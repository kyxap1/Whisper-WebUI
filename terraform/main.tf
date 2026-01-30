terraform {
  required_version = "~> 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.30.0"
    }
  }
}

module "cognito" {
  # Local development path
  source = "/Users/kyxap/tmp/terraformita/terraform-aws-cognito"
  # Future registry source:
  # source = "terraformita/cognito/aws"

  region      = var.aws_region
  stage_name  = "ignore"
  domain_name = var.domain_name
  tags        = var.tags

  # Enable Standalone Mode to avoid requiring ECS containers map
  usage_mode = "standalone"

  # Override default naming logic
  user_pool_name = var.domain_name

  auth = {
    allow_user_sign_up = false # Disable self-registration
  }

  # Standalone OAuth Clients Configuration
  standalone_clients = {
    "whisper" = {
      callback_urls = [
        "https://${var.domain_name}/oauth2/callback",
        "https://${var.domain_name}/oauth2/idpresponse"
      ]
      logout_urls = [
        "https://${var.domain_name}/oauth2/logout"
      ]
      allowed_oauth_flows  = ["code"]
      allowed_oauth_scopes = ["phone", "email", "openid", "profile"]
    }
  }
}
