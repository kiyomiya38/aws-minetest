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

# --------------------------------
# VPC / Subnets: 柔軟性を残すため
# - var.vpc_id が空なら default VPC を自動検出
# - var.subnet_ids が空なら default VPC のすべてのサブネットを自動検出
# - var.ec2_subnet_id が空なら、上の自動検出結果の先頭を利用
# --------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# 任意の VPC/Subnet を明示指定する場合に備え、by_id 参照も用意
data "aws_subnet" "by_id" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

locals {
  # 有効VPC
  effective_vpc_id = (
    length(var.vpc_id) > 0 ? var.vpc_id : data.aws_vpc.default.id
  )

  # 有効Subnets
  effective_subnet_ids = (
    length(var.subnet_ids) > 0
    ? var.subnet_ids
    : data.aws_subnets.default.ids
  )

  # EC2用サブネット
  effective_ec2_subnet_id = (
    length(var.ec2_subnet_id) > 0
    ? var.ec2_subnet_id
    : local.effective_subnet_ids[0]
  )

  name = "${var.project_name}-${var.aws_region}"

  # user_data に渡すテンプレート（DB_HOST へ統一）
  user_data = templatefile("${path.module}/user_data.sh", {
    DB_HOST    = aws_db_instance.mtworld.address
    DB_USER    = var.db_user
    DB_PASS    = var.db_password
    DB_NAME    = var.db_name
    PROJECT    = local.name
    project    = local.name    # ← user_data.sh が小文字projectを参照してもOKに
  })
}

# --------------------------
# セキュリティグループ
# --------------------------
resource "aws_security_group" "minetest_ec2" {
  name        = "${local.name}-ec2-sg"
  description = "Allow SSH and Minetest"
  vpc_id      = local.effective_vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Minetest (Luanti) UDP 30000
  ingress {
    from_port   = 30000
    to_port     = 30000
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # どこへでも egress 可（RDS への接続もこれでOK）
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${local.name}-ec2-sg" }
}

resource "aws_security_group" "minetest_rds" {
  name        = "${local.name}-rds-sg"
  description = "Allow Postgres from EC2 SG"
  vpc_id      = local.effective_vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.minetest_ec2.id] # ← タイポ修正済み
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "${local.name}-rds-sg" }
}

# タイポ修正用のローカル参照（既存名を壊さない）
locals {
  minesetest_ec2_sg_id = aws_security_group.minetest_ec2.id
}
# 上の RDS SG ingress 用に参照を修正

# --------------------------
# RDS Subnet Group & RDS
# --------------------------
resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-rds-subnets"
  subnet_ids = local.effective_subnet_ids

  tags = { Name = "${local.name}-rds-subnets" }
}

resource "aws_db_instance" "mtworld" {
  identifier             = "${var.project_name}-pg"
  db_name                = var.db_name
  engine                 = "postgres"
  engine_version         = "15.7"
  instance_class         = var.rds_instance_class
  allocated_storage      = var.rds_allocated_storage
  username               = var.db_user
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.minetest_rds.id]
  publicly_accessible    = true
  skip_final_snapshot    = true

  tags = { Name = "${local.name}-rds" }
}

# --------------------------
# EC2 (Ubuntu 22.04 ARM64) + user_data
# --------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }
}

resource "aws_instance" "minetest" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.effective_ec2_subnet_id
  vpc_security_group_ids = [aws_security_group.minetest_ec2.id]
  key_name               = var.key_name
  user_data              = local.user_data

  tags = { Name = "${local.name}-ec2" }
}
