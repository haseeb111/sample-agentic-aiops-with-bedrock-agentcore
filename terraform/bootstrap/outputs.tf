output "github_deploy_role_arn" {
  value       = aws_iam_role.github_deploy.arn
  description = "ARN of the IAM role used by GitHub Actions for deployment"
}

output "ecr_repository_urls" {
  value       = { for name, repo in aws_ecr_repository.agents : name => repo.repository_url }
  description = "Map of ECR repository names to their repository URLs"
}
