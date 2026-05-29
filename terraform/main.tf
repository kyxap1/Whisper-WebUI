terraform {
  required_version = "~> 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.30.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.0"
    }
  }
}

module "cognito" {
  source  = "terraformita/cognito/aws"
  version = "~> 1.2.0"

  region      = var.aws_region
  stage_name  = "ignore"
  domain_name = var.domain_name
  tags        = var.tags

  # Enable Standalone Mode to avoid requiring ECS containers map
  usage_mode = "standalone"

  # Override default naming logic
  user_pool_name = var.domain_name

  auth = {
    allow_user_sign_up = false
  }

  # Standalone OAuth Clients Configuration
  standalone_clients = {
    (var.app_name) = {
      callback_urls = [
        "https://${var.domain_name}/oauth2/callback",
        "https://${var.domain_name}/oauth2/idpresponse",
        "https://${var.domain_name}/launcher"
      ]
      logout_urls = [
        "https://${var.domain_name}/oauth2/logout",
        "https://${var.domain_name}/launcher"
      ]
      allowed_oauth_flows  = ["code"]
      allowed_oauth_scopes = ["phone", "email", "openid", "profile"]
    }
  }
}

#### Data Sources
data "aws_instance" "app" {
  instance_id = var.ec2_instance_id
}

#### Lambda: Start Page & Launcher
module "start_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.5.0"

  function_name = "${var.app_name}-start-instance"
  handler       = "start_instance.lambda_handler"
  runtime       = "python3.11"
  source_path   = "${path.module}/scripts/start_instance.py"
  hash_extra    = filesha256("${path.module}/scripts/start_instance.py")

  environment_variables = {
    INSTANCE_ID    = var.ec2_instance_id
    APP_DOMAIN     = var.domain_name
    DOMAIN_NAME    = var.domain_name
    COGNITO_DOMAIN = "${module.cognito.standalone["whisper"].domain}.auth.${var.aws_region}.amazoncognito.com"
    CLIENT_ID      = module.cognito.standalone["whisper"].client_id
    CLIENT_SECRET  = module.cognito.standalone["whisper"].client_secret
  }

  attach_policy_statements = true
  policy_statements = {
    ec2_control = {
      effect    = "Allow"
      actions   = ["ec2:StartInstances", "ec2:DescribeInstances"]
      resources = ["*"]
    }
  }

  # Enable Function URL (public, but accessed via CloudFront)
  create_lambda_function_url = true
  # NONE = Public URL. We rely on Start Page being simple/harmless.
  # If you want auth, we need AWS_IAM or cloudfront signed URLs (more complex).
  authorization_type = "NONE"
  cors = {
    allow_credentials = true
    allow_origins     = ["*"]
    allow_methods     = ["*"]
  }

  tags = var.tags
}

#### Lambda: Stop Logic
module "stop_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.5.0"

  function_name = "${var.app_name}-stop-instance"
  handler       = "stop_instance.lambda_handler"
  runtime       = "python3.11"
  source_path   = "${path.module}/scripts/stop_instance.py"
  hash_extra    = filesha256("${path.module}/scripts/stop_instance.py")

  environment_variables = {
    INSTANCE_ID = var.ec2_instance_id
  }

  attach_policy_statements = true
  policy_statements = {
    ec2_stop = {
      effect    = "Allow"
      actions   = ["ec2:StopInstances"]
      resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${var.ec2_instance_id}"]
    }
  }

  allowed_triggers = {
    SNS = {
      service    = "sns"
      source_arn = module.sns_topic.topic_arn
    }
  }

  create_current_version_allowed_triggers = false

  tags = var.tags
}

#### CloudFront & ACME
module "cloudfront" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "~> 6.3.0"

  aliases = [var.domain_name]

  comment             = "${var.app_name} distribution"
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"
  retain_on_delete    = false
  wait_for_deployment = false

  origin = {
    app_server = { # Identifying key for this origin
      domain_name = data.aws_instance.app.public_dns
      custom_origin_config = {
        http_port                = 80
        https_port               = 443
        origin_protocol_policy   = "match-viewer"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_read_timeout      = 5
        origin_keepalive_timeout = 5
      }
      connection_attempts = 1
    }

    start_lambda = {
      domain_name = replace(replace(module.start_lambda.lambda_function_url, "https://", ""), "/", "")
      custom_origin_config = {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }
    }
  }

  default_cache_behavior = {
    target_origin_id       = "app_server"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true
    query_string    = true

    # Forward all headers for Websockets and Auth
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    function_association = {
      viewer-request = {
        function_arn = aws_cloudfront_function.auth_redirect.arn
      }
    }
  }

  ordered_cache_behavior = [
    {
      path_pattern           = "/.well-known/acme-challenge/*"
      target_origin_id       = "app_server"
      viewer_protocol_policy = "allow-all"

      allowed_methods = ["GET", "HEAD", "OPTIONS"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true
      query_string    = false

      cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    },
    {
      path_pattern           = "/launcher"
      target_origin_id       = "start_lambda"
      viewer_protocol_policy = "redirect-to-https"

      allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods  = ["GET", "HEAD"]
      compress        = true
      query_string    = true

      cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    }
  ]

  custom_error_response = [
    {
      error_code            = 502
      response_code         = 200
      response_page_path    = "/launcher"
      error_caching_min_ttl = 0
    },
    {
      error_code            = 503
      response_code         = 200
      response_page_path    = "/launcher"
      error_caching_min_ttl = 0
    },
    {
      error_code            = 504
      response_code         = 200
      response_page_path    = "/launcher"
      error_caching_min_ttl = 0
    }
  ]

  viewer_certificate = {
    acm_certificate_arn      = module.acm.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"

  }

  tags = var.tags
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 6.3.0"

  domain_name = var.domain_name
  zone_id     = module.zone.id

  validation_method = "DNS"

  wait_for_validation = true

  tags = var.tags
}

module "zone" {
  source  = "terraform-aws-modules/route53/aws"
  version = "~> 6.4.0"

  name              = var.domain_name
  delegation_set_id = module.delegation_set.route53_delegation_set_id["main"]
  tags              = var.tags
}

module "records" {
  source  = "terraform-aws-modules/route53/aws"
  version = "~> 6.4.0"

  name        = var.domain_name
  create_zone = false

  records = {
    cloudfront = {
      full_name = var.domain_name
      type      = "A"
      alias = {
        name                   = module.cloudfront.cloudfront_distribution_domain_name
        zone_id                = module.cloudfront.cloudfront_distribution_hosted_zone_id
        evaluate_target_health = false
      }
    }
  }
}

module "delegation_set" {
  source  = "terraform-aws-modules/route53/aws//modules/delegation-sets"
  version = "~> 6.4.0"

  delegation_sets = {
    main = {
      reference_name = var.app_name
    }
  }
}

#### Monitoring & Auto-Stop
module "sns_topic" {
  source  = "terraform-aws-modules/sns/aws"
  version = "~> 7.1.0"

  name = "${var.app_name}-stop-notifications"

  subscriptions = {
    lambda = {
      protocol = "lambda"
      endpoint = module.stop_lambda.lambda_function_arn
    }
  }

  tags = var.tags
}

module "metric_alarm" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version = "~> 5.7.2"

  alarm_name          = "${var.app_name}-gpu-idle-stop"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 5
  alarm_description   = "Stop instance when GPU is idle for 15 minutes"
  alarm_actions       = [module.sns_topic.topic_arn]

  metric_query = concat(
    [for idx, gpu in var.gpu_metrics_config : {
      id = "gpu${idx}"
      metric = [{
        metric_name = var.gpu_metric_name
        namespace   = var.gpu_metric_namespace
        period      = 300
        stat        = "Average"
        dimensions = {
          InstanceId = var.ec2_instance_id
          name       = gpu.name
          arch       = gpu.arch
          index      = gpu.index
        }
      }]
      return_data = false
    }],
    [{
      id          = "e1"
      expression  = "MAX([${join(",", [for idx, _ in var.gpu_metrics_config : "gpu${idx}"])}])"
      label       = "Max GPU Utilization"
      return_data = true
    }]
  )

  tags = var.tags
}

#### Common Config
data "aws_caller_identity" "current" {}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_function" "auth_redirect" {
  name    = "${var.app_name}-auth-redirect"
  runtime = "cloudfront-js-1.0"
  comment = "Redirects unauthenticated users to Cognito"
  publish = true
  code = templatefile("${path.module}/templates/redirect_to_cognito.js.tftpl", {
    cognito_domain = "${module.cognito.standalone["whisper"].domain}.auth.${var.aws_region}.amazoncognito.com"
    client_id      = module.cognito.standalone["whisper"].client_id
    redirect_uri   = "https://${var.domain_name}/launcher"
  })
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# Policy for the Instance to push metrics (attach this to your app execution role)
resource "aws_iam_policy" "cw_agent_policy" {
  name        = "${replace(var.app_name, "-", "_")}_cw_agent_policy"
  description = "Allows pushing CloudWatch metrics"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = var.gpu_metric_namespace
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cw_agent_attach" {
  count      = var.iam_role_name != "" ? 1 : 0
  role       = var.iam_role_name
  policy_arn = aws_iam_policy.cw_agent_policy.arn
}
