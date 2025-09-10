variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "project_name" {
  description = "Resource name prefix (use this instead of 'name')"
  type        = string
  default     = "minetest"
}

# 任意：空なら default VPC を自動検出
variable "vpc_id" {
  description = "Target VPC ID. Empty string means use default VPC"
  type        = string
  default     = ""
}

# 任意：空なら VPC 内サブネットを自動検出
variable "subnet_ids" {
  description = "Subnet IDs for RDS subnet group (>=2). Empty list means discover from VPC"
  type        = list(string)
  default     = []
}

# 任意：空なら effective_subnet_ids の先頭
variable "ec2_subnet_id" {
  description = "Subnet ID for EC2. Empty selects the first effective subnet"
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  type    = number
  default = 20
}

# クライアントからMinetestへ (UDP 30000) を開けるCIDR
variable "minetest_client_cidr" {
  description = "CIDR allowed to access Minetest UDP/30000"
  type        = string
  default     = "0.0.0.0/0"
}

# SSH許可CIDR
variable "ssh_cidr" {
  description = "CIDR allowed to SSH"
  type        = string
  default     = "0.0.0.0/0"
}

# DB接続情報（user_data に渡す）
variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}
