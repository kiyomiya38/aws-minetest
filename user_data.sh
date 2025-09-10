#!/bin/bash
set -euo pipefail

# Variables from Terraform templatefile():
DB_HOST="minetest-pg.cxes4u0ecmfp.ap-northeast-3.rds.amazonaws.com"
DB_USER="mtuser"
DB_PASS="mtpass123"
DB_NAME="mtworld"
PROJECT="minetest-ap-northeast-3"

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
pgsql_connection = host=${DB_HOST} port=5432 user=${DB_USER} password=${DB_PASS} dbname=${DB_NAME}
gameid = minetest_game
MT
chown -R ubuntu:ubuntu /var/lib/minetest

# 一度だけ起動して初期化（ハング防止のため timeout 追加）
timeout 5s sudo -u ubuntu env HOME=/home/ubuntu /usr/local/bin/luantiserver \
  --world /var/lib/minetest/world \
  --gameid minetest_game \
  --quiet || true
sleep 2

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
