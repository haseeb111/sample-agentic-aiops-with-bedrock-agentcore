terraform {


  backend "s3" {
    bucket         = "aiops-terraform-tfstate01"
    key            = "dev-aiops.tfstate"
    region         = "us-east-1"
  }
}


################################################################################
# VARIABLES
################################################################################

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "aiops-demo"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "admin_cidr" {
  description = "Your public IP as x.x.x.x/32. Allowed to SSH and open Grafana/Prometheus/Alertmanager/FastAPI/Qdrant."
  type        = string
  default     = "0.0.0.0/0"
}

variable "app_ingress_cidr" {
  description = "Who may reach the demo app through the load balancer"
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two subnets in two AZs (the ALB needs two)"
  type        = list(string)
  default     = ["10.50.1.0/24", "10.50.2.0/24"]
}

variable "app_vm_count" {
  type    = number
  default = 2
}

variable "app_instance_type" {
  type    = string
  default = "t3.small"
}

variable "db_instance_type" {
  type    = string
  default = "t3.small"
}

variable "monitoring_instance_type" {
  description = "Needs ~16 GiB RAM for the Docker stack + local Ollama model. Smaller types run out of memory and become unreachable."
  type        = string
  default     = "t3.micro"
}

variable "app_root_gb" {
  type    = number
  default = 20
}

variable "db_root_gb" {
  type    = number
  default = 30
}

variable "monitoring_root_gb" {
  type    = number
  default = 60
}

variable "ollama_model" {
  type    = string
  default = "llama3.2:3b"
}

variable "ollama_embedding_model" {
  type    = string
  default = "nomic-embed-text"
}

# Optional ServiceNow. Leave empty to skip ticket creation.
variable "servicenow_url" {
  description = "e.g. https://yourinstance.service-now.com"
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

variable "bootstrap_bucket_name" {
  description = "EXISTING S3 bucket for the monitoring VM install script (not created here)"
  type        = string
  default     = "aiops-terraform-tfstate01"
}

variable "bootstrap_prefix" {
  type    = string
  default = "bootstrap"
}

################################################################################
# DATA / LOCALS
################################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_s3_bucket" "bootstrap" {
  bucket = var.bootstrap_bucket_name
}

locals {
  name_prefix    = "${var.project_name}-${var.environment}"
  azs            = slice(data.aws_availability_zones.available.names, 0, length(var.public_subnet_cidrs))
  dns_zone       = "aiops.internal"
  monitoring_dns = "monitoring.${local.dns_zone}"
  db_dns         = "db.${local.dns_zone}"
  bootstrap_key  = "${var.bootstrap_prefix}/${local.name_prefix}/install-monitoring.sh"

  app_names = [for i in range(var.app_vm_count) : format("%s-app-%02d", local.name_prefix, i + 1)]
  db_name   = "${local.name_prefix}-db"

  # Shared agent installer for app + DB VMs: node_exporter and Fluent Bit -> Loki.
  # Usage in user_data:  install_agents "<host>" "job=/path/glob" ...
  agents_fn = <<-AGENTS
    install_agents() {
      local host="$1"; shift
      docker run -d --name node-exporter --restart unless-stopped \
        --network host --pid host -v "/:/host:ro,rslave" \
        quay.io/prometheus/node-exporter:latest --path.rootfs=/host

      mkdir -p /etc/fluent-bit /var/lib/fluent-bit
      {
        printf '[SERVICE]\n    Flush     5\n    Log_Level warn\n\n'
        for pair in "$@"; do
          job="$${pair%%=*}"
          path="$${pair#*=}"
          printf '[INPUT]\n    Name             tail\n    Path             %s\n    Tag              %s\n    DB               /state/%s.db\n    Skip_Long_Lines  On\n\n' "$path" "$job" "$job"
          printf '[OUTPUT]\n    Name             loki\n    Match            %s\n    Host             ${local.monitoring_dns}\n    Port             3100\n    Labels           job=%s, host=%s\n    Drop_Single_Key  On\n\n' "$job" "$job" "$host"
        done
      } > /etc/fluent-bit/fluent-bit.conf

      docker run -d --name fluent-bit --restart unless-stopped --network host \
        -v /etc/fluent-bit/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro \
        -v /var/log:/var/log:ro \
        -v /var/lib/fluent-bit:/state \
        fluent/fluent-bit:latest
    }
  AGENTS
}

################################################################################
# NETWORK
################################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnet_cidrs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route53_zone" "private" {
  name = local.dns_zone

  vpc {
    vpc_id = aws_vpc.this.id
  }
}

################################################################################
# SECURITY GROUPS
################################################################################

resource "aws_security_group" "this" {
  for_each = toset(["alb", "monitoring", "app", "db"])

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "${local.name_prefix} ${each.key}"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-${each.key}-sg" }
}

locals {
  # sg = group the rule belongs to; source is either a CIDR or another group.
  ingress_rules = {
    alb-http          = { sg = "alb", port = 80, cidr = var.app_ingress_cidr, src = null }
    mon-ssh           = { sg = "monitoring", port = 22, cidr = var.admin_cidr, src = null }
    mon-grafana       = { sg = "monitoring", port = 3000, cidr = var.admin_cidr, src = null }
    mon-fastapi       = { sg = "monitoring", port = 8000, cidr = var.admin_cidr, src = null }
    mon-prometheus    = { sg = "monitoring", port = 9090, cidr = var.admin_cidr, src = null }
    mon-alertmanager  = { sg = "monitoring", port = 9093, cidr = var.admin_cidr, src = null }
    mon-qdrant        = { sg = "monitoring", port = 6333, cidr = var.admin_cidr, src = null }
    mon-loki-from-app = { sg = "monitoring", port = 3100, cidr = null, src = "app" }
    mon-loki-from-db  = { sg = "monitoring", port = 3100, cidr = null, src = "db" }
    app-http-from-alb = { sg = "app", port = 8080, cidr = null, src = "alb" }
    app-http-from-mon = { sg = "app", port = 8080, cidr = null, src = "monitoring" }
    app-node-exporter = { sg = "app", port = 9100, cidr = null, src = "monitoring" }
    app-ssh-from-mon  = { sg = "app", port = 22, cidr = null, src = "monitoring" }
    app-ssh-admin     = { sg = "app", port = 22, cidr = var.admin_cidr, src = null }
    db-pg-from-app    = { sg = "db", port = 5432, cidr = null, src = "app" }
    db-node-exporter  = { sg = "db", port = 9100, cidr = null, src = "monitoring" }
    db-pg-exporter    = { sg = "db", port = 9187, cidr = null, src = "monitoring" }
    db-ssh-from-mon   = { sg = "db", port = 22, cidr = null, src = "monitoring" }
    db-ssh-admin      = { sg = "db", port = 22, cidr = var.admin_cidr, src = null }
  }
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = local.ingress_rules

  security_group_id            = aws_security_group.this[each.value.sg].id
  description                  = each.key
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  cidr_ipv4                    = each.value.cidr
  referenced_security_group_id = each.value.src == null ? null : aws_security_group.this[each.value.src].id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = aws_security_group.this

  security_group_id = each.value.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

################################################################################
# IAM - one instance role for all VMs
################################################################################

resource "aws_iam_role" "ec2" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ec2" {
  name = "${local.name_prefix}-ec2-inline"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PrometheusEc2Discovery"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeAvailabilityZones"]
        Resource = "*"
      },
      {
        Sid      = "ReadBootstrapScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.aws_s3_bucket.bootstrap.arn}/${local.bootstrap_key}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name
}

################################################################################
# KEYS AND PASSWORDS
# POC: private keys and passwords are kept in Terraform state.
################################################################################

resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "admin" {
  key_name   = "${local.name_prefix}-admin-key"
  public_key = tls_private_key.admin.public_key_openssh
}

resource "local_sensitive_file" "admin_pem" {
  filename        = "${path.module}/${local.name_prefix}-admin.pem"
  content         = tls_private_key.admin.private_key_pem
  file_permission = "0400"
}

# Used by Ansible on the monitoring VM to reach the app/DB VMs.
resource "tls_private_key" "ansible" {
  algorithm = "ED25519"
}

resource "random_password" "db_app" {
  length  = 24
  special = false
}

resource "random_password" "db_exporter" {
  length  = 24
  special = false
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

################################################################################
# DATABASE VM - PostgreSQL (free) + postgres_exporter + node_exporter + Fluent Bit
################################################################################

resource "aws_instance" "db" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.db_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.this["db"].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.db_root_gb
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    hostnamectl set-hostname "${local.db_name}"

    apt-get update
    apt-get install -y postgresql postgresql-contrib docker.io
    systemctl enable --now docker

    # Ansible key from the monitoring VM
    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    echo "${trimspace(tls_private_key.ansible.public_key_openssh)}" >> /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    # ------------------------------------------------------------ PostgreSQL
    PG_VER=$(ls /etc/postgresql | sort -V | tail -1)
    PG_DIR=/etc/postgresql/$PG_VER/main
    cat >> $PG_DIR/postgresql.conf <<'PGCONF'
    listen_addresses = '*'
    shared_preload_libraries = 'pg_stat_statements'
    log_min_duration_statement = 1000
    log_connections = on
    log_disconnections = on
    PGCONF
    echo "host appdb appuser ${var.vpc_cidr} scram-sha-256" >> $PG_DIR/pg_hba.conf
    systemctl restart postgresql

    sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
    CREATE ROLE appuser LOGIN PASSWORD '${random_password.db_app.result}';
    CREATE DATABASE appdb OWNER appuser;
    CREATE ROLE postgres_exporter LOGIN PASSWORD '${random_password.db_exporter.result}';
    GRANT pg_monitor TO postgres_exporter;
    SQL

    sudo -u postgres psql -v ON_ERROR_STOP=1 -d appdb <<SQL
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    CREATE TABLE IF NOT EXISTS visits (id bigserial PRIMARY KEY, host text, created_at timestamptz DEFAULT now());
    ALTER TABLE visits OWNER TO appuser;
    SQL

    # ------------------------------------------------------------ exporters + logs
    docker run -d --name postgres-exporter --restart unless-stopped --network host \
      -e DATA_SOURCE_NAME="postgresql://postgres_exporter:${random_password.db_exporter.result}@127.0.0.1:5432/postgres?sslmode=disable" \
      quay.io/prometheuscommunity/postgres-exporter:latest

    ${indent(4, local.agents_fn)}
    install_agents "${local.db_name}" \
      "system=/var/log/syslog" \
      "auth=/var/log/auth.log" \
      "postgres=/var/log/postgresql/*.log"
  USERDATA

  tags = {
    Name      = local.db_name
    Role      = "AIOpsDatabase"
    Monitored = "true"
  }

  depends_on = [aws_route_table_association.public]
}

resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.db_dns
  type    = "A"
  ttl     = 30
  records = [aws_instance.db.private_ip]
}

################################################################################
# DEMO APP VMs (2) - Python app on :8080 using PostgreSQL
#   GET /     -> 200, app alive
#   GET /db   -> writes + reads a row in PostgreSQL (500 if the DB is down)
################################################################################

resource "aws_instance" "app" {
  count = var.app_vm_count

  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids      = [aws_security_group.this["app"].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.app_root_gb
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    HOST_NAME="${local.app_names[count.index]}"
    hostnamectl set-hostname "$HOST_NAME"

    apt-get update
    apt-get install -y docker.io python3 python3-psycopg2
    systemctl enable --now docker

    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
    echo "${trimspace(tls_private_key.ansible.public_key_openssh)}" >> /home/ubuntu/.ssh/authorized_keys
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
    chmod 600 /home/ubuntu/.ssh/authorized_keys

    mkdir -p /opt/aiops-demo /var/log/aiops-demo

    cat > /etc/aiops-demo.env <<ENVEOF
    APP_HOST=$HOST_NAME
    DB_HOST=${local.db_dns}
    DB_NAME=appdb
    DB_USER=appuser
    DB_PASSWORD=${random_password.db_app.result}
    ENVEOF
    chmod 600 /etc/aiops-demo.env

    cat > /opt/aiops-demo/app.py <<'PYEOF'
    import logging
    import os
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    import psycopg2

    logging.basicConfig(
        filename="/var/log/aiops-demo/app.log",
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    HOST = os.environ.get("APP_HOST", "unknown")


    def db_visit():
        conn = psycopg2.connect(
            host=os.environ["DB_HOST"], dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
            connect_timeout=3,
        )
        try:
            with conn, conn.cursor() as cur:
                cur.execute("INSERT INTO visits (host) VALUES (%s)", (HOST,))
                cur.execute("SELECT count(*) FROM visits")
                return cur.fetchone()[0]
        finally:
            conn.close()


    class Handler(BaseHTTPRequestHandler):
        def reply(self, code, text):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(text.encode())

        def do_GET(self):
            if self.path.startswith("/db"):
                try:
                    count = db_visit()
                    logging.info("db ok path=%s visits=%s", self.path, count)
                    self.reply(200, f"DB OK from {HOST}: {count} visits\n")
                except Exception as exc:
                    logging.error("db error path=%s error=%s", self.path, exc)
                    self.reply(500, f"DB ERROR from {HOST}: {exc}\n")
                return
            logging.info("request path=%s", self.path)
            self.reply(200, f"AIOps Demo OK from {HOST}\n")

        def log_message(self, *args):
            pass


    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PYEOF

    cat > /etc/systemd/system/aiops-demo.service <<'SVCEOF'
    [Unit]
    Description=AIOps Demo Application
    After=network-online.target
    Wants=network-online.target

    [Service]
    EnvironmentFile=/etc/aiops-demo.env
    ExecStart=/usr/bin/python3 /opt/aiops-demo/app.py
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    systemctl daemon-reload
    systemctl enable --now aiops-demo

    ${indent(4, local.agents_fn)}
    install_agents "$HOST_NAME" \
      "system=/var/log/syslog" \
      "auth=/var/log/auth.log" \
      "application=/var/log/aiops-demo/*.log"

    echo "INFO AIOps demo app bootstrap completed" >> /var/log/aiops-demo/app.log
  USERDATA

  tags = {
    Name      = local.app_names[count.index]
    Role      = "AIOpsApp"
    Monitored = "true"
  }

  depends_on = [aws_route_table_association.public, aws_route53_record.db, aws_route53_record.monitoring]
}

################################################################################
# LOAD BALANCER - ALB :80 -> app VMs :8080
################################################################################

resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.this["alb"].id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "app" {
  name     = "${local.name_prefix}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count = var.app_vm_count

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

################################################################################
# MONITORING + AIOPS VM
# The full installer is larger than the 16 KiB user_data limit, so it is stored
# in the existing S3 bucket and user_data downloads and runs it.
################################################################################

resource "aws_s3_object" "monitoring_bootstrap" {
  bucket                 = data.aws_s3_bucket.bootstrap.id
  key                    = local.bootstrap_key
  content_type           = "text/x-shellscript"
  server_side_encryption = "AES256"

  content = <<-BOOTSTRAP
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y docker.io docker-compose-v2 curl jq
    systemctl enable --now docker

    mkdir -p /opt/aiops/{prometheus,alertmanager,blackbox,loki,grafana/provisioning/datasources,fastapi,ansible/playbooks,keys}
    chmod 700 /opt/aiops/keys

    cat > /opt/aiops/keys/ansible_ed25519 <<'KEYEOF'
    ${trimspace(tls_private_key.ansible.private_key_openssh)}
    KEYEOF
    chmod 600 /opt/aiops/keys/ansible_ed25519

    umask 077
    cat > /opt/aiops/.env <<'ENVEOF'
    SERVICENOW_URL=${var.servicenow_url}
    SERVICENOW_USERNAME=${var.servicenow_username}
    SERVICENOW_PASSWORD=${var.servicenow_password}
    GF_SECURITY_ADMIN_PASSWORD=${random_password.grafana.result}
    ENVEOF
    umask 022

    # ============================================================ PROMETHEUS
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
      - job_name: node-exporter
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 9100
            filters:
              - name: tag:Monitored
                values: ["true"]
              - name: tag:Project
                values: ["${var.project_name}"]
              - name: instance-state-name
                values: ["running"]
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
            target_label: private_ip
          - source_labels: [__meta_ec2_tag_Name]
            target_label: host
          - source_labels: [__meta_ec2_instance_id]
            target_label: instance_id
          - source_labels: [__meta_ec2_tag_Role]
            target_label: role

      - job_name: postgres
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 9187
            filters:
              - name: tag:Role
                values: ["AIOpsDatabase"]
              - name: tag:Project
                values: ["${var.project_name}"]
              - name: instance-state-name
                values: ["running"]
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
            target_label: private_ip
          - source_labels: [__meta_ec2_tag_Name]
            target_label: host
          - source_labels: [__meta_ec2_instance_id]
            target_label: instance_id
          - source_labels: [__meta_ec2_tag_Role]
            target_label: role

      - job_name: blackbox-app
        metrics_path: /probe
        params:
          module: [http_2xx]
        ec2_sd_configs:
          - region: ${var.aws_region}
            port: 8080
            filters:
              - name: tag:Role
                values: ["AIOpsApp"]
              - name: tag:Project
                values: ["${var.project_name}"]
              - name: instance-state-name
                values: ["running"]
        relabel_configs:
          - source_labels: [__meta_ec2_private_ip]
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

      - job_name: blackbox-alb
        metrics_path: /probe
        params:
          module: [http_2xx]
        static_configs:
          - targets:
              - http://${aws_lb.app.dns_name}/
              - http://${aws_lb.app.dns_name}/db
            labels:
              host: ${local.name_prefix}-alb
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__address__]
            target_label: url
          - target_label: __address__
            replacement: blackbox:9115
    PROMEOF

    cat > /opt/aiops/prometheus/alerts.yml <<'ALERTEOF'
    groups:
      - name: vm-alerts
        rules:
          - alert: VMMonitoringDown
            expr: up{job="node-exporter"} == 0
            for: 1m
            labels: {severity: critical}
            annotations:
              summary: "Cannot scrape node_exporter on {{ $labels.host }}"

          - alert: DemoApplicationDown
            expr: probe_success{job="blackbox-app"} == 0
            for: 30s
            labels: {severity: critical}
            annotations:
              summary: "Demo application down on {{ $labels.host }}"

          - alert: HighCPU
            expr: 100 - (avg by (host, instance_id, private_ip) (rate(node_cpu_seconds_total{job="node-exporter",mode="idle"}[5m])) * 100) > 85
            for: 3m
            labels: {severity: warning}
            annotations:
              summary: "CPU above 85% on {{ $labels.host }}"

          - alert: HighMemory
            expr: (1 - node_memory_MemAvailable_bytes{job="node-exporter"} / node_memory_MemTotal_bytes{job="node-exporter"}) * 100 > 90
            for: 3m
            labels: {severity: critical}
            annotations:
              summary: "Memory above 90% on {{ $labels.host }}"

          - alert: LowDiskSpace
            expr: node_filesystem_avail_bytes{job="node-exporter",mountpoint="/"} / node_filesystem_size_bytes{job="node-exporter",mountpoint="/"} * 100 < 15
            for: 5m
            labels: {severity: warning}
            annotations:
              summary: "Less than 15% disk free on {{ $labels.host }}"

      - name: database-alerts
        rules:
          - alert: PostgresDown
            expr: pg_up{job="postgres"} == 0 or up{job="postgres"} == 0
            for: 1m
            labels: {severity: critical}
            annotations:
              summary: "PostgreSQL is down on {{ $labels.host }}"

          - alert: PostgresTooManyConnections
            expr: sum by (host, instance_id, private_ip) (pg_stat_activity_count{job="postgres"}) > 80
            for: 2m
            labels: {severity: warning}
            annotations:
              summary: "More than 80 PostgreSQL connections on {{ $labels.host }}"

      - name: load-balancer-alerts
        rules:
          - alert: LoadBalancerEndpointFailing
            expr: probe_success{job="blackbox-alb"} == 0
            for: 1m
            labels: {severity: critical}
            annotations:
              summary: "Load balancer check failing for {{ $labels.url }}"
    ALERTEOF

    # ============================================================ ALERTMANAGER
    cat > /opt/aiops/alertmanager/alertmanager.yml <<'AMEOF'
    route:
      receiver: aiops-webhook
      group_by: [alertname, host]
      group_wait: 15s
      group_interval: 1m
      repeat_interval: 30m

    receivers:
      - name: aiops-webhook
        webhook_configs:
          - url: http://fastapi:8000/alerts
            send_resolved: true
    AMEOF

    # ============================================================ BLACKBOX
    cat > /opt/aiops/blackbox/blackbox.yml <<'BBEOF'
    modules:
      http_2xx:
        prober: http
        timeout: 5s
        http:
          preferred_ip_protocol: ip4
          valid_status_codes: [200]
    BBEOF

    # ============================================================ LOKI
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

    # ============================================================ GRAFANA
    cat > /opt/aiops/grafana/provisioning/datasources/datasources.yml <<'DSEOF'
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
    DSEOF

    # ============================================================ ANSIBLE
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

    # ============================================================ FASTAPI (RAG)
    cat > /opt/aiops/fastapi/requirements.txt <<'REQEOF'
    fastapi
    uvicorn[standard]
    requests
    qdrant-client
    REQEOF

    cat > /opt/aiops/fastapi/Dockerfile <<'DOCKEREOF'
    FROM python:3.12-slim
    RUN apt-get update && apt-get install -y --no-install-recommends ansible openssh-client && rm -rf /var/lib/apt/lists/*
    WORKDIR /app
    COPY requirements.txt .
    RUN pip install --no-cache-dir -r requirements.txt
    COPY app.py .
    CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
    DOCKEREOF

    cat > /opt/aiops/fastapi/app.py <<'PYEOF'
    import json
    import os
    import subprocess
    import time
    import uuid
    from typing import Any

    import requests
    from fastapi import BackgroundTasks, FastAPI, Request
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

    # Guardrail: a playbook may only run for the alerts listed here, whatever the LLM says.
    ALLOWED_AUTOMATION = {
        "RESTART_APP": {"DemoApplicationDown"},
    }

    # Last processed incidents, visible at GET /incidents
    INCIDENTS: list[dict] = []

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
    - For database, CPU, memory, disk, load balancer, unknown, network, security or destructive conditions choose HUMAN_REVIEW.
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


    def handle_alert(alert: dict) -> dict:
        labels = alert.get("labels", {})
        alertname = labels.get("alertname", "VM alert")
        host = labels.get("host", labels.get("instance", "unknown"))
        target_ip = labels.get("private_ip", "")

        logs = recent_logs(host)
        context = json.dumps(alert) + "\n" + logs
        vector = make_embedding(context)
        history = find_similar(vector)
        analysis = ask_llm(alert, logs, history)

        ticket = create_servicenow(
            f"AIOps: {alertname} on {host}",
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
        remediation_id = analysis.get("remediation_id", "HUMAN_REVIEW")
        if (
            analysis.get("safe_to_automate") is True
            and alertname in ALLOWED_AUTOMATION.get(remediation_id, set())
        ):
            remediation = run_remediation(remediation_id, target_ip)

        return {
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "alertname": alertname,
            "host": host,
            "target_ip": target_ip,
            "analysis": analysis,
            "ticket": ticket,
            "remediation": remediation,
        }


    def process_alerts(alerts: list[dict]):
        for alert in alerts:
            try:
                result = handle_alert(alert)
            except Exception as exc:
                result = {"alert": alert.get("labels", {}), "error": str(exc)}
            print(json.dumps(result, default=str), flush=True)
            INCIDENTS.insert(0, result)
            del INCIDENTS[50:]


    @app.get("/incidents")
    def incidents():
        return INCIDENTS


    @app.post("/alerts")
    async def alerts(request: Request, background: BackgroundTasks):
        """Alertmanager webhook. Returns immediately; the LLM work runs in the background
        so Alertmanager does not time out and resend the same alert."""
        payload = await request.json()
        queued, skipped = [], []

        for alert in payload.get("alerts", []):
            labels = alert.get("labels", {})
            host = labels.get("host", labels.get("instance", "unknown"))
            if alert.get("status", "firing") != "firing":
                skipped.append({"host": host, "status": "resolved"})
                continue
            dedupe_key = f"{labels.get('alertname')}|{host}|{alert.get('startsAt', '')}"
            if seen_recently(dedupe_key):
                skipped.append({"host": host, "status": "duplicate"})
                continue
            queued.append(alert)

        if queued:
            background.add_task(process_alerts, queued)
        return {"queued": len(queued), "skipped": skipped}
    PYEOF

    # ============================================================ COMPOSE
    cat > /opt/aiops/docker-compose.yml <<'COMPOSEEOF'
    services:
      prometheus:
        image: prom/prometheus:latest
        container_name: prometheus
        restart: unless-stopped
        command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.retention.time=7d"]
        volumes:
          - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
          - ./prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
          - prometheus-data:/prometheus
        ports: ["9090:9090"]

      alertmanager:
        image: prom/alertmanager:latest
        container_name: alertmanager
        restart: unless-stopped
        volumes:
          - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
        ports: ["9093:9093"]

      blackbox:
        image: prom/blackbox-exporter:latest
        container_name: blackbox
        restart: unless-stopped
        command: ["--config.file=/config/blackbox.yml"]
        volumes:
          - ./blackbox/blackbox.yml:/config/blackbox.yml:ro

      loki:
        image: grafana/loki:latest
        container_name: loki
        restart: unless-stopped
        command: ["-config.file=/etc/loki/loki.yml"]
        volumes:
          - ./loki/loki.yml:/etc/loki/loki.yml:ro
          - loki-data:/loki
        ports: ["3100:3100"]

      grafana:
        image: grafana/grafana:latest
        container_name: grafana
        restart: unless-stopped
        env_file: [.env]
        volumes:
          - grafana-data:/var/lib/grafana
          - ./grafana/provisioning:/etc/grafana/provisioning:ro
        ports: ["3000:3000"]
        depends_on: [prometheus, loki]

      qdrant:
        image: qdrant/qdrant:latest
        container_name: qdrant
        restart: unless-stopped
        volumes:
          - qdrant-data:/qdrant/storage
        ports: ["6333:6333"]

      ollama:
        image: ollama/ollama:latest
        container_name: ollama
        restart: unless-stopped
        volumes:
          - ollama-data:/root/.ollama
        ports: ["127.0.0.1:11434:11434"]

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
        ports: ["8000:8000"]
        depends_on: [loki, qdrant, ollama]

    volumes:
      prometheus-data:
      loki-data:
      grafana-data:
      qdrant-data:
      ollama-data:
    COMPOSEEOF

    cd /opt/aiops
    docker compose up -d --build

    for i in $(seq 1 90); do
      curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break
      sleep 5
    done
    docker exec ollama ollama pull ${var.ollama_model} || true
    docker exec ollama ollama pull ${var.ollama_embedding_model} || true

    cat > /usr/local/bin/aiops-status <<'STATUSEOF'
    #!/usr/bin/env bash
    cd /opt/aiops
    docker compose ps
    echo; echo "FastAPI:";    curl -s http://localhost:8000/health; echo
    echo "Prometheus:";       curl -s http://localhost:9090/-/healthy; echo
    echo "Loki:";             curl -s http://localhost:3100/ready; echo
    echo "Ollama models:";    curl -s http://localhost:11434/api/tags | jq -r '.models[].name'
    STATUSEOF
    chmod +x /usr/local/bin/aiops-status

    echo "AIOPS BOOTSTRAP COMPLETE" | tee /dev/console
  BOOTSTRAP
}

resource "aws_instance" "monitoring" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.monitoring_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.this["monitoring"].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # Prometheus EC2 discovery runs in a container
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.monitoring_root_gb
    encrypted   = true
  }

  # Keep user_data small and make SSH/SSM work first. The big installer runs in
  # the background; follow it with: sudo tail -f /var/log/aiops-bootstrap.log
  user_data_replace_on_change = true
  user_data                   = <<-USERDATA
    #!/usr/bin/env bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    hostnamectl set-hostname "${local.name_prefix}-monitoring"

    apt-get update
    apt-get install -y curl unzip jq
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp/awscliv2
    /tmp/awscliv2/aws/install --update

    /usr/local/bin/aws s3 cp "s3://${var.bootstrap_bucket_name}/${local.bootstrap_key}" \
      /usr/local/sbin/install-monitoring.sh --region "${var.aws_region}"
    chmod 700 /usr/local/sbin/install-monitoring.sh
    nohup /usr/local/sbin/install-monitoring.sh > /var/log/aiops-bootstrap.log 2>&1 &
  USERDATA

  tags = {
    Name = "${local.name_prefix}-monitoring"
    Role = "AIOpsMonitoring"
  }

  depends_on = [
    aws_route_table_association.public,
    aws_iam_role_policy.ec2,
    aws_iam_role_policy_attachment.ssm,
    aws_s3_object.monitoring_bootstrap,
  ]
}

resource "aws_route53_record" "monitoring" {
  zone_id = aws_route53_zone.private.zone_id
  name    = local.monitoring_dns
  type    = "A"
  ttl     = 30
  records = [aws_instance.monitoring.private_ip]
}

################################################################################
# OUTPUTS
################################################################################

output "app_url" {
  description = "Demo app through the load balancer (/ = app, /db = app + PostgreSQL)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "grafana_url" {
  value = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "prometheus_url" {
  value = "http://${aws_instance.monitoring.public_ip}:9090"
}

output "alertmanager_url" {
  value = "http://${aws_instance.monitoring.public_ip}:9093"
}

output "aiops_api_url" {
  description = "FastAPI: /health, /incidents, /docs"
  value       = "http://${aws_instance.monitoring.public_ip}:8000/docs"
}

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "admin_private_key_pem" {
  description = "terraform output -raw admin_private_key_pem > ~/.ssh/aiops-admin.pem && chmod 600 ~/.ssh/aiops-admin.pem"
  value       = tls_private_key.admin.private_key_pem
  sensitive   = true
}

output "ssh_monitoring" {
  value = "ssh -i ~/.ssh/aiops-admin.pem ubuntu@${aws_instance.monitoring.public_ip}"
}

output "ssh_apps" {
  value = [for vm in aws_instance.app : "ssh -i ~/.ssh/aiops-admin.pem ubuntu@${vm.public_ip}"]
}

output "ssh_db" {
  value = "ssh -i ~/.ssh/aiops-admin.pem ubuntu@${aws_instance.db.public_ip}"
}

output "ssm_monitoring" {
  value = "aws ssm start-session --target ${aws_instance.monitoring.id} --region ${var.aws_region}"
}

output "db_password" {
  value     = random_password.db_app.result
  sensitive = true
}
