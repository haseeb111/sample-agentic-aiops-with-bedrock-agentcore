output "github_deploy_role_arn" { value = aws_iam_role.github_deploy.arn }
output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.agents : name => repo.repository_url }
}
