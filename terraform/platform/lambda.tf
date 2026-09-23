resource "aws_iam_role_policy" "lambda_agentcore" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["bedrock-agentcore:InvokeAgentRuntime","bedrock-agentcore:GetAgentRuntime"], Resource = "*" }]
  })
}
resource "aws_lambda_function" "orchestrator" {
  function_name = "${var.environment}-incident-orchestrator"
  filename = var.lambda_zip
  source_code_hash = filebase64sha256(var.lambda_zip)
  role = aws_iam_role.lambda.arn
  handler = "lambda_function.lambda_handler"
  runtime = "python3.11"
  timeout = 180
  environment {
    variables = {
      ANALYZE_AGENT_ARN = aws_bedrockagentcore_agent_runtime.agent["analyze"].agent_runtime_arn
      VALIDATION_AGENT_ARN = aws_bedrockagentcore_agent_runtime.agent["validation"].agent_runtime_arn
      SOP_AGENT_ARN = aws_bedrockagentcore_agent_runtime.agent["sop"].agent_runtime_arn
      EXECUTION_AGENT_ARN = aws_bedrockagentcore_agent_runtime.agent["execution"].agent_runtime_arn
      BEDROCK_MODEL_ID = var.bedrock_model_id
      BEDROCK_KB_ID = var.bedrock_kb_id
    }
  }
}
