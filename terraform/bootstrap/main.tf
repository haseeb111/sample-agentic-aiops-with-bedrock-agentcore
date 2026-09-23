
# ==========================================================
# 1. CENTRAL S3 BUCKET FOR LOG AGGREGATION
# ==========================================================

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

data "aws_caller_identity" "current" {}

# ==========================================================
# 2. FIREHOSE ROLE & STREAM (CLOUDWATCH -> S3)
# ==========================================================

resource "aws_iam_role" "firehose_delivery" {
  name = "${var.environment}-firehose-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose_s3_permissions" {
  name = "${var.environment}-firehose-s3-policy"
  role = aws_iam_role.firehose_delivery.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.central_logs.arn,
          "${aws_s3_bucket.central_logs.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "log_stream" {
  name        = "${var.environment}-central-log-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_delivery.arn
    bucket_arn = aws_s3_bucket.central_logs.arn
    prefix     = "ec2-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
  }
}

# ==========================================================
# 3. CLOUDWATCH SUBSCRIPTION FILTER
# ==========================================================

resource "aws_cloudwatch_log_group" "ec2_app_logs" {
  name              = "/aws/ec2/monitoring-agents"
  retention_in_days = 30
}

resource "aws_iam_role" "cw_to_firehose" {
  name = "${var.environment}-cw-to-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cw_to_firehose" {
  name = "${var.environment}-cw-to-firehose-policy"
  role = aws_iam_role.cw_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
      Resource = [aws_kinesis_firehose_delivery_stream.log_stream.arn]
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "firehose_sync" {
  name            = "central-s3-export"
  log_group_name  = aws_cloudwatch_log_group.ec2_app_logs.name
  filter_pattern  = "" # Capture all incoming logs
  destination_arn = aws_kinesis_firehose_delivery_stream.log_stream.arn
  role_arn        = aws_iam_role.cw_to_firehose.arn
}

# ==========================================================
# 4. MONITORING TEST EC2 INSTANCE (WITH CW AGENT)
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

# Attach SSM and CloudWatch policies to the VM
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
  iam_instance_profile = aws_iam_instance_profile.ec2_monitoring.name

  user_data = <<-EOF
              #!/bin/bash
              dnf install -y amazon-cloudwatch-agent ssm-agent
              systemctl enable --now amazon-ssm-agent
              
              # Config file for CloudWatch Agent to ship logs to central group
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
# 5. ALARM, SERVICENOW TICKET GENERATION & AUTOMATED REMEDIATION
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

resource "aws_sns_topic" "incident_topic" {
  name = "${var.environment}-incident-notification"
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

resource "aws_lambda_function" "incident_orchestrator" {
  filename      = "lambda_orchestrator.zip"
  function_name = "${var.environment}-incident-orchestrator"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "python3.11"

  environment {
    variables = {
      SERVICENOW_SECRET_ARN = var.servicenow_secret_arn
      AGENTCORE_ROLE_ARN    = aws_iam_role.agentcore_runtime.arn
    }
  }
}
