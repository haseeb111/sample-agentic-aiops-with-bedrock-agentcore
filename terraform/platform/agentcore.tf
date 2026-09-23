locals {
  runtimes = {
    analyze = var.analyze_image
    validation = var.validation_image
    sop = var.sop_image
    execution = var.sop_execution_image
  }
}
resource "aws_bedrockagentcore_agent_runtime" "agent" {
  for_each = local.runtimes
  agent_runtime_name = "${var.environment}-${each.key}-agent"
  role_arn = aws_iam_role.agentcore_runtime.arn
  agent_runtime_artifact {
    container_configuration { container_uri = each.value }
  }
  network_configuration { network_mode = "PUBLIC" }
}
