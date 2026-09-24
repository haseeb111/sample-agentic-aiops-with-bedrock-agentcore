# ==========================================================
# 0. LOCAL HELPER & SECRETS MANAGER PROVISIONING
# ==========================================================

# Create Secrets Manager container if pre-existing ARN is not provided
resource "aws_secretsmanager_secret" "servicenow" {
  count       = var.servicenow_secret_arn == "" ? 1 : 0
  name        = "${var.environment}/servicenow/credentials"
  description = "ServiceNow API credentials for AIOps"
}

# Store the JSON payload inside Secrets Manager
resource "aws_secretsmanager_secret_version" "servicenow_val" {
  count     = var.servicenow_secret_arn == "" ? 1 : 0
  secret_id = aws_secretsmanager_secret.servicenow[0].id
  secret_string = jsonencode({
    url      = var.servicenow_url
    username = var.servicenow_username
    password = var.servicenow_password
  })
}

# Local variable to dynamically select the active secret ARN
locals {
  active_servicenow_secret_arn = var.servicenow_secret_arn != "" ? var.servicenow_secret_arn : aws_secretsmanager_secret.servicenow[0].arn
}

# ==========================================================
# 1. CENTRAL S3 BUCKET FOR LOG AGGREGATION
# ==========================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "central_logs" {
  bucket        = "central-logging-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "central_logs_crypto" {
  bucket = aws_s3_bucket.central_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==========================================================
# 2. CLOUDWATCH LOG GROUP
# ==========================================================

resource "aws_cloudwatch_log_group" "ec2_app_logs" {
  name              = "/aws/ec2/monitoring-agents"
  retention_in_days = 30
}

# ==========================================================
# 3. MONITORING TEST EC2 INSTANCE (WITH CW AGENT)
# ==========================================================

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_iam_role" "ec2_monitoring" {
  name = "${var.environment}-monitoring-vm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_cw" {
  role       = aws_iam_role.ec2_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_monitoring" {
  name = "${var.environment}-monitoring-vm-profile"
  role = aws_iam_role.ec2_monitoring.name
}

resource "aws_instance" "monitoring_test_vm" {
  ami                  = data.aws_ami.amazon_linux_2023.id
  instance_type        = "t3.micro"
  subnet_id            = "subnet-0f87c73ac77418d93"
  iam_instance_profile = aws_iam_instance_profile.ec2_monitoring.name

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y amazon-cloudwatch-agent ssm-agent
              systemctl enable --now amazon-ssm-agent
              
              cat << 'CWCFG' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
              {
                "logs": {
                  "logs_collected": {
                    "files": {
                      "collect_list": [
                        {
                          "file_path": "/var/log/messages",
                          "log_group_name": "${aws_cloudwatch_log_group.ec2_app_logs.name}",
                          "log_stream_name": "{instance_id}"
                        }
                      ]
                    }
                  }
                }
              }
              CWCFG

              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
                -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
              EOF

  tags = {
    Name        = "${var.environment}-monitoring-test-vm"
    Environment = var.environment
  }
}

# ==========================================================
# 4. ALARM, SERVICENOW TICKET GENERATION & AUTOMATED REMEDIATION
# ==========================================================

resource "aws_cloudwatch_log_metric_filter" "error_counter" {
  name           = "ErrorLogFilter"
  pattern        = "ERROR"
  log_group_name = aws_cloudwatch_log_group.ec2_app_logs.name

  metric_transformation {
    name      = "EC2ErrorCount"
    namespace = "AgenticAIOps/Monitoring"
    value     = "1"
  }
}

resource "aws_sns_topic" "incident_topic" {
  name = "${var.environment}-incident-notification"
}

resource "aws_cloudwatch_metric_alarm" "error_alarm" {
  alarm_name          = "${var.environment}-ec2-critical-error-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.error_counter.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.error_counter.metric_transformation[0].namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  alarm_actions       = [aws_sns_topic.incident_topic.arn]
}

resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = aws_sns_topic.incident_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.incident_orchestrator.arn
}

resource "aws_lambda_permission" "sns_lambda" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_orchestrator.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.incident_topic.arn
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda" # Adjusts dynamically to target the lambda source directory
  output_path = "${path.module}/lambda_deployment.zip"
}

resource "aws_lambda_function" "incident_orchestrator" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "${var.environment}-incident-orchestrator"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.11"

  environment {
    variables = {
      SERVICENOW_SECRET_ARN = local.active_servicenow_secret_arn
      AGENTCORE_ROLE_ARN    = aws_iam_role.agentcore_runtime.arn
    }
  }
}

# ==========================================================
# 5. IAM ROLES & POLICIES FOR LAMBDA AND AGENTCORE
# ==========================================================

resource "aws_iam_role" "lambda" {
  name = "${var.environment}-incident-orchestrator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "agentcore_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agentcore_runtime" {
  name               = "${var.environment}-agentcore-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume_role.json
}

resource "aws_iam_role_policy" "agentcore_runtime" {
  name = "${var.environment}-agentcore-runtime-policy"
  role = aws_iam_role.agentcore_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ssm:SendCommand",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [local.active_servicenow_secret_arn]
      }
    ]
  })
}
