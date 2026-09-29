################################################################################
# AIOps Solution Guide (LLM/RAG for VMs, EKS & Databases) - Terraform
#
# Implements the PDF end to end, keeping the existing open-source VM stack:
#
#   Collection  : CloudWatch Agent on VMs, Fluent Bit on EKS -> CloudWatch Logs
#                 node_exporter / Prometheus (VM stack + kube-prometheus-stack)
#                 RDS Enhanced Monitoring + Performance Insights
#   Detection   : Amazon DevOps Guru (tag-scoped), CloudWatch alarms,
#                 Prometheus alert rules, k8sgpt operator (Bedrock backend)
#   RAG         : Lambda -> Bedrock Titan embeddings -> OpenSearch k-NN
#                 -> Bedrock Claude RCA   (plus Ollama/Qdrant on the AIOps VM)
#   Ticketing   : ServiceNow Table API, credentials in Secrets Manager
#   Cost/safety : DynamoDB dedupe window, LLM only runs on confirmed anomalies
#
# Every expensive layer has an enable_* flag (see VARIABLES).
#
# Manual one-time steps Terraform cannot do (see README notes in the reply):
#   * Bedrock: submit the Anthropic first-time-use form in the Bedrock console.
#   * ServiceNow: put real credentials into the Secrets Manager secret.
################################################################################

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket = "aiops-terraform-tfstate01"
    key    = "dev-aiops.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
  }
}

################################################################################
# VARIABLES
################################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project prefix"
  type        = string
  default     = "aiops-demo"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "admin_cidr" {
  description = "Your public IP/CIDR for SSH, Grafana, Prometheus, Alertmanager, FastAPI and Qdrant. Set to YOUR.PUBLIC.IP/32."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

# Two subnets in two AZs: EKS, RDS and multi-node OpenSearch all require 2 AZs.
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.50.1.0/24", "10.50.2.0/24"]
}

# ---------------------------------------------------------------- feature flags
variable "enable_oss_aiops_vm" {
  description = "Open-source AIOps VM (Prometheus, Loki, Grafana, Ollama, Qdrant, FastAPI, Ansible)"
  type        = bool
  default     = true
}

variable "enable_eks" {
  description = "EKS layer: Fluent Bit, kube-prometheus-stack, k8sgpt operator"
  type        = bool
  default     = true
}

variable "existing_eks_cluster_name" {
  description = "Use an EXISTING EKS cluster instead of creating one (needs API or API_AND_CONFIG_MAP auth mode and the eks-pod-identity-agent add-on). Leave empty to create a new cluster."
  type        = string
  default     = ""
}

variable "enable_rds" {
  description = "Demo PostgreSQL RDS instance with Performance Insights + Enhanced Monitoring"
  type        = bool
  default     = true
}

variable "enable_opensearch" {
  description = "OpenSearch domain used as the RAG vector store"
  type        = bool
  default     = true
}

variable "enable_devops_guru" {
  description = "Enable Amazon DevOps Guru (one resource collection per account/region - disable if already configured)"
  type        = bool
  default     = true
}

# ------------------------------------------------------------------- VM sizing
variable "target_vm_count" {
  description = "Number of monitored application VMs"
  type        = number
  default     = 2
}

variable "target_instance_type" {
  type    = string
  default = "t3.small"
}

variable "aiops_instance_type" {
  description = "AIOps VM. Needs ~16 GiB RAM for Docker stack + local Ollama model. t3.micro (1 GiB) runs out of memory and becomes unreachable over SSH/SSM."
  type        = string
  default     = "t3.xlarge"
}

variable "target_root_gb" {
  type    = number
  default = 30
}

variable "aiops_root_gb" {
  type    = number
  default = 100
}

variable "ollama_model" {
  type    = string
  default = "llama3.2:3b"
}

variable "ollama_embedding_model" {
  type    = string
  default = "nomic-embed-text"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ------------------------------------------------------------------ Bedrock
variable "bedrock_llm_model_id" {
  description = "Bedrock chat model for RCA (Converse API). Claude 4.5 models need a geo/global inference profile ID."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "bedrock_embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "embedding_dimensions" {
  type    = number
  default = 1024
}

# -------------------------------------------------------------------- EKS
variable "eks_version" {
  type    = string
  default = "1.34"
}

variable "eks_node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "eks_node_desired" {
  type    = number
  default = 2
}

variable "k8sgpt_version" {
  description = "k8sgpt image tag run by the operator"
  type        = string
  default     = "v0.4.32"
}

variable "k8sgpt_bedrock_model" {
  description = "Model name passed to k8sgpt's amazonbedrock backend. Must be one the k8sgpt version supports."
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

# -------------------------------------------------------------------- RDS
variable "rds_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "rds_engine_version" {
  type    = string
  default = "16"
}

# ------------------------------------------------------------- OpenSearch
variable "opensearch_engine_version" {
  type    = string
  default = "OpenSearch_2.17"
}

variable "opensearch_instance_type" {
  description = "PDF production sizing is r6g.large.search x2. t3.medium.search x1 is fine for a demo."
  type        = string
  default     = "t3.medium.search"
}

variable "opensearch_instance_count" {
  type    = number
  default = 1
}

variable "opensearch_volume_gb" {
  type    = number
  default = 20
}

# -------------------------------------------------------------- ServiceNow
# Optional initial values. Terraform writes them ONCE into Secrets Manager and
# then ignores changes, so you can rotate the secret outside Terraform.
variable "servicenow_url" {
  description = "e.g. https://yourinstance.service-now.com - leave empty to skip ticket creation"
  type        = string
  default     = ""
}

variable "servicenow_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "servicenow_password" {
  type      = string
  default   = ""
  sensitive = true
}

# --------------------------------------------------------------- bootstrap
variable "bootstrap_bucket_name" {
  description = "Existing S3 bucket used to store the AIOps bootstrap script (not created here)"
  type        = string
  default     = "aiops-terraform-tfstate01"
}

variable "bootstrap_prefix" {
  type    = string
  default = "bootstrap"
}

################################################################################
# PROVIDERS
################################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # DevOps Guru analyses every resource carrying this tag (see section 6.5).
  # PDF uses CloudFormation stacks, but Terraform resources are not in a
  # CloudFormation stack, so tag-based coverage is used instead.
  devops_guru_tag_key = "DevOps-Guru-aiops"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project                     = var.project_name
      Environment                 = var.environment
      ManagedBy                   = "terraform"
      (local.devops_guru_tag_key) = local.name_prefix
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = local.eks_endpoint
    cluster_ca_certificate = local.eks_ca
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.eks_name, "--region", var.aws_region]
    }
  }
}

provider "kubectl" {
  host                   = local.eks_endpoint
  cluster_ca_certificate = local.eks_ca
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.eks_name, "--region", var.aws_region]
  }
}

################################################################################
# DATA / LOCALS
################################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
  # use1-az3 has limited capacity and does not support EKS control planes.
  exclude_zone_ids = ["use1-az3"]
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_s3_bucket" "bootstrap" {
  bucket = var.bootstrap_bucket_name
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  azs         = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  aiops_dns   = "aiops.aiops.internal"
  vm_log_grp  = "/aiops/${var.environment}/vms"
  eks_log_grp = "/aiops/${var.environment}/eks"
  cw_param    = "AmazonCloudWatch-${local.name_prefix}-vm-config"

  create_eks = var.enable_eks && var.existing_eks_cluster_name == ""
  eks_name   = local.create_eks ? try(module.eks[0].cluster_name, "") : var.existing_eks_cluster_name
  eks_endpoint = local.create_eks ? try(module.eks[0].cluster_endpoint, "") : try(data.aws_eks_cluster.existing[0].endpoint, "")
  eks_ca = base64decode(
    local.create_eks ? try(module.eks[0].cluster_certificate_authority_data, "") : try(data.aws_eks_cluster.existing[0].certificate_authority[0].data, "")
  )

  # Shared CloudWatch Agent install (PDF 6.2). Config comes from SSM Parameter Store.
  cw_agent_install = <<-CWA
    curl -fsSL -o /tmp/amazon-cloudwatch-agent.deb \
      https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -c ssm:${local.cw_param} -s
  CWA
}

################################################################################
# NETWORKING
################################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.name_prefix}-public-snet-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

################################################################################
# SECURITY GROUPS (created first, cross-SG rules added separately - no cycle)
################################################################################

resource "aws_security_group" "aiops" {
  name        = "${local.name_prefix}-aiops-sg"
  description = "AIOps platform security group"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-aiops-sg"
  }
}

resource "aws_security_group" "target" {
  name        = "${local.name_prefix}-target-sg"
  description = "Monitored VM security group"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name_prefix}-target-sg"
  }
}

locals {
  aiops_admin_ports = {
    ssh          = 22
    grafana      = 3000
    fastapi      = 8000
    prometheus   = 9090
    alertmanager = 9093
    qdrant       = 6333
  }
}

resource "aws_vpc_security_group_ingress_rule" "aiops_admin" {
  for_each = local.aiops_admin_ports

  security_group_id = aws_security_group.aiops.id
  description       = "${each.key} from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aiops_loki_from_targets" {
  security_group_id            = aws_security_group.aiops.id
  description                  = "Loki ingestion from monitored VMs"
  referenced_security_group_id = aws_security_group.target.id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
}

locals {
  target_ports_from_aiops = {
    node_exporter = 9100
    ansible_ssh   = 22
    demo_app      = 8080
  }
}

resource "aws_vpc_security_group_ingress_rule" "target_from_aiops" {
  for_each = local.target_ports_from_aiops

  security_group_id            = aws_security_group.target.id
  description                  = "${each.key} from AIOps VM"
  referenced_security_group_id = aws_security_group.aiops.id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "target_ssh_from_admin" {
  security_group_id = aws_security_group.target.id
  description       = "SSH to monitored VMs from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "aiops_outbound" {
  security_group_id = aws_security_group.aiops.id
  description       = "Outbound Internet, package and model downloads"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "target_outbound" {
  security_group_id = aws_security_group.target.id
  description       = "Outbound package installation and log forwarding"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

################################################################################
# PRIVATE DNS
################################################################################

resource "aws_route53_zone" "private" {
  name = "aiops.internal"

  vpc {
    vpc_id = aws_vpc.this.id
  }

  tags = {
    Name = "${local.name_prefix}-private-zone"
  }
}

################################################################################
# CENTRAL LOG STORE (CloudWatch Logs) - VMs and EKS ship to the same place
################################################################################

resource "aws_cloudwatch_log_group" "vms" {
  name              = local.vm_log_grp
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "eks" {
  count = var.enable_eks ? 1 : 0

  name              = local.eks_log_grp
  retention_in_days = var.log_retention_days
}

# CloudWatch Agent config (PDF 6.2) - metrics + logs from every VM.
resource "aws_ssm_parameter" "cw_agent_config" {
  name = local.cw_param
  type = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace         = "CWAgent"
      append_dimensions = { InstanceId = "$${aws:InstanceId}" }
      metrics_collected = {
        mem  = { measurement = ["mem_used_percent"] }
        disk = { measurement = ["used_percent"], resources = ["/"] }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            { file_path = "/var/log/syslog", log_group_name = local.vm_log_grp, log_stream_name = "{instance_id}/syslog" },
            { file_path = "/var/log/auth.log", log_group_name = local.vm_log_grp, log_stream_name = "{instance_id}/auth" },
            { file_path = "/var/log/aiops-demo/*.log", log_group_name = local.vm_log_grp, log_stream_name = "{instance_id}/app" },
          ]
        }
      }
    }
  })
}

################################################################################
# SECRETS MANAGER - ServiceNow credentials (PDF 6.8)
# Update the real value outside Terraform, e.g.:
#   aws secretsmanager put-secret-value --secret-id servicenow/aiops-demo-dev-credentials \
#     --secret-string '{"instance_url":"https://x.service-now.com","client_id":"...","client_secret":"...","username":"...","password":"..."}'
################################################################################

resource "aws_secretsmanager_secret" "servicenow" {
  name                    = "servicenow/${local.name_prefix}-credentials"
  description             = "ServiceNow API credentials for the AIOps pipeline"
  recovery_window_in_days = 0 # allows destroy + re-create with the same name
}

resource "aws_secretsmanager_secret_version" "servicenow" {
  secret_id = aws_secretsmanager_secret.servicenow.id
  secret_string = jsonencode({
    instance_url  = var.servicenow_url
    username      = var.servicenow_username
    password      = var.servicenow_password
    client_id     = ""
    client_secret = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

################################################################################
# IAM - shared policies
################################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# Least-privilege Bedrock access (PDF says scope down from FullAccess).
resource "aws_iam_policy" "bedrock_invoke" {
  name = "${local.name_prefix}-bedrock-invoke"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${local.account_id}:inference-profile/*",
        ]
      },
      {
        # Needed the first time a Marketplace-backed model is invoked in the account.
        Effect   = "Allow"
        Action   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
        Resource = "*"
      }
    ]
  })
}

################################################################################
# IAM - EC2 instance role (SSM, CloudWatch Agent, EC2 SD, bootstrap, secret)
################################################################################

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ec2_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
  ])

  role       = aws_iam_role.ec2.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "ec2_inline" {
  name = "${local.name_prefix}-ec2-inline"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PrometheusEc2Discovery"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones", "ec2:DescribeTags"]
        Resource = "*"
      },
      {
        Sid      = "BootstrapRead"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.bootstrap.arn}/${var.bootstrap_prefix}/*"
      },
      {
        Sid      = "BootstrapList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = data.aws_s3_bucket.bootstrap.arn
        Condition = {
          StringLike = { "s3:prefix" = ["${var.bootstrap_prefix}/*"] }
        }
      },
      {
        Sid      = "ServiceNowSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.servicenow.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

################################################################################
# SSH KEYS
# POC NOTE: private keys live in Terraform state. Replace with an approved
# key-management process (or SSM Session Manager only) for production.
################################################################################

resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

resource "tls_private_key" "admin_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "admin_ssh" {
  key_name   = "${local.name_prefix}-admin-key"
  public_key = tls_private_key.admin_ssh.public_key_openssh
}

resource "local_sensitive_file" "admin_ssh_pem" {
  filename        = "${path.module}/${local.name_prefix}-admin.pem"
  content         = tls_private_key.admin_ssh.private_key_pem
  file_permission = "0400"
}

resource "random_password" "grafana_admin" {
  length  = 20
  special = false
}

################################################################################
# OPEN-SOURCE AIOPS VM (Prometheus/Alertmanager/Loki/Grafana/Ollama/Qdrant/
# FastAPI/Ansible) - bootstrap script stored in the existing S3 bucket because
# of the 16 KiB user_data limit.
################################################################################

resource "aws_s3_object" "aiops_bootstrap" {
  count = var.enable_oss_aiops_vm ? 1 : 0

  bucket = data.aws_s3_bucket.bootstrap.id
  key    = "${var.bootstrap_prefix}/${local.name_prefix}/install-aiops.sh"

  content = <<-BOOTSTRAP
    #!/usr/bin/env bash
    set -euxo pipefail

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y docker.io docker-compose-v2 curl jq python3 python3-pip ansible unzip
    systemctl enable --now docker

    mkdir -p /opt/aiops/{prometheus,alertmanager,blackbox,loki,grafana/provisioning/datasources,fastapi,ansible/playbooks,keys}
    chmod 700 /opt/aiops/keys

    cat > /opt/aiops/keys/ansible_ed25519 <<'ANSIBLEKEY'
    ${tls_private_key.ansible.private_key_openssh}
    ANSIBLEKEY
    chmod 600 /opt/aiops/keys/ansible_ed25519

    ############################################################################
    # SECRETS -> .env (ServiceNow from Secrets Manager, never baked into S3)
    ############################################################################

    SN_JSON=$(aws secretsmanager get-secret-value \
      --secret-id "${aws_secretsmanager_secret.servicenow.arn}" \
      --region "${var.aws_region}" --query SecretString --output text || echo '{}')

    umask 077
    cat > /opt/aiops/.env <<ENVEOF
    SERVICENOW_URL=$(echo "$SN_JSON" | jq -r '.instance_url // ""')
    SERVICENOW_USERNAME=$(echo "$SN_JSON" | jq -r '.username // ""')
    SERVICENOW_PASSWORD=$(echo "$SN_JSON" | jq -r '.password // ""')
    GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana_admin.result}
    ENVEOF
    umask 022

    ############################################################################
    # PROMETHEUS
    ############################################################################

    cat > /opt/aiops/prometheus/prometheus.yml <<'PROMEOF'
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    rule_files:
      - /etc/prometheus/alerts.yml

    alerting:
      alertmanagers:
        - static_configs:
            - targets: ["alertmanager:9093"]

    scrape_configs:
      - job_name: "node-exporter"
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 9100
            filters:
              - name: tag:Role
                values: ["AIOpsTarget"]
              - name: instance-state-name
                values: ["running"]
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
            regex: (.+)
            target_label: __address__
            replacement: $1:9100
          - source_labels: [__meta_ec2_private_ip]
            target_label: private_ip
          - source_labels: [__meta_ec2_tag_Name]
            target_label: host
          - source_labels: [__meta_ec2_instance_id]
            target_label: instance_id

      - job_name: "blackbox-http"
        metrics_path: /probe
        params:
          module: [http_2xx]
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 8080
            filters:
              - name: tag:Role
                values: ["AIOpsTarget"]
              - name: instance-state-name
                values: ["running"]
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
            regex: (.+)
            target_label: __param_target
            replacement: http://$1:8080/
          - source_labels: [__meta_ec2_private_ip]
            target_label: private_ip
          - source_labels: [__meta_ec2_tag_Name]
            target_label: host
          - source_labels: [__meta_ec2_instance_id]
            target_label: instance_id
          - target_label: __address__
            replacement: blackbox:9115
    PROMEOF

    cat > /opt/aiops/prometheus/alerts.yml <<'ALERTEOF'
    groups:
      - name: vm-alerts
        rules:
          - alert: TargetVMMonitoringDown
            expr: up{job="node-exporter"} == 0
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "VM monitoring unavailable on {{ $labels.host }}"
              description: "Prometheus cannot scrape node_exporter on {{ $labels.host }}."

          - alert: DemoApplicationDown
            expr: probe_success{job="blackbox-http"} == 0
            for: 30s
            labels:
              severity: critical
            annotations:
              summary: "Demo application unavailable on {{ $labels.host }}"
              description: "HTTP probe failed for {{ $labels.host }}."

          - alert: HighCPU
            expr: 100 - (avg by(instance,host,instance_id,private_ip) (rate(node_cpu_seconds_total{job="node-exporter",mode="idle"}[5m])) * 100) > 85
            for: 3m
            labels:
              severity: warning
            annotations:
              summary: "High CPU on {{ $labels.host }}"
              description: "CPU has been above 85 percent for 3 minutes."

          - alert: HighMemory
            expr: (1 - (node_memory_MemAvailable_bytes{job="node-exporter"} / node_memory_MemTotal_bytes{job="node-exporter"})) * 100 > 90
            for: 3m
            labels:
              severity: critical
            annotations:
              summary: "High memory on {{ $labels.host }}"
              description: "Memory usage has been above 90 percent for 3 minutes."

          - alert: LowDiskSpace
            expr: (node_filesystem_avail_bytes{job="node-exporter",mountpoint="/"} / node_filesystem_size_bytes{job="node-exporter",mountpoint="/"}) * 100 < 15
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "Low disk space on {{ $labels.host }}"
              description: "Root filesystem has less than 15 percent free space."
    ALERTEOF

    ############################################################################
    # ALERTMANAGER -> FASTAPI WEBHOOK
    ############################################################################

    cat > /opt/aiops/alertmanager/alertmanager.yml <<'AMEOF'
    global:
      resolve_timeout: 5m

    route:
      receiver: aiops-webhook
      group_by: [alertname, host, instance_id]
      group_wait: 15s
      group_interval: 1m
      repeat_interval: 30m

    receivers:
      - name: aiops-webhook
        webhook_configs:
          - url: http://fastapi:8000/alerts
            send_resolved: true
    AMEOF

    ############################################################################
    # BLACKBOX EXPORTER
    ############################################################################

    cat > /opt/aiops/blackbox/blackbox.yml <<'BBEOF'
    modules:
      http_2xx:
        prober: http
        timeout: 5s
        http:
          preferred_ip_protocol: ip4
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: [200]
    BBEOF

    ############################################################################
    # LOKI
    ############################################################################

    cat > /opt/aiops/loki/loki.yml <<'LOKIEOF'
    auth_enabled: false

    server:
      http_listen_port: 3100

    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        instance_addr: 127.0.0.1
        kvstore:
          store: inmemory

    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h

    limits_config:
      allow_structured_metadata: true
    LOKIEOF

    ############################################################################
    # GRAFANA DATASOURCE PROVISIONING
    ############################################################################

    cat > /opt/aiops/grafana/provisioning/datasources/datasources.yml <<'GRAFANADSEOF'
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
        editable: true
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
        editable: true
    GRAFANADSEOF

    ############################################################################
    # ANSIBLE REMEDIATION PLAYBOOKS
    ############################################################################

    cat > /opt/aiops/ansible/playbooks/restart-app.yml <<'ANSIBLEEOF'
    ---
    - name: Restart AIOps demo application
      hosts: all
      become: true
      gather_facts: false
      tasks:
        - name: Restart demo application
          ansible.builtin.systemd:
            name: aiops-demo
            state: restarted
            enabled: true

        - name: Verify application service state
          ansible.builtin.command: systemctl is-active aiops-demo
          register: service_state
          changed_when: false

        - name: Show result
          ansible.builtin.debug:
            var: service_state.stdout
    ANSIBLEEOF

    ############################################################################
    # FASTAPI / RAG / SERVICENOW / REMEDIATION SERVICE
    ############################################################################

    cat > /opt/aiops/fastapi/requirements.txt <<'REQEOF'
    fastapi
    uvicorn[standard]
    requests
    qdrant-client
    REQEOF

    cat > /opt/aiops/fastapi/Dockerfile <<'DOCKEREOF'
    FROM python:3.12-slim
    RUN apt-get update && apt-get install -y ansible openssh-client && rm -rf /var/lib/apt/lists/*
    WORKDIR /app
    COPY requirements.txt .
    RUN pip install --no-cache-dir -r requirements.txt
    COPY app.py .
    CMD ["uvicorn","app:app","--host","0.0.0.0","--port","8000"]
    DOCKEREOF

    cat > /opt/aiops/fastapi/app.py <<'PYEOF'
    import json
    import os
    import subprocess
    import time
    import uuid
    from typing import Any

    import requests
    from fastapi import FastAPI, Request
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, PointStruct, VectorParams

    app = FastAPI(title="Open Source VM AIOps Demo")

    LOKI_URL = os.getenv("LOKI_URL", "http://loki:3100")
    OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
    QDRANT_HOST = os.getenv("QDRANT_HOST", "qdrant")
    QDRANT_PORT = int(os.getenv("QDRANT_PORT", "6333"))
    LLM_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2:3b")
    EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
    SN_URL = os.getenv("SERVICENOW_URL", "")
    SN_USER = os.getenv("SERVICENOW_USERNAME", "")
    SN_PASS = os.getenv("SERVICENOW_PASSWORD", "")

    COLLECTION = "incidents"
    qdrant = QdrantClient(host=QDRANT_HOST, port=QDRANT_PORT)

    SAFE_PLAYBOOKS = {
        "RESTART_APP": "/ansible/playbooks/restart-app.yml"
    }

    # Dedupe window (PDF section 4): don't re-run the LLM for the same alert.
    DEDUPE_SECONDS = int(os.getenv("DEDUPE_SECONDS", "1800"))
    _recent: dict[str, float] = {}


    def seen_recently(key: str) -> bool:
        now = time.time()
        for k in [k for k, t in _recent.items() if now - t > DEDUPE_SECONDS]:
            _recent.pop(k, None)
        if key in _recent:
            return True
        _recent[key] = now
        return False


    @app.get("/health")
    def health():
        return {"status": "ok"}


    def recent_logs(host: str) -> str:
        if not host:
            return "No host label supplied"

        end = int(time.time() * 1_000_000_000)
        start = end - (10 * 60 * 1_000_000_000)
        query = '{host="' + host + '"}'

        try:
            response = requests.get(
                f"{LOKI_URL}/loki/api/v1/query_range",
                params={
                    "query": query,
                    "start": start,
                    "end": end,
                    "limit": 250,
                    "direction": "backward",
                },
                timeout=20,
            )
            response.raise_for_status()
            return json.dumps(response.json())[:15000]
        except Exception as exc:
            return f"Loki query failed: {exc}"


    def make_embedding(text: str) -> list[float]:
        response = requests.post(
            f"{OLLAMA_URL}/api/embed",
            json={"model": EMBED_MODEL, "input": text},
            timeout=180,
        )
        response.raise_for_status()
        return response.json()["embeddings"][0]


    def ensure_collection(vector_size: int):
        names = [item.name for item in qdrant.get_collections().collections]
        if COLLECTION not in names:
            qdrant.create_collection(
                collection_name=COLLECTION,
                vectors_config=VectorParams(
                    size=vector_size,
                    distance=Distance.COSINE,
                ),
            )


    def find_similar(vector: list[float]) -> list[dict[str, Any]]:
        ensure_collection(len(vector))
        try:
            result = qdrant.query_points(
                collection_name=COLLECTION,
                query=vector,
                limit=3,
            )
            return [point.payload or {} for point in result.points]
        except Exception:
            return []


    def ask_llm(alert: dict, logs: str, history: list[dict]) -> dict:
        prompt = f"""
    You are an SRE incident analyst.

    CURRENT ALERT:
    {json.dumps(alert)}

    RELATED VM LOGS:
    {logs}

    SIMILAR PREVIOUS RESOLVED INCIDENTS:
    {json.dumps(history)}

    Return ONLY valid JSON using this schema:
    {{
      "root_cause": "brief likely root cause",
      "confidence": "low|medium|high",
      "recommended_action": "specific safe operator action",
      "remediation_id": "RESTART_APP|HUMAN_REVIEW",
      "safe_to_automate": true,
      "reasoning_summary": "brief explanation"
    }}

    Safety requirements:
    - Never invent or execute arbitrary shell commands.
    - Choose RESTART_APP only when the demo application is clearly unavailable or stopped.
    - For CPU, memory, disk, unknown, network, security or destructive conditions choose HUMAN_REVIEW.
    - If uncertain set safe_to_automate=false.
    """

        response = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={
                "model": LLM_MODEL,
                "prompt": prompt,
                "stream": False,
                "format": "json",
            },
            timeout=240,
        )
        response.raise_for_status()
        return json.loads(response.json()["response"])


    def create_servicenow(summary: str, description: str):
        if not (SN_URL and SN_USER and SN_PASS):
            return {"skipped": True, "reason": "ServiceNow not configured"}

        response = requests.post(
            f"{SN_URL.rstrip('/')}/api/now/table/incident",
            auth=(SN_USER, SN_PASS),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            json={
                "short_description": summary,
                "description": description,
                "urgency": "2",
                "impact": "2",
                "category": "software",
            },
            timeout=30,
        )
        response.raise_for_status()
        return response.json()


    def run_remediation(remediation_id: str, target_ip: str):
        playbook = SAFE_PLAYBOOKS.get(remediation_id)
        if not playbook or not target_ip:
            return {"skipped": True, "reason": "No approved remediation"}

        process = subprocess.run(
            [
                "ansible-playbook",
                "-i", f"{target_ip},",
                "-u", "ubuntu",
                "--private-key", "/keys/ansible_ed25519",
                "--ssh-common-args", "-o StrictHostKeyChecking=no",
                playbook,
            ],
            capture_output=True,
            text=True,
            timeout=180,
        )

        return {
            "returncode": process.returncode,
            "stdout": process.stdout[-8000:],
            "stderr": process.stderr[-4000:],
        }


    def remember_incident(vector: list[float], payload: dict):
        ensure_collection(len(vector))
        qdrant.upsert(
            collection_name=COLLECTION,
            points=[
                PointStruct(
                    id=str(uuid.uuid4()),
                    vector=vector,
                    payload=payload,
                )
            ],
        )


    @app.post("/knowledge")
    async def add_resolved_incident(request: Request):
        payload = await request.json()
        vector = make_embedding(json.dumps(payload))
        remember_incident(vector, payload)
        return {"stored": True, "collection": COLLECTION}


    @app.post("/alerts")
    async def alerts(request: Request):
        payload = await request.json()
        results = []

        for alert in payload.get("alerts", []):
            labels = alert.get("labels", {})
            status = alert.get("status", "firing")
            host = labels.get("host", labels.get("instance", "unknown"))
            target_ip = labels.get("private_ip", "")

            if status != "firing":
                results.append({"host": host, "status": status})
                continue

            dedupe_key = f"{labels.get('alertname')}|{host}|{alert.get('startsAt', '')}"
            if seen_recently(dedupe_key):
                results.append({"host": host, "skipped": "duplicate alert within dedupe window"})
                continue

            logs = recent_logs(host)
            context = json.dumps(alert) + "\n" + logs
            vector = make_embedding(context)
            history = find_similar(vector)
            analysis = ask_llm(alert, logs, history)

            ticket = create_servicenow(
                f"AIOps: {labels.get('alertname', 'VM alert')} on {host}",
                json.dumps(
                    {
                        "alert": alert,
                        "analysis": analysis,
                        "recent_logs": logs[:10000],
                        "similar_incidents": history,
                    },
                    indent=2,
                ),
            )

            remediation = {"skipped": True, "reason": "Human review required"}
            if analysis.get("safe_to_automate") is True:
                remediation = run_remediation(
                    analysis.get("remediation_id", "HUMAN_REVIEW"),
                    target_ip,
                )

            results.append(
                {
                    "host": host,
                    "target_ip": target_ip,
                    "analysis": analysis,
                    "ticket": ticket,
                    "remediation": remediation,
                }
            )

        return {"processed": results}
    PYEOF

    ############################################################################
    # DOCKER COMPOSE STACK
    ############################################################################

    cat > /opt/aiops/docker-compose.yml <<'COMPOSEEOF'
    services:
      prometheus:
        image: prom/prometheus:latest
        container_name: prometheus
        restart: unless-stopped
        command:
          - --config.file=/etc/prometheus/prometheus.yml
        volumes:
          - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
          - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
          - prometheus-data:/prometheus
        ports:
          - "9090:9090"

      alertmanager:
        image: prom/alertmanager:latest
        container_name: alertmanager
        restart: unless-stopped
        volumes:
          - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
        ports:
          - "9093:9093"

      blackbox:
        image: prom/blackbox-exporter:latest
        container_name: blackbox
        restart: unless-stopped
        command:
          - --config.file=/config/blackbox.yml
        volumes:
          - ./blackbox/blackbox.yml:/config/blackbox.yml:ro

      loki:
        image: grafana/loki:latest
        container_name: loki
        restart: unless-stopped
        command: -config.file=/etc/loki/loki.yml
        volumes:
          - ./loki/loki.yml:/etc/loki/loki.yml:ro
          - loki-data:/loki
        ports:
          - "3100:3100"

      grafana:
        image: grafana/grafana:latest
        container_name: grafana
        restart: unless-stopped
        env_file: [.env]
        volumes:
          - grafana-data:/var/lib/grafana
          - ./grafana/provisioning:/etc/grafana/provisioning:ro
        ports:
          - "3000:3000"
        depends_on:
          - prometheus
          - loki

      qdrant:
        image: qdrant/qdrant:latest
        container_name: qdrant
        restart: unless-stopped
        volumes:
          - qdrant-data:/qdrant/storage
        ports:
          - "6333:6333"
          - "6334:6334"

      ollama:
        image: ollama/ollama:latest
        container_name: ollama
        restart: unless-stopped
        volumes:
          - ollama-data:/root/.ollama
        ports:
          - "127.0.0.1:11434:11434"

      fastapi:
        build: ./fastapi
        container_name: fastapi
        restart: unless-stopped
        env_file: [.env]
        environment:
          LOKI_URL: http://loki:3100
          OLLAMA_URL: http://ollama:11434
          QDRANT_HOST: qdrant
          QDRANT_PORT: "6333"
          OLLAMA_MODEL: ${var.ollama_model}
          EMBED_MODEL: ${var.ollama_embedding_model}
        volumes:
          - ./ansible:/ansible:ro
          - ./keys:/keys:ro
        ports:
          - "8000:8000"
        depends_on:
          - loki
          - qdrant
          - ollama

    volumes:
      prometheus-data:
      loki-data:
      grafana-data:
      qdrant-data:
      ollama-data:
    COMPOSEEOF

    cd /opt/aiops
    docker compose up -d --build

    # Wait for Ollama, then pull local LLM + embedding models.
    for i in $(seq 1 90); do
      if curl -sf http://127.0.0.1:11434/api/tags >/dev/null; then
        break
      fi
      sleep 5
    done

    docker exec ollama ollama pull ${var.ollama_model} || true
    docker exec ollama ollama pull ${var.ollama_embedding_model} || true

    cat > /usr/local/bin/aiops-status <<'STATUSEOF'
    #!/usr/bin/env bash
    set -e
    cd /opt/aiops
    docker compose ps
    echo
    echo "FastAPI health:";    curl -sf http://localhost:8000/health || true; echo
    echo "Prometheus health:"; curl -sf http://localhost:9090/-/healthy || true; echo
    echo "Loki health:";       curl -sf http://localhost:3100/ready || true; echo
    STATUSEOF
    chmod +x /usr/local/bin/aiops-status

    echo "AIOPS BOOTSTRAP COMPLETE" | tee /dev/console
  BOOTSTRAP

  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"
}

resource "aws_instance" "aiops" {
  count = var.enable_oss_aiops_vm ? 1 : 0

  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.aiops_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.aiops.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.admin_ssh.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers (Prometheus EC2 SD) need 2 hops
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.aiops_root_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Management access first, so the VM stays reachable even if the big
  # bootstrap fails. The heavy installer runs in the background so cloud-init
  # finishes quickly; follow it with: sudo tail -f /var/log/aiops-bootstrap.log
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y curl unzip ca-certificates openssh-server ec2-instance-connect jq

    systemctl enable --now ssh

    if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
      snap install amazon-ssm-agent --classic || true
    fi
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # AWS CLI v2 (instance role supplies credentials)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    rm -rf /tmp/awscliv2
    unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
    /tmp/awscliv2/aws/install --update

    # CloudWatch Agent (metrics + logs)
    ${indent(4, local.cw_agent_install)}

    aws s3 cp \
      "s3://${var.bootstrap_bucket_name}/${var.bootstrap_prefix}/${local.name_prefix}/install-aiops.sh" \
      /usr/local/sbin/install-aiops.sh --region "${var.aws_region}"
    chmod 700 /usr/local/sbin/install-aiops.sh
    nohup /usr/local/sbin/install-aiops.sh > /var/log/aiops-bootstrap.log 2>&1 &
  USERDATA

  tags = {
    Name = "${local.name_prefix}-aiops"
    Role = "AIOpsPlatform"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_iam_role_policy.ec2_inline,
    aws_iam_role_policy_attachment.ec2_managed,
    aws_s3_object.aiops_bootstrap,
    aws_ssm_parameter.cw_agent_config,
  ]
}

resource "aws_route53_record" "aiops" {
  count = var.enable_oss_aiops_vm ? 1 : 0

  zone_id = aws_route53_zone.private.zone_id
  name    = local.aiops_dns
  type    = "A"
  ttl     = 30
  records = [aws_instance.aiops[0].private_ip]
}

################################################################################
# MONITORED APPLICATION VMs
# Demo app + node_exporter + Alloy->Loki (OSS path) + CloudWatch Agent (AWS path)
################################################################################

resource "aws_instance" "target" {
  count = var.target_vm_count

  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.target_instance_type
  subnet_id                   = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids      = [aws_security_group.target.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.admin_ssh.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.target_root_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    TARGET_NAME="${format("%s-app-%02d", local.name_prefix, count.index + 1)}"

    apt-get update
    apt-get install -y docker.io curl jq python3
    systemctl enable --now docker
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
    hostnamectl set-hostname "$TARGET_NAME"

    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    cat >> /home/ubuntu/.ssh/authorized_keys <<'PUBKEY'
    ${trimspace(tls_private_key.ansible.public_key_openssh)}
    PUBKEY
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    mkdir -p /opt/aiops-target /var/log/aiops-demo /opt/alloy

    # ---------------------------------------------------------- demo app
    cat > /opt/aiops-target/app.py <<'PYEOF'
    from http.server import HTTPServer, BaseHTTPRequestHandler
    import logging

    logging.basicConfig(
        filename="/var/log/aiops-demo/app.log",
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            logging.info("request path=%s", self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"AIOps Demo OK\n")

    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PYEOF

    cat > /etc/systemd/system/aiops-demo.service <<'SVCEOF'
    [Unit]
    Description=AIOps Demo Application
    After=network-online.target
    Wants=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/aiops-target/app.py
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    systemctl daemon-reload
    systemctl enable --now aiops-demo

    # ---------------------------------------------------------- node_exporter
    docker run -d --name node-exporter --restart unless-stopped \
      --network host --pid host -v "/:/host:ro,rslave" \
      quay.io/prometheus/node-exporter:latest --path.rootfs=/host

    # ---------------------------------------------------------- Alloy -> Loki
    cat > /opt/alloy/config.alloy <<EOF
    local.file_match "vm_logs" {
      path_targets = [
        { "__path__" = "/var/log/syslog", "job" = "system", "host" = "$TARGET_NAME" },
        { "__path__" = "/var/log/auth.log", "job" = "auth", "host" = "$TARGET_NAME" },
        { "__path__" = "/var/log/aiops-demo/*.log", "job" = "application", "host" = "$TARGET_NAME" }
      ]
    }

    loki.source.file "files" {
      targets    = local.file_match.vm_logs.targets
      forward_to = [loki.write.aiops.receiver]
    }

    loki.write "aiops" {
      endpoint {
        url = "http://${local.aiops_dns}:3100/loki/api/v1/push"
      }
    }
    EOF

    docker run -d --name alloy --restart unless-stopped --network host \
      -v /opt/alloy/config.alloy:/etc/alloy/config.alloy:ro \
      -v /var/log:/var/log:ro \
      grafana/alloy:latest run /etc/alloy/config.alloy

    # ---------------------------------------------------------- CloudWatch Agent
    ${indent(4, local.cw_agent_install)}

    echo "INFO AIOps target bootstrap completed" >> /var/log/aiops-demo/app.log
  USERDATA

  tags = {
    Name = format("%s-app-%02d", local.name_prefix, count.index + 1)
    Role = "AIOpsTarget"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_route53_record.aiops,
    aws_ssm_parameter.cw_agent_config,
    aws_iam_role_policy_attachment.ec2_managed,
  ]
}

################################################################################
# DATABASES - RDS PostgreSQL with Performance Insights + Enhanced Monitoring
# (PDF 6.4). For EXISTING databases run the aws rds modify-db-instance command
# from the PDF using the monitoring role ARN from `terraform output`.
################################################################################

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_security_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name        = "${local.name_prefix}-rds-sg"
  description = "PostgreSQL from AIOps VM and target VMs"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_vms" {
  for_each = { for k, v in {
    aiops  = aws_security_group.aiops.id
    target = aws_security_group.target.id
  } : k => v if var.enable_rds }

  security_group_id            = aws_security_group.rds[0].id
  referenced_security_group_id = each.value
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_db_subnet_group" "rds" {
  count = var.enable_rds ? 1 : 0

  name       = "${local.name_prefix}-rds-subnets"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "demo" {
  count = var.enable_rds ? 1 : 0

  identifier                  = "${local.name_prefix}-pg"
  engine                      = "postgres"
  engine_version              = var.rds_engine_version
  instance_class              = var.rds_instance_class
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "aiops"
  username                    = "aiopsadmin"
  manage_master_user_password = true # password lives in Secrets Manager
  db_subnet_group_name        = aws_db_subnet_group.rds[0].name
  vpc_security_group_ids      = [aws_security_group.rds[0].id]
  publicly_accessible         = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql"]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  depends_on = [aws_iam_role_policy_attachment.rds_monitoring]
}

################################################################################
# DETECTION - CloudWatch alarms (trigger the RAG Lambda via EventBridge)
# Alarm names MUST start with "<name_prefix>-" to be routed to the pipeline.
################################################################################

resource "aws_cloudwatch_metric_alarm" "target_cpu" {
  count = var.target_vm_count

  alarm_name          = "${local.name_prefix}-app-${format("%02d", count.index + 1)}-high-cpu"
  alarm_description   = "CPU above 85% for 3 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.target[count.index].id }
}

resource "aws_cloudwatch_metric_alarm" "target_memory" {
  count = var.target_vm_count

  alarm_name          = "${local.name_prefix}-app-${format("%02d", count.index + 1)}-high-memory"
  alarm_description   = "Memory above 90% for 3 minutes (CloudWatch Agent)"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { InstanceId = aws_instance.target[count.index].id }
}

resource "aws_cloudwatch_metric_alarm" "target_status" {
  count = var.target_vm_count

  alarm_name          = "${local.name_prefix}-app-${format("%02d", count.index + 1)}-status-check"
  alarm_description   = "EC2 status check failing"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.target[count.index].id }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.enable_rds ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-high-cpu"
  alarm_description   = "RDS CPU above 80% for 5 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.demo[0].identifier }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count = var.enable_rds ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-low-storage"
  alarm_description   = "RDS free storage below 2 GiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.demo[0].identifier }
}

################################################################################
# DETECTION - Amazon DevOps Guru (PDF 6.5), scoped by tag
################################################################################

resource "aws_devopsguru_resource_collection" "aiops" {
  count = var.enable_devops_guru ? 1 : 0

  type = "AWS_TAGS"
  tags {
    app_boundary_key = local.devops_guru_tag_key
    tag_values       = [local.name_prefix]
  }
}

################################################################################
# RAG VECTOR STORE - OpenSearch with k-NN (PDF 6.6)
# Public HTTPS endpoint protected by an IAM resource policy (only the RAG
# Lambda role can call it), so the Lambda needs no VPC/NAT.
################################################################################

resource "aws_opensearch_domain" "vectors" {
  count = var.enable_opensearch ? 1 : 0

  domain_name    = "${local.name_prefix}-vectors"
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = var.opensearch_instance_count
    zone_awareness_enabled = var.opensearch_instance_count > 1

    dynamic "zone_awareness_config" {
      for_each = var.opensearch_instance_count > 1 ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_gb
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.rag_lambda.arn }
      Action    = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete"]
      Resource  = "arn:aws:es:${var.aws_region}:${local.account_id}:domain/${local.name_prefix}-vectors/*"
    }]
  })

  depends_on = [aws_iam_role_policy.rag_lambda]
}

################################################################################
# RAG PIPELINE LAMBDA (PDF 3 + 6.7) + dedupe table (PDF 4)
################################################################################

resource "aws_dynamodb_table" "dedupe" {
  name         = "${local.name_prefix}-anomaly-dedupe"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

resource "aws_iam_role" "rag_lambda" {
  name = "${local.name_prefix}-rag-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rag_lambda_basic" {
  role       = aws_iam_role.rag_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rag_lambda_bedrock" {
  role       = aws_iam_role.rag_lambda.name
  policy_arn = aws_iam_policy.bedrock_invoke.arn
}

resource "aws_iam_role_policy" "rag_lambda" {
  name = "${local.name_prefix}-rag-lambda"
  role = aws_iam_role.rag_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Dedupe"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.dedupe.arn
      },
      {
        Sid      = "OpenSearch"
        Effect   = "Allow"
        Action   = ["es:ESHttpGet", "es:ESHttpHead", "es:ESHttpPost", "es:ESHttpPut", "es:ESHttpDelete"]
        Resource = "arn:aws:es:${var.aws_region}:${local.account_id}:domain/${local.name_prefix}-vectors/*"
      },
      {
        Sid      = "ServiceNowSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.servicenow.arn
      },
      {
        Sid      = "ReadVmLogs"
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents"]
        Resource = "${aws_cloudwatch_log_group.vms.arn}:*"
      },
      {
        Sid      = "DescribeEks"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${local.account_id}:cluster/*"
      }
    ]
  })
}

locals {
  rag_handler_py = <<-PYEOF
    """AIOps RAG pipeline (PDF sections 3 / 6.7).

    Triggers:
      * EventBridge: DevOps Guru "New Insight Open"
      * EventBridge: CloudWatch alarm -> ALARM (alarms named <prefix>-*)
      * EventBridge schedule: poll k8sgpt Result CRs on EKS
      * Manual invoke: {"action": "test"} | {"action": "add_incident", "incident": {...}}
                       | {"action": "poll_k8sgpt"}

    Flow: dedupe -> embed (Titan v2) -> k-NN search past incidents (OpenSearch)
          -> LLM RCA (Bedrock Converse) -> ServiceNow incident (secret in Secrets Manager).
    No third-party dependencies: only boto3/botocore from the Lambda runtime.
    """
    import base64
    import hashlib
    import json
    import os
    import ssl
    import time
    import urllib.error
    import urllib.parse
    import urllib.request

    import boto3
    from botocore.auth import SigV4Auth
    from botocore.awsrequest import AWSRequest
    from botocore.signers import RequestSigner

    REGION = os.environ.get("AWS_REGION", "us-east-1")
    OS_ENDPOINT = os.environ.get("OPENSEARCH_ENDPOINT", "")
    OS_INDEX = os.environ.get("OPENSEARCH_INDEX", "incidents")
    EMBED_MODEL = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
    EMBED_DIM = int(os.environ.get("EMBED_DIMENSIONS", "1024"))
    LLM_MODEL = os.environ.get("LLM_MODEL_ID", "")
    SECRET_ID = os.environ.get("SERVICENOW_SECRET_ID", "")
    DEDUPE_TABLE = os.environ.get("DEDUPE_TABLE", "")
    DEDUPE_TTL = int(os.environ.get("DEDUPE_TTL_SECONDS", "3600"))
    VM_LOG_GROUP = os.environ.get("VM_LOG_GROUP", "")
    EKS_CLUSTER = os.environ.get("EKS_CLUSTER_NAME", "")
    K8SGPT_NS = os.environ.get("K8SGPT_NAMESPACE", "k8sgpt")
    MAX_PER_RUN = int(os.environ.get("MAX_ANOMALIES_PER_RUN", "10"))

    session = boto3.session.Session()
    bedrock = session.client("bedrock-runtime", region_name=REGION)
    ddb = session.client("dynamodb", region_name=REGION)
    logs = session.client("logs", region_name=REGION)
    secrets = session.client("secretsmanager", region_name=REGION)
    eks = session.client("eks", region_name=REGION)

    PROMPT = """You are an SRE assistant. A new anomaly was detected:
    {anomaly}

    Here are the {count} most similar past incidents and how they were resolved:
    {history}

    Based on this, respond with ONLY one JSON object (no prose) with these keys:
      "root_cause": likely root cause (string)
      "confidence": "low" | "medium" | "high"
      "remediation_steps": list of specific steps, exact commands where applicable
      "safe_to_auto_remediate": true or false
      "reasoning_summary": short explanation (string)
    Never mark destructive, security, data-loss or unknown conditions as safe to auto-remediate."""


    # --------------------------------------------------------------------------- #
    # HTTP helpers
    # --------------------------------------------------------------------------- #
    def http_json(url, method="GET", body=None, headers=None, data=None, timeout=30, context=None):
        if body is not None:
            data = json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
        with urllib.request.urlopen(req, timeout=timeout, context=context) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else {}


    def os_request(method, path, body=None):
        """SigV4-signed request to the OpenSearch domain. Returns None on 404."""
        url = f"https://{OS_ENDPOINT}{path}"
        data = json.dumps(body).encode() if body is not None else None
        aws_req = AWSRequest(method=method, url=url, data=data, headers={"Content-Type": "application/json"})
        SigV4Auth(session.get_credentials(), "es", REGION).add_auth(aws_req)
        req = urllib.request.Request(url, data=data, method=method, headers=dict(aws_req.headers.items()))
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise RuntimeError(f"OpenSearch {method} {path} -> {exc.code}: {exc.read()[:500]!r}")


    # --------------------------------------------------------------------------- #
    # Vector store (OpenSearch k-NN)
    # --------------------------------------------------------------------------- #
    _index_ready = False


    def ensure_index():
        global _index_ready
        if _index_ready or not OS_ENDPOINT:
            return
        if os_request("HEAD", f"/{OS_INDEX}") is None:
            mapping = {
                "settings": {"index": {"knn": True}},
                "mappings": {
                    "properties": {
                        "embedding": {
                            "type": "knn_vector",
                            "dimension": EMBED_DIM,
                            "method": {"name": "hnsw", "engine": "lucene", "space_type": "cosinesimil"},
                        },
                        "text": {"type": "text"},
                        "title": {"type": "text"},
                        "root_cause": {"type": "text"},
                        "resolution": {"type": "text"},
                        "created_at": {"type": "date"},
                    }
                },
            }
            try:
                os_request("PUT", f"/{OS_INDEX}", mapping)
            except RuntimeError as exc:
                if "resource_already_exists" not in str(exc):
                    raise
        _index_ready = True


    def embed(text):
        resp = bedrock.invoke_model(
            modelId=EMBED_MODEL,
            contentType="application/json",
            accept="application/json",
            body=json.dumps({"inputText": text[:30000], "dimensions": EMBED_DIM, "normalize": True}),
        )
        return json.loads(resp["body"].read())["embedding"]


    def similar_incidents(vector, k=3):
        if not OS_ENDPOINT:
            return []
        ensure_index()
        res = os_request(
            "POST",
            f"/{OS_INDEX}/_search",
            {"size": k, "_source": {"excludes": ["embedding"]}, "query": {"knn": {"embedding": {"vector": vector, "k": k}}}},
        )
        hits = (res or {}).get("hits", {}).get("hits", [])
        return [dict(h.get("_source", {}), score=h.get("_score")) for h in hits]


    def store_incident(incident):
        """Feed a resolved incident back into the RAG store (PDF section 5)."""
        if not OS_ENDPOINT:
            return {"stored": False, "reason": "OpenSearch disabled"}
        text = "\n".join(
            f"{key}: {incident.get(key, '')}"
            for key in ("title", "symptoms", "logs", "root_cause", "resolution")
            if incident.get(key)
        ) or json.dumps(incident)
        doc = dict(incident)
        doc.update({"text": text, "embedding": embed(text), "created_at": int(time.time() * 1000)})
        ensure_index()
        res = os_request("POST", f"/{OS_INDEX}/_doc?refresh=true", doc)
        return {"stored": True, "id": (res or {}).get("_id")}


    # --------------------------------------------------------------------------- #
    # LLM reasoning (Bedrock Converse API - works for any Bedrock chat model)
    # --------------------------------------------------------------------------- #
    def analyse(anomaly_text, history):
        prompt = PROMPT.format(
            anomaly=anomaly_text[:20000],
            count=len(history),
            history=json.dumps(history, indent=2, default=str)[:12000] or "none",
        )
        resp = bedrock.converse(
            modelId=LLM_MODEL,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": 1500, "temperature": 0.2},
        )
        text = resp["output"]["message"]["content"][0]["text"]
        start, end = text.find("{"), text.rfind("}")
        try:
            return json.loads(text[start : end + 1])
        except Exception:
            return {"root_cause": "LLM response was not valid JSON", "confidence": "low",
                    "safe_to_auto_remediate": False, "raw": text[:4000]}


    # --------------------------------------------------------------------------- #
    # ServiceNow (credentials pulled from Secrets Manager at runtime - PDF 6.8)
    # --------------------------------------------------------------------------- #
    _sn_cfg = None


    def sn_config():
        global _sn_cfg
        if _sn_cfg is None:
            try:
                _sn_cfg = json.loads(secrets.get_secret_value(SecretId=SECRET_ID)["SecretString"])
            except Exception as exc:
                print(f"ServiceNow secret unavailable: {exc}")
                _sn_cfg = {}
        return _sn_cfg


    def create_ticket(short_description, description, urgency="2"):
        cfg = sn_config()
        base = (cfg.get("instance_url") or "").rstrip("/")
        if not base:
            return {"skipped": True, "reason": "ServiceNow not configured (instance_url empty in secret)"}

        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if cfg.get("client_id") and cfg.get("client_secret"):
            form = {"client_id": cfg["client_id"], "client_secret": cfg["client_secret"]}
            if cfg.get("username"):
                form.update(grant_type="password", username=cfg["username"], password=cfg.get("password", ""))
            else:
                form.update(grant_type="client_credentials")
            token = http_json(
                f"{base}/oauth_token.do",
                method="POST",
                data=urllib.parse.urlencode(form).encode(),
                headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
            )
            headers["Authorization"] = "Bearer " + token["access_token"]
        elif cfg.get("username"):
            basic = base64.b64encode(f"{cfg['username']}:{cfg.get('password', '')}".encode()).decode()
            headers["Authorization"] = "Basic " + basic
        else:
            return {"skipped": True, "reason": "No ServiceNow credentials in secret"}

        res = http_json(
            f"{base}/api/now/table/incident",
            method="POST",
            headers=headers,
            body={
                "short_description": short_description[:160],
                "description": description[:30000],
                "urgency": urgency,
                "impact": "2",
                "category": "software",
            },
        )
        result = res.get("result", {})
        return {"number": result.get("number"), "sys_id": result.get("sys_id")}


    # --------------------------------------------------------------------------- #
    # Dedupe / correlation (PDF section 4: don't re-run RAG 50x for one alert)
    # --------------------------------------------------------------------------- #
    def first_time(key, ttl):
        if not DEDUPE_TABLE:
            return True
        now = int(time.time())
        try:
            ddb.put_item(
                TableName=DEDUPE_TABLE,
                Item={"pk": {"S": key}, "expires_at": {"N": str(now + ttl)}},
                ConditionExpression="attribute_not_exists(pk) OR expires_at < :now",
                ExpressionAttributeValues={":now": {"N": str(now)}},
            )
            return True
        except ddb.exceptions.ConditionalCheckFailedException:
            return False


    def forget(key):
        if DEDUPE_TABLE:
            try:
                ddb.delete_item(TableName=DEDUPE_TABLE, Key={"pk": {"S": key}})
            except Exception:
                pass


    # --------------------------------------------------------------------------- #
    # Event sources
    # --------------------------------------------------------------------------- #
    def recent_vm_logs(instance_id, minutes=15, limit=100):
        if not (VM_LOG_GROUP and instance_id):
            return ""
        try:
            res = logs.filter_log_events(
                logGroupName=VM_LOG_GROUP,
                logStreamNamePrefix=instance_id,
                startTime=int((time.time() - minutes * 60) * 1000),
                limit=limit,
            )
            return "\n".join(e["message"] for e in res.get("events", []))[-8000:]
        except Exception as exc:
            return f"(log lookup failed: {exc})"


    def from_cloudwatch_alarm(event):
        detail = event.get("detail", {})
        if detail.get("state", {}).get("value") != "ALARM":
            return None
        instance_id = ""
        for metric in detail.get("configuration", {}).get("metrics", []):
            dims = metric.get("metricStat", {}).get("metric", {}).get("dimensions", {})
            instance_id = instance_id or dims.get("InstanceId", "")
        name = detail.get("alarmName", "unknown-alarm")
        started = detail.get("state", {}).get("timestamp", "")
        return {
            "key": f"cw-{name}-{started}",
            "title": f"CloudWatch alarm {name}",
            "instance_id": instance_id,
            "urgency": "2",
            "details": json.dumps(
                {"source": "CloudWatch alarm", "alarm": name, "reason": detail.get("state", {}).get("reason"),
                 "configuration": detail.get("configuration"), "resources": event.get("resources")},
                indent=2, default=str),
        }


    def from_devops_guru(event):
        detail = event.get("detail", {})
        insight = detail.get("insightId", event.get("id"))
        severity = str(detail.get("insightSeverity", "medium")).lower()
        return {
            "key": f"guru-{insight}",
            "title": f"DevOps Guru {severity} insight {detail.get('insightDescription', insight)}",
            "urgency": "1" if severity == "high" else "2",
            "details": json.dumps({"source": "Amazon DevOps Guru", "detail": detail}, indent=2, default=str)[:20000],
        }


    def eks_token(cluster):
        sts = session.client("sts", region_name=REGION)
        signer = RequestSigner(sts.meta.service_model.service_id, REGION, "sts", "v4",
                               session.get_credentials(), session.events)
        url = signer.generate_presigned_url(
            {
                "method": "GET",
                "url": f"https://sts.{REGION}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
                "body": {},
                "headers": {"x-k8s-aws-id": cluster},
                "context": {},
            },
            region_name=REGION,
            expires_in=60,
            operation_name="",
        )
        return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


    def from_k8sgpt():
        if not EKS_CLUSTER:
            return []
        cluster = eks.describe_cluster(name=EKS_CLUSTER)["cluster"]
        ctx = ssl.create_default_context(cadata=base64.b64decode(cluster["certificateAuthority"]["data"]).decode())
        data = http_json(
            f"{cluster['endpoint']}/apis/core.k8sgpt.ai/v1alpha1/namespaces/{K8SGPT_NS}/results",
            headers={"Authorization": "Bearer " + eks_token(EKS_CLUSTER), "Accept": "application/json"},
            context=ctx,
        )
        found = []
        for item in data.get("items", []):
            spec = item.get("spec", {})
            errors = [e.get("text", "") for e in (spec.get("error") or [])]
            digest = hashlib.sha256(json.dumps([spec.get("kind"), spec.get("name"), errors]).encode()).hexdigest()[:24]
            details = (
                f"EKS cluster {EKS_CLUSTER} - k8sgpt finding\n"
                f"Kind: {spec.get('kind')}\nObject: {spec.get('name')}\nParent: {spec.get('parentObject')}\n"
                "Errors:\n- " + "\n- ".join(errors) + f"\n\nk8sgpt explanation:\n{spec.get('details', '')}"
            )
            found.append({"key": f"k8sgpt-{digest}", "title": f"EKS {spec.get('kind')} {spec.get('name')}",
                          "details": details, "urgency": "2", "ttl": 86400})
        return found


    # --------------------------------------------------------------------------- #
    # Pipeline
    # --------------------------------------------------------------------------- #
    def process(anomaly):
        key = anomaly["key"]
        if not first_time(key, anomaly.get("ttl", DEDUPE_TTL)):
            return {"key": key, "skipped": "duplicate within dedupe window"}
        try:
            text = anomaly["details"]
            if anomaly.get("instance_id"):
                text += "\n\nRecent VM logs (CloudWatch Logs):\n" + recent_vm_logs(anomaly["instance_id"])
            vector = embed(text)
            history = similar_incidents(vector)
            analysis = analyse(text, history)
            description = json.dumps(
                {"anomaly": text[:20000], "llm_analysis": analysis, "similar_past_incidents": history},
                indent=2, default=str)
            ticket = create_ticket(f"AIOps: {anomaly['title']}", description, anomaly.get("urgency", "2"))
            result = {"key": key, "title": anomaly["title"], "analysis": analysis, "ticket": ticket,
                      "similar_count": len(history)}
            print(json.dumps(result, default=str))
            return result
        except Exception as exc:
            forget(key)  # allow a retry on the next event
            print(f"ERROR processing {key}: {exc}")
            return {"key": key, "error": str(exc)}


    def handler(event, context):
        event = event or {}
        action = event.get("action")
        source = event.get("source")

        if action == "add_incident":
            return store_incident(event.get("incident", {}))

        if action == "test":
            anomalies = [{
                "key": f"test-{int(time.time())}",
                "title": "AIOps pipeline test",
                "urgency": "3",
                "details": event.get("details", "Synthetic test anomaly: demo app on port 8080 returns HTTP 500 "
                                                "after a deploy; systemd shows aiops-demo restarting repeatedly."),
            }]
        elif source == "aws.cloudwatch":
            anomalies = [from_cloudwatch_alarm(event)]
        elif source == "aws.devops-guru":
            anomalies = [from_devops_guru(event)]
        elif source == "aws.events" or action == "poll_k8sgpt":
            anomalies = from_k8sgpt()
        else:
            return {"ignored": True, "reason": "unrecognised event"}

        anomalies = [a for a in anomalies if a][:MAX_PER_RUN]
        return {"processed": [process(a) for a in anomalies]}
  PYEOF
}

data "archive_file" "rag" {
  type        = "zip"
  output_path = "${path.module}/.build/rag-pipeline.zip"

  source {
    content  = local.rag_handler_py
    filename = "rag_handler.py"
  }
}

resource "aws_cloudwatch_log_group" "rag" {
  name              = "/aws/lambda/${local.name_prefix}-rag-handler"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "rag" {
  function_name    = "${local.name_prefix}-rag-handler"
  role             = aws_iam_role.rag_lambda.arn
  runtime          = "python3.12"
  handler          = "rag_handler.handler"
  filename         = data.archive_file.rag.output_path
  source_code_hash = data.archive_file.rag.output_base64sha256
  timeout          = 180
  memory_size      = 512

  environment {
    variables = {
      OPENSEARCH_ENDPOINT   = try(aws_opensearch_domain.vectors[0].endpoint, "")
      OPENSEARCH_INDEX      = "incidents"
      EMBED_MODEL_ID        = var.bedrock_embedding_model_id
      EMBED_DIMENSIONS      = tostring(var.embedding_dimensions)
      LLM_MODEL_ID          = var.bedrock_llm_model_id
      SERVICENOW_SECRET_ID  = aws_secretsmanager_secret.servicenow.arn
      DEDUPE_TABLE          = aws_dynamodb_table.dedupe.name
      DEDUPE_TTL_SECONDS    = "3600"
      VM_LOG_GROUP          = aws_cloudwatch_log_group.vms.name
      EKS_CLUSTER_NAME      = var.enable_eks ? local.eks_name : ""
      K8SGPT_NAMESPACE      = "k8sgpt"
      MAX_ANOMALIES_PER_RUN = "10"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.rag,
    aws_iam_role_policy.rag_lambda,
    aws_iam_role_policy_attachment.rag_lambda_basic,
  ]
}

# ---------------------------------------------------------------- EventBridge
locals {
  rag_rules_all = {
      cw-alarms = {
        enabled     = true
        description = "CloudWatch alarms entering ALARM -> RAG pipeline"
        pattern = jsonencode({
          source        = ["aws.cloudwatch"]
          "detail-type" = ["CloudWatch Alarm State Change"]
          detail = {
            alarmName = [{ prefix = "${local.name_prefix}-" }]
            state     = { value = ["ALARM"] }
          }
        })
        schedule = null
      }
      devopsguru = {
        enabled     = var.enable_devops_guru
        description = "DevOps Guru new insights -> RAG pipeline"
        pattern = jsonencode({
          source        = ["aws.devops-guru"]
          "detail-type" = ["DevOps Guru New Insight Open"]
        })
        schedule = null
      }
      k8sgpt-poll = {
        enabled     = var.enable_eks
        description = "Poll k8sgpt results every 10 minutes -> RAG pipeline"
        pattern     = null
        schedule    = "rate(10 minutes)"
      }
  }
  rag_rules = { for k, v in local.rag_rules_all : k => v if v.enabled }
}

resource "aws_cloudwatch_event_rule" "rag" {
  for_each = local.rag_rules

  name                = "${local.name_prefix}-${each.key}-to-rag"
  description         = each.value.description
  event_pattern       = each.value.pattern
  schedule_expression = each.value.schedule
}

resource "aws_cloudwatch_event_target" "rag" {
  for_each = local.rag_rules

  rule      = aws_cloudwatch_event_rule.rag[each.key].name
  target_id = "rag-lambda"
  arn       = aws_lambda_function.rag.arn
}

resource "aws_lambda_permission" "rag" {
  for_each = local.rag_rules

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rag.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rag[each.key].arn
}

################################################################################
# EKS (PDF 6.3) - new cluster, or an existing one via existing_eks_cluster_name
################################################################################

data "aws_eks_cluster" "existing" {
  count = var.enable_eks && !local.create_eks ? 1 : 0
  name  = var.existing_eks_cluster_name
}

module "eks" {
  count   = local.create_eks ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name                             = "${local.name_prefix}-eks"
  cluster_version                          = var.eks_version
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD" # AL2 AMIs are not published for k8s >= 1.33
      instance_types = [var.eks_node_instance_type]
      min_size       = 1
      max_size       = 3
      desired_size   = var.eks_node_desired

      # Fallbacks in case a workload does not pick up its Pod Identity role.
      iam_role_additional_policies = {
        bedrock    = aws_iam_policy.bedrock_invoke.arn
        cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      }
    }
  }
}

# ------------------------------------------------ Pod Identity roles (IRSA successor)
locals {
  pod_identities = { for k, v in {
    fluent-bit = { namespace = "logging", service_account = "fluent-bit" }
    k8sgpt     = { namespace = "k8sgpt", service_account = "k8sgpt" }
    aiops-sa   = { namespace = "aiops", service_account = "aiops-sa" }
  } : k => v if var.enable_eks }
}

resource "aws_iam_role" "pod" {
  for_each = local.pod_identities

  name               = "${local.name_prefix}-pod-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "pod_bedrock" {
  for_each = { for k, v in local.pod_identities : k => v if k != "fluent-bit" }

  role       = aws_iam_role.pod[each.key].name
  policy_arn = aws_iam_policy.bedrock_invoke.arn
}

resource "aws_iam_role_policy" "pod_fluent_bit_logs" {
  count = var.enable_eks ? 1 : 0

  name = "cloudwatch-logs"
  role = aws_iam_role.pod["fluent-bit"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
      Resource = ["${aws_cloudwatch_log_group.eks[0].arn}", "${aws_cloudwatch_log_group.eks[0].arn}:*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "pod" {
  for_each = local.pod_identities

  cluster_name    = local.eks_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.pod[each.key].arn

  depends_on = [module.eks]
}

# ------------------------------------------------ Lambda read access to k8sgpt results
resource "aws_eks_access_entry" "rag_lambda" {
  count = var.enable_eks ? 1 : 0

  cluster_name      = local.eks_name
  principal_arn     = aws_iam_role.rag_lambda.arn
  kubernetes_groups = ["aiops-k8sgpt-readers"]
  type              = "STANDARD"

  depends_on = [module.eks]
}

resource "kubectl_manifest" "k8sgpt_results_reader" {
  count = var.enable_eks ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: aiops-k8sgpt-results-reader
    rules:
      - apiGroups: ["core.k8sgpt.ai"]
        resources: ["results"]
        verbs: ["get", "list", "watch"]
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "k8sgpt_results_reader_binding" {
  count = var.enable_eks ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: aiops-k8sgpt-results-reader
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: aiops-k8sgpt-results-reader
    subjects:
      - apiGroup: rbac.authorization.k8s.io
        kind: Group
        name: aiops-k8sgpt-readers
  YAML

  depends_on = [kubectl_manifest.k8sgpt_results_reader]
}

# ------------------------------------------------ aiops namespace + aiops-sa (PDF 6.3)
resource "kubectl_manifest" "aiops_namespace" {
  count = var.enable_eks ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: aiops
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "aiops_sa" {
  count = var.enable_eks ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: aiops-sa
      namespace: aiops
  YAML

  depends_on = [kubectl_manifest.aiops_namespace]
}

# ------------------------------------------------ Fluent Bit DaemonSet -> CloudWatch Logs
resource "helm_release" "fluent_bit" {
  count = var.enable_eks ? 1 : 0

  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  namespace        = "logging"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    serviceAccount = { create = true, name = "fluent-bit" }
    config = {
      outputs = <<-EOT
        [OUTPUT]
            Name              cloudwatch_logs
            Match             *
            region            ${var.aws_region}
            log_group_name    ${local.eks_log_grp}
            log_stream_prefix eks-
            auto_create_group Off
      EOT
    }
  })]

  depends_on = [module.eks, aws_eks_pod_identity_association.pod]
}

# ------------------------------------------------ Prometheus + kube-state-metrics
resource "helm_release" "kube_prometheus" {
  count = var.enable_eks ? 1 : 0

  name             = "kube-prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900

  values = [yamlencode({
    grafana = { adminPassword = random_password.grafana_admin.result }
  })]

  depends_on = [module.eks]
}

# ------------------------------------------------ k8sgpt operator + Bedrock backend
resource "helm_release" "k8sgpt_operator" {
  count = var.enable_eks ? 1 : 0

  name             = "k8sgpt-operator"
  repository       = "https://charts.k8sgpt.ai/"
  chart            = "k8sgpt-operator"
  namespace        = "k8sgpt"
  create_namespace = true
  timeout          = 600

  depends_on = [module.eks]
}

resource "kubectl_manifest" "k8sgpt_bedrock" {
  count = var.enable_eks ? 1 : 0

  yaml_body = <<-YAML
    apiVersion: core.k8sgpt.ai/v1alpha1
    kind: K8sGPT
    metadata:
      name: k8sgpt-bedrock
      namespace: k8sgpt
    spec:
      ai:
        enabled: true
        backend: amazonbedrock
        model: ${var.k8sgpt_bedrock_model}
        region: ${var.aws_region}
        anonymized: true
      noCache: false
      repository: ghcr.io/k8sgpt-ai/k8sgpt
      version: ${var.k8sgpt_version}
  YAML

  depends_on = [helm_release.k8sgpt_operator, aws_eks_pod_identity_association.pod]
}

################################################################################
# OUTPUTS
################################################################################

output "aiops_public_ip" {
  value = try(aws_instance.aiops[0].public_ip, null)
}

output "ssh_aiops" {
  description = "Run after: terraform output -raw admin_private_key_pem > ~/.ssh/aiops-admin.pem && chmod 600 ~/.ssh/aiops-admin.pem"
  value       = try("ssh -i ~/.ssh/aiops-admin.pem ubuntu@${aws_instance.aiops[0].public_ip}", null)
}

output "ssm_aiops" {
  value = try("aws ssm start-session --target ${aws_instance.aiops[0].id} --region ${var.aws_region}", null)
}

output "admin_private_key_pem" {
  description = "Admin SSH key for all VMs (works even when terraform ran on an ephemeral CI runner)"
  value       = tls_private_key.admin_ssh.private_key_pem
  sensitive   = true
}

output "grafana_url" {
  value = try("http://${aws_instance.aiops[0].public_ip}:3000", null)
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}

output "target_private_ips" {
  value = aws_instance.target[*].private_ip
}

output "rag_lambda_name" {
  value = aws_lambda_function.rag.function_name
}

output "servicenow_secret_name" {
  value = aws_secretsmanager_secret.servicenow.name
}

output "opensearch_endpoint" {
  value = try(aws_opensearch_domain.vectors[0].endpoint, null)
}

output "rds_endpoint" {
  value = try(aws_db_instance.demo[0].endpoint, null)
}

output "rds_monitoring_role_arn" {
  description = "Use with aws rds modify-db-instance for EXISTING databases"
  value       = aws_iam_role.rds_monitoring.arn
}

output "eks_cluster_name" {
  value = var.enable_eks ? local.eks_name : null
}

output "eks_kubeconfig_command" {
  value = var.enable_eks ? "aws eks update-kubeconfig --name ${local.eks_name} --region ${var.aws_region}" : null
}

output "vm_log_group" {
  value = aws_cloudwatch_log_group.vms.name
}
