variable "environment" {
  type        = string
  default     = "dev"
  description = "Target deployment environment"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "servicenow_url" {
  type        = string
  description = "ServiceNow instance URL"
  default     = "https://dev366467.service-now.com"
}

variable "servicenow_username" {
  type        = string
  description = "ServiceNow integration user"
  default     = "agentcore_service"
}

variable "servicenow_password" {
  type        = string
  description = "ServiceNow user password"
  sensitive   = true
}

variable "servicenow_secret_arn" {
  type        = string
  description = "Optional pre-existing Secrets Manager ARN"
  default     = ""
}

variable "github_org" {
  type        = string
  description = "GitHub Organization or username"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}

variable "github_branch" {
  type        = string
  default     = "main"
  description = "Deployment branch name"
}
