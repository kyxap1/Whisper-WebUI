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
