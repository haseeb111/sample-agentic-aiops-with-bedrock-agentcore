resource "aws_api_gateway_rest_api" "incident" { name = "${var.environment}-incident-api" }
resource "aws_api_gateway_resource" "incident" {
  rest_api_id = aws_api_gateway_rest_api.incident.id
  parent_id = aws_api_gateway_rest_api.incident.root_resource_id
  path_part = "incident"
}
resource "aws_api_gateway_method" "post" {
  rest_api_id = aws_api_gateway_rest_api.incident.id
  resource_id = aws_api_gateway_resource.incident.id
  http_method = "POST"
  authorization = "NONE"
  api_key_required = true
}
resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.incident.id
  resource_id = aws_api_gateway_resource.incident.id
  http_method = aws_api_gateway_method.post.http_method
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.orchestrator.invoke_arn
}
resource "aws_lambda_permission" "api_gateway" {
  statement_id = "AllowApiGateway"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestrator.function_name
  principal = "apigateway.amazonaws.com"
  source_arn = "${aws_api_gateway_rest_api.incident.execution_arn}/*/*"
}
resource "aws_api_gateway_deployment" "incident" {
  rest_api_id = aws_api_gateway_rest_api.incident.id
  triggers = { redeployment = sha1(jsonencode([aws_api_gateway_resource.incident.id, aws_api_gateway_method.post.id, aws_api_gateway_integration.lambda.id])) }
  lifecycle { create_before_destroy = true }
}
resource "aws_api_gateway_stage" "stage" {
  deployment_id = aws_api_gateway_deployment.incident.id
  rest_api_id = aws_api_gateway_rest_api.incident.id
  stage_name = var.environment
}
