module "cloudfront_log_group" {
  source  = "terraform-aws-modules/cloudwatch/aws//modules/log-group"
  version = "~> 5.7.2"

  name              = "/aws/cloudfront/${var.app_name}-access-logs"
  retention_in_days = 30
}

data "aws_iam_policy_document" "cloudfront_log_delivery" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${module.cloudfront_log_group.cloudwatch_log_group_arn}:*"]
    principals {
      identifiers = ["delivery.logs.amazonaws.com"]
      type        = "Service"
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "cloudfront_log_delivery" {
  policy_document = data.aws_iam_policy_document.cloudfront_log_delivery.json
  policy_name     = "${var.app_name}-cf-log-delivery-policy"
}

resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  name         = "${var.app_name}-cf-source"
  log_type     = "ACCESS_LOGS"
  resource_arn = module.cloudfront.cloudfront_distribution_arn
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront" {
  name = "${var.app_name}-cf-destination"
  delivery_destination_configuration {
    destination_resource_arn = module.cloudfront_log_group.cloudwatch_log_group_arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront.arn
}
