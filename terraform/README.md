# Agentic AIOps Terraform

Terraform starter for AWS Bedrock AgentCore CI/CD.

## Deployment
1. Deploy `bootstrap` to create ECR repositories and the GitHub OIDC role.
2. Build/push the four agent images.
3. Package Lambda as `build/lambda_deployment.zip`.
4. Deploy `platform` with the image URIs and environment values.

Review IAM scope and AgentCore arguments against your selected AWS provider version before production deployment.
