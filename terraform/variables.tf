variable "aws_region" {
  description = "AWS Region to deploy resources."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain name for the Cognito User Pool (e.g. whisper.example.com)."
  type        = string
  default     = "service.domain.tld"
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
  default     = {}
}
