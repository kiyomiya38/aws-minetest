terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------
# デフォルトVPC/サブネットの自動検出（明示指定があればそちらを優先）
# ---------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 実際に使うVPCのCIDR（NLBヘルス用インバウンドに使う）
# local.effective_vpc_id を元に再取得
data "aws_vpc" "selected" {
  id = local.effective_vpc_id
}

locals {
  name = "${var.project_name}-${var.aws_region}"

  effective_vpc_id        = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default.id
  effective_subnet_ids    = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.default.ids
  effective_ec2_subnet_id = var.subnet_id != "" ? var.subnet_id : local.effective_subnet_ids[0]

  # EC2ごとの user_data（Primary/Standby に渡し分け）
  user_data_primary = templatefile("${path.module}/user_data.sh", {
    DB_HOST     = aws_db_instance.mtworld.address
    DB_USER     = var.db_user
    DB_PASS     = var.db_password
    DB_NAME     = var.db_name
    PROJECT     = local.name
    project     = local.name
    HEALTH_PORT = var.health_check_port
    IS_PRIMARY  = "true"
  })

  user_data_standby = templatefile("${path.module}/user_data.sh", {
    DB_HOST     = aws_db_instance.mtworld.address
    DB_USER     = var.db_user
    DB_PASS     = var.db_password
    DB_NAME     = var.db_name
    PROJECT     = local.name
    project     = local.name
    HEALTH_PORT = var.health_check_port
    IS_PRIMARY  = "false"
  })
}

# ---------------------------
# AMI: Ubuntu 22.04 (Jammy) ARM64
# ---------------------------
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------
# セキュリティグループ
# ---------------------------

# EC2側（SSH / Minetest-UDP / NLBヘルスTCP）
resource "aws_security_group" "minetest_ec2" {
  name        = "${local.name}-ec2-sg"
  description = "Security group for Minetest EC2 instances"
  vpc_id      = local.effective_vpc_id

  # SSH
  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = [var.ssh_cidr]
    ipv6_cidr_blocks = []
    description      = "SSH"
  }

  # Minetest クライアント (UDP/30000 デフォルト)
  ingress {
    from_port        = var.client_port
    to_port          = var.client_port
    protocol         = "udp"
    cidr_blocks      = [var.minetest_client_cidr]
    ipv6_cidr_blocks = []
    description      = "Minetest client UDP"
  }

  # NLB ヘルスチェック (TCP/30001) - VPC内から到達
  ingress {
    from_port        = var.health_check_port
    to_port          = var.health_check_port
    protocol         = "tcp"
    cidr_blocks      = [data.aws_vpc.selected.cidr_block]
    ipv6_cidr_blocks = []
    description      = "NLB health check TCP"
  }

  # 全てのアウトバウンドを許可（OS/apt/DB接続など）
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${local.name}-ec2-sg"
  }
}

# RDS側（EC2のSGからのみ受け付け）
resource "aws_security_group" "minetest_rds" {
  name        = "${local.name}-rds-sg"
  description = "Security group for Minetest RDS"
  vpc_id      = local.effective_vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.minetest_ec2.id]
    description     = "Allow Postgres from EC2 SG only"
  }

  tags = {
    Name = "${local.name}-rds-sg"
  }
}

# ---------------------------
# RDS（PostgreSQL）
# ---------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnet"
  subnet_ids = local.effective_subnet_ids
}

resource "aws_db_instance" "mtworld" {
  identifier           = "${local.name}-rds"
  engine               = "postgres"
  engine_version       = "15.7"
  instance_class       = var.rds_instance_class
  allocated_storage    = var.rds_allocated_storage
  db_subnet_group_name = aws_db_subnet_group.this.name

  db_name  = var.db_name
  username = var.db_user
  password = var.db_password

  vpc_security_group_ids = [aws_security_group.minetest_rds.id]
  publicly_accessible    = false # 非公開推奨
  multi_az               = false # 教材向け簡易

  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name = "${local.name}-rds"
  }
}

# ---------------------------
# 監視のための IAM（CloudWatch Agent / SSM）
# ---------------------------

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "${local.name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# CloudWatch Agent 権限
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# （任意）SSMで踏み台レス管理を有効化
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ---------------------------
# EC2（2台：Primary / Standby）
# ---------------------------

resource "aws_instance" "minetest_1" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = local.effective_ec2_subnet_id
  vpc_security_group_ids = [aws_security_group.minetest_ec2.id]
  key_name               = var.key_name

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  user_data            = local.user_data_primary

  tags = {
    Name = "${local.name}-ec2-1"
    Role = "primary"
  }
}

# 2台目は別AZへ（例として別サブネットを選択）
resource "aws_instance" "minetest_2" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = length(local.effective_subnet_ids) > 1 ? local.effective_subnet_ids[1] : local.effective_ec2_subnet_id
  vpc_security_group_ids = [aws_security_group.minetest_ec2.id]
  key_name               = var.key_name

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  user_data            = local.user_data_standby

  tags = {
    Name = "${local.name}-ec2-2"
    Role = "standby"
  }
}

# ---------------------------
# NLB（UDP 30000 / ヘルスチェック TCP 30001）
# ---------------------------

resource "aws_lb" "minetest_nlb" {
  name                             = "${local.name}-nlb"
  load_balancer_type               = "network"
  subnets                          = local.effective_subnet_ids
  enable_cross_zone_load_balancing = true
  ip_address_type                  = "ipv4"

  tags = {
    Name = "${local.name}-nlb"
  }
}

resource "aws_lb_target_group" "minetest_udp_tg" {
  name        = "${local.name}-udp-tg"
  port        = var.client_port
  protocol    = "UDP"
  vpc_id      = local.effective_vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP" # UDPはヘルス不可、TCPでチェック
    port     = var.health_check_port
  }

  tags = {
    Name = "${local.name}-udp-tg"
  }
}

resource "aws_lb_listener" "minetest_udp_listener" {
  load_balancer_arn = aws_lb.minetest_nlb.arn
  port              = var.client_port
  protocol          = "UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.minetest_udp_tg.arn
  }
}

# 2台をターゲットグループに登録
resource "aws_lb_target_group_attachment" "tg_attach_1" {
  target_group_arn = aws_lb_target_group.minetest_udp_tg.arn
  target_id        = aws_instance.minetest_1.id
  port             = var.client_port
}

resource "aws_lb_target_group_attachment" "tg_attach_2" {
  target_group_arn = aws_lb_target_group.minetest_udp_tg.arn
  target_id        = aws_instance.minetest_2.id
  port             = var.client_port
}

# ---------------------------
# 通知（SNS） + 代表的なCloudWatchアラーム
# ---------------------------

resource "aws_sns_topic" "ops_alerts" {
  name = "${local.name}-ops-alerts"
}

# ※ メール通知したい場合は以下を有効化し、受信メールで購読承認してください
# resource "aws_sns_topic_subscription" "ops_email" {
#   topic_arn = aws_sns_topic.ops_alerts.arn
#   protocol  = "email"
#   endpoint  = "YOUR_MAIL@example.com"
# }

# 1) luantiserver プロセスが 0 件（CloudWatch Agentのprocstat）
resource "aws_cloudwatch_metric_alarm" "luanti_down" {
  alarm_name          = "${local.name}-luantiserver-down"
  namespace           = "CWAgent"
  metric_name         = "procstat_lookup_pid_count"
  dimensions          = { pattern = "luantiserver" }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  alarm_description   = "luantiserver process is not running"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# 2) NLB HealthyHostCount < 1
resource "aws_cloudwatch_metric_alarm" "nlb_no_healthy" {
  alarm_name          = "${local.name}-nlb-no-healthy"
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  dimensions = {
    LoadBalancer = aws_lb.minetest_nlb.arn_suffix
    TargetGroup  = aws_lb_target_group.minetest_udp_tg.arn_suffix
  }
  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]
}

# 3) RDS 空きストレージが 5GiB 未満
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  alarm_name          = "${local.name}-rds-free-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 5 * 1024 * 1024 * 1024
  dimensions          = { DBInstanceIdentifier = aws_db_instance.mtworld.id }
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  ok_actions          = [aws_sns_topic.ops_alerts.arn]
}

# ---------------------------
# 出力
# ---------------------------
output "nlb_dns_name" {
  value       = aws_lb.minetest_nlb.dns_name
  description = "Use this DNS name for Minetest clients."
}
