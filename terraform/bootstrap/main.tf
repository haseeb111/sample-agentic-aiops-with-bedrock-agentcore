# ==========================================================
# 0. LOCAL HELPER & SECRETS MANAGER PROVISIONING
# ==========================================================

terraform {
  backend "s3" {
    bucket         = "aiops-terraform-tfstate01"
    key            = "dev-aiops.tfstate"
    region         = "us-east-1"
  }

}


terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Solution    = "OpenSource-VM-AIOps"
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
  description = "Your public IP/CIDR allowed to open Grafana, Prometheus, Alertmanager, FastAPI and Qdrant. Set to YOUR.PUBLIC.IP/32."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.50.1.0/24"
}

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
  description = "AIOps VM. 16 GiB RAM is recommended for a small local Ollama model."
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

variable "servicenow_url" {
  description = "Optional ServiceNow base URL, for example https://example.service-now.com. Leave empty to skip ticket creation."
  type        = string
  default     = ""
}

variable "servicenow_username" {
  description = "Optional ServiceNow API username. Demo only; prefer OAuth/OpenBao for production."
  type        = string
  default     = ""
  sensitive   = true
}

variable "servicenow_password" {
  description = "Optional ServiceNow API password. Demo only; prefer OAuth/OpenBao for production."
  type        = string
  default     = ""
  sensitive   = true
}

################################################################################
# LOCALS / DATA
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  az          = data.aws_availability_zones.available.names[0]
  aiops_dns   = "aiops.aiops.internal"
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
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-snet"
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
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

################################################################################
# SECURITY GROUPS
#
# IMPORTANT:
# The security groups are created first WITHOUT cross-referencing ingress rules.
# Cross-security-group rules are created separately below with
# aws_vpc_security_group_ingress_rule resources. This prevents the Terraform
# dependency cycle:
#   aws_security_group.aiops <-> aws_security_group.target
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

################################################################################
# AIOPS SECURITY GROUP INGRESS RULES
################################################################################

resource "aws_vpc_security_group_ingress_rule" "aiops_grafana" {
  security_group_id = aws_security_group.aiops.id
  description       = "Grafana UI from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aiops_fastapi" {
  security_group_id = aws_security_group.aiops.id
  description       = "FastAPI from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 8000
  to_port           = 8000
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aiops_prometheus" {
  security_group_id = aws_security_group.aiops.id
  description       = "Prometheus UI from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aiops_alertmanager" {
  security_group_id = aws_security_group.aiops.id
  description       = "Alertmanager UI from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 9093
  to_port           = 9093
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aiops_qdrant" {
  security_group_id = aws_security_group.aiops.id
  description       = "Qdrant UI/API from admin CIDR"
  cidr_ipv4         = var.admin_cidr
  from_port         = 6333
  to_port           = 6333
  ip_protocol       = "tcp"
}

# Target VMs push logs to Loki running on the AIOps VM.
resource "aws_vpc_security_group_ingress_rule" "aiops_loki_from_targets" {
  security_group_id            = aws_security_group.aiops.id
  description                  = "Loki ingestion from monitored VMs"
  referenced_security_group_id = aws_security_group.target.id
  from_port                    = 3100
  to_port                      = 3100
  ip_protocol                  = "tcp"
}

################################################################################
# TARGET VM SECURITY GROUP INGRESS RULES
################################################################################

# Prometheus running on the AIOps VM scrapes node_exporter on the target VMs.
resource "aws_vpc_security_group_ingress_rule" "target_node_exporter_from_aiops" {
  security_group_id            = aws_security_group.target.id
  description                  = "Prometheus node_exporter scrape from AIOps VM"
  referenced_security_group_id = aws_security_group.aiops.id
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
}

# Ansible running on the AIOps VM remediates target VMs over private SSH.
resource "aws_vpc_security_group_ingress_rule" "target_ssh_from_aiops" {
  security_group_id            = aws_security_group.target.id
  description                  = "Ansible SSH from AIOps VM"
  referenced_security_group_id = aws_security_group.aiops.id
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
}

# Blackbox Exporter running on the AIOps VM probes the demo app on target VMs.
resource "aws_vpc_security_group_ingress_rule" "target_demo_app_from_aiops" {
  security_group_id            = aws_security_group.target.id
  description                  = "Blackbox HTTP probe from AIOps VM"
  referenced_security_group_id = aws_security_group.aiops.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

################################################################################
# SECURITY GROUP EGRESS RULES
################################################################################

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
# PRIVATE DNS FOR THE AIOPS SERVER
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
# IAM FOR EC2 / SSM / PROMETHEUS EC2 SERVICE DISCOVERY
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

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "prometheus_ec2_discovery" {
  name = "${local.name_prefix}-ec2-discovery"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

################################################################################
# ANSIBLE SSH KEYPAIR
# POC NOTE: the private key is stored in Terraform state. Replace this design
# with a managed key / OpenBao workflow before production use.
################################################################################

resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

################################################################################
# AIOPS EC2 VM
# Installs:
# - Docker / Compose
# - Prometheus
# - Alertmanager
# - Blackbox Exporter
# - Loki
# - Grafana
# - Ollama
# - Qdrant
# - FastAPI AIOps service
# - Ansible
################################################################################

resource "aws_instance" "aiops" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.aiops_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.aiops.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.aiops_root_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-USERDATA
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
          - "11434:11434"

      fastapi:
        build: ./fastapi
        container_name: fastapi
        restart: unless-stopped
        environment:
          LOKI_URL: http://loki:3100
          OLLAMA_URL: http://ollama:11434
          QDRANT_HOST: qdrant
          QDRANT_PORT: "6333"
          OLLAMA_MODEL: ${var.ollama_model}
          EMBED_MODEL: ${var.ollama_embedding_model}
          SERVICENOW_URL: ${jsonencode(var.servicenow_url)}
          SERVICENOW_USERNAME: ${jsonencode(var.servicenow_username)}
          SERVICENOW_PASSWORD: ${jsonencode(var.servicenow_password)}
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
    echo "FastAPI health:"
    curl -sf http://localhost:8000/health || true
    echo
    echo "Prometheus health:"
    curl -sf http://localhost:9090/-/healthy || true
    echo
    echo "Loki health:"
    curl -sf http://localhost:3100/ready || true
    echo
    STATUSEOF
    chmod +x /usr/local/bin/aiops-status
  USERDATA

  tags = {
    Name = "${local.name_prefix}-aiops"
    Role = "AIOpsPlatform"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_iam_role_policy.prometheus_ec2_discovery
  ]
}

resource "aws_route53_record" "aiops" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.aiops_dns
  type    = "A"
  ttl     = 30
  records = [aws_instance.aiops.private_ip]
}

################################################################################
# MONITORED APPLICATION VMs
# Each VM installs:
# - Demo Python application
# - node_exporter
# - Grafana Alloy log shipper -> Loki
# - SSM access
################################################################################

resource "aws_instance" "target" {
  count = var.target_vm_count

  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.target_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.target.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Public IP is used only for outbound package/image downloads in this simple POC.
  # There is NO public inbound security-group rule.
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

  user_data = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail

    export DEBIAN_FRONTEND=noninteractive
    TARGET_NAME="${format("%s-app-%02d", local.name_prefix, count.index + 1)}"

    apt-get update
    apt-get install -y docker.io curl jq python3
    systemctl enable --now docker

    # Ensure SSM agent is running on Ubuntu AWS images.
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    hostnamectl set-hostname "$TARGET_NAME"

    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    cat >> /home/ubuntu/.ssh/authorized_keys <<'PUBKEY'
    ${trimspace(tls_private_key.ansible.public_key_openssh)}
    PUBKEY
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    mkdir -p /opt/aiops-target /var/log/aiops-demo /opt/alloy

    ############################################################################
    # DEMO APPLICATION
    ############################################################################

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

    ############################################################################
    # NODE EXPORTER
    ############################################################################

    docker run -d \
      --name node-exporter \
      --restart unless-stopped \
      --network host \
      --pid host \
      -v "/:/host:ro,rslave" \
      quay.io/prometheus/node-exporter:latest \
      --path.rootfs=/host

    ############################################################################
    # GRAFANA ALLOY -> LOKI
    ############################################################################

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

    docker run -d \
      --name alloy \
      --restart unless-stopped \
      --network host \
      -v /opt/alloy/config.alloy:/etc/alloy/config.alloy:ro \
      -v /var/log:/var/log:ro \
      grafana/alloy:latest \
      run /etc/alloy/config.alloy

    echo "INFO AIOps target bootstrap completed" >> /var/log/aiops-demo/app.log
  USERDATA

  tags = {
    Name = format("%s-app-%02d", local.name_prefix, count.index + 1)
    Role = "AIOpsTarget"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_route53_record.aiops
  ]
}
