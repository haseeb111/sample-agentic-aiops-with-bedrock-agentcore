output "incident_api_url" { value = "${aws_api_gateway_stage.stage.invoke_url}/incident" }
output "agent_runtime_arns" { value = { for k, v in aws_bedrockagentcore_agent_runtime.agent : k => v.agent_runtime_arn } }
