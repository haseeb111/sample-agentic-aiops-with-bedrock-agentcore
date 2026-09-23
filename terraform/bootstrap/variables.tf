variable "environment" {
  type        = string
  default     = "dev"
  description = "Target deployment environment"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "servicenow_secret_arn" {
  type        = string
  description = "AWS Secrets Manager ARN storing ServiceNow credentials (URL, username, password)"
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
