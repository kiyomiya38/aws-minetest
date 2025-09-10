aws_region   = "ap-northeast-3"
project_name = "minetest"

# ▼ 任意VPCで使うなら値を入れる。デフォルトVPCで良ければコメントアウト/空に
# vpc_id               = "vpc-xxxxxxxx"
# subnet_ids           = ["subnet-aaaaaaaa", "subnet-bbbbbbbb"]
# ec2_subnet_id        = "subnet-aaaaaaaa"

key_name              = "test-key"
instance_type         = "t4g.small"
rds_instance_class    = "db.t4g.micro"
rds_allocated_storage = 20

# ネットワーク許可
ssh_cidr             = "0.0.0.0/0" # 必要に応じて固定IPへ絞って下さい
minetest_client_cidr = "0.0.0.0/0" # クライアントからのUDP/30000

# DB接続情報（user_data へ流す）
db_name     = "mtworld"
db_user     = "mtuser"
db_password = "mtpass123"
