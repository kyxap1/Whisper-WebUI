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

variable "app_name" {
  description = "Name of the application (used for resource naming)."
  type        = string
  default     = "whisper"
}

variable "ec2_instance_id" {
  description = "ID of the existing EC2 instance to manage."
  type        = string
}

variable "gpu_metric_name" {
  description = "Name of the GPU metric to monitor."
  type        = string
  default     = "nvidia_smi_utilization_gpu"
}

variable "gpu_metric_namespace" {
  description = "Namespace of the GPU metric."
  type        = string
  default     = "CWAgent"
}

variable "gpu_metrics_config" {
  description = "List of GPU configurations for CloudWatch alarms dimensions."
  type = list(object({
    name  = string
    arch  = string
    index = string
  }))
  default = [
    {
      name  = "Tesla T4"
      arch  = "Turing"
      index = "0"
    }
  ]
}

variable "iam_role_name" {
  description = "Name of the existing IAM Role to attach policies to (optional)."
  type        = string
  default     = ""
}
