data "aws_iam_policy_document" "agentcore_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["bedrock-agentcore.amazonaws.com"] }
  }
}
resource "aws_iam_role" "agentcore_runtime" {
  name = "${var.environment}-agentcore-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume_role.json
}
resource "aws_iam_role_policy" "agentcore_runtime" {
  role = aws_iam_role.agentcore_runtime.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["bedrock:InvokeModel","bedrock:Retrieve","bedrock:RetrieveAndGenerate","ec2:DescribeInstances","ec2:DescribeInstanceStatus","ssm:SendCommand","ssm:GetCommandInvocation"], Resource = "*" },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = [var.servicenow_secret_arn] }
    ]
  })
}
resource "aws_iam_role" "lambda" {
  name = "${var.environment}-incident-orchestrator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
