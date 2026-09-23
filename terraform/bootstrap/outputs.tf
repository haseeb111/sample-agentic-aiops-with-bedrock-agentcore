output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "ARN of the IAM role used by GitHub Actions for deployment"
}
