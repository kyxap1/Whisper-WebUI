output "cognito_user_pool_id" {
  description = "Map of Cognito User Pool IDs."
  value       = { for k, v in module.cognito.standalone : k => v.user_pool_id }
}

output "cognito_client_id" {
  description = "Map of App Client IDs."
  value       = { for k, v in module.cognito.standalone : k => v.client_id }
}

output "cognito_client_secret" {
  description = "Map of client secrets."
  value       = { for k, v in module.cognito.standalone : k => v.client_secret }
  sensitive   = true
}

output "cognito_domain" {
  description = "Map of Cognito domains."
  value       = { for k, v in module.cognito.standalone : k => v.domain }
}

output "cloudfront_domain" {
  description = "Domain name of the CloudFront distribution."
  value       = module.cloudfront.cloudfront_distribution_domain_name
}

output "start_page_url" {
  description = "Direct URL for the Start Page Lambda (for debugging)."
  value       = module.start_lambda.lambda_function_url
}

output "cw_agent_policy_arn" {
  description = "ARN of the IAM Policy to attach to the EC2 Instance Profile."
  value       = aws_iam_policy.cw_agent_policy.arn
}

output "delegation_set_nameservers" {
  description = "Name servers of the Route53 delegation set."
  value       = module.delegation_set.route53_delegation_set_name_servers["main"]
}
