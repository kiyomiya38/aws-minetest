#!/bin/bash
set -euo pipefail

# Variables from Terraform templatefile():
DB_HOST="${DB_HOST}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_NAME="${DB_NAME}"
PROJECT="${PROJECT}"

export DEBIAN_FRONTEND=noninteractive

# Basic tools
apt-get update -y
apt-get install -y build-essential git cmake libpq-dev postgresql-client \
                   libsqlite3-dev libcurl4-openssl-dev libjpeg-dev \
                   libxxf86vm-dev libgl1-mesa-dev libxrandr-dev \
                   libxinerama-dev libx11-dev libogg-dev libvorbis-dev \
                   libopenal-dev libfreetype6-dev zlib1g-dev libzstd-dev

# Build & install Luanti (Minetest)
install -d /opt/minetest
cd /opt/minetest
if [ ! -d .git ]; then
  git clone --depth=1 https://github.com/luanti-org/luanti.git /opt/minetest
  git submodule update --init --recursive
fi

install -d /opt/minetest/build
cd /opt/minetest/build
cmake -DRUN_IN_PLACE=FALSE -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SERVER=TRUE -DBUILD_CLIENT=FALSE -DENABLE_POSTGRESQL=TRUE ..
make -j"$(nproc)"
make install

# === Minetest Game を導入（Luanti はゲーム同梱なし） ===
install -d /usr/local/share/luanti/games
if [ ! -d /usr/local/share/luanti/games/minetest_game ]; then
  git clone --depth=1 https://github.com/luanti-org/minetest_game.git \
    /usr/local/share/luanti/games/minetest_game
fi

# World dir & config
install -d -o ubuntu -g ubuntu /var/lib/minetest/world

# world.mt（DB値を変数から展開：ここをクォート無しに変更）
cat >/var/lib/minetest/world/world.mt <<MT
backend = postgresql
gameid = minetest_game
pgsql_connection = host=${DB_HOST} port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME}

player_backend = postgresql
auth_backend = postgresql
mod_storage_backend = postgresql
pgsql_player_connection = host=${DB_HOST} port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME}
pgsql_auth_connection   = host=${DB_HOST} port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME}
pgsql_mod_storage_connection = host=${DB_HOST} port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME}
MT
chown -R ubuntu:ubuntu /var/lib/minetest

# 一度だけ起動して初期化（ハング防止のため timeout 追加）
timeout 5s sudo -u ubuntu env HOME=/home/ubuntu /usr/local/bin/luantiserver \
  --world /var/lib/minetest/world \
  --gameid minetest_game \
  --quiet || true
sleep 2

# RDS 待ちスクリプト（systemd のエスケープ問題を回避）
cat >/usr/local/bin/minetest-wait-for-rds <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mt=/var/lib/minetest/world/world.mt
line=$(grep -E '^pgsql_connection' "$mt" | tail -n1)

# world.mt の1行から host/user/password/dbname を安全に抽出
host=$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^host=/){split($i,a,"="); print a[2]}}}')
db=$(  printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^dbname=/){split($i,a,"="); print a[2]}}}')
user=$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^user=/){split($i,a,"="); print a[2]}}}')
pass=$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++){if($i ~ /^password=/){split($i,a,"="); print a[2]}}}')

for i in {1..60}; do
  PGPASSWORD="$pass" /usr/bin/pg_isready -h "$host" -p 5432 -d "$db" -U "$user" -q && exit 0
  sleep 2
done
echo "RDS not ready"; exit 1
SH
chmod +x /usr/local/bin/minetest-wait-for-rds

# systemd unit
cat >/etc/systemd/system/minetest.service <<'UNIT'
[Unit]
Description=Minetest (Luanti) Server
After=network-online.target
Wants=network-online.target

[Service]
Environment=HOME=/home/ubuntu
User=ubuntu
WorkingDirectory=/var/lib/minetest
ExecStartPre=/usr/local/bin/minetest-wait-for-rds
ExecStart=/usr/local/bin/luantiserver \
  --world /var/lib/minetest/world \
  --gameid minetest_game
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now minetest

# === (追記) NLBヘルスチェック用のTCPエンドポイント ===
apt-get update -y
apt-get install -y socat

cat >/etc/systemd/system/minetest-health.service <<'EOF'
[Unit]
Description=Minetest NLB TCP health endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/minetest/env
ExecStart=/usr/bin/socat TCP-LISTEN:${HEALTH_PORT},fork,reuseaddr SYSTEM:"/bin/echo OK"
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 /etc/minetest
cat >/etc/minetest/env <<EOF
HEALTH_PORT=${HEALTH_PORT}
EOF

# Primaryだけヘルスサービスを起動（Standbyは起動しない＝常時OutOfService）
if [ "${IS_PRIMARY}" = "true" ]; then
  systemctl daemon-reload
  systemctl enable --now minetest-health.service
fi
