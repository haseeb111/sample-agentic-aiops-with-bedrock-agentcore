variable "aws_region" { type = string, default = "us-east-1" }
variable "environment" { type = string, default = "dev" }
variable "analyze_image" { type = string }
variable "validation_image" { type = string }
variable "sop_image" { type = string }
variable "sop_execution_image" { type = string }
variable "bedrock_model_id" { type = string }
variable "bedrock_kb_id" { type = string }
variable "servicenow_secret_arn" { type = string }
variable "lambda_zip" { type = string, default = "../../build/lambda_deployment.zip" }
