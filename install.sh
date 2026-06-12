#!/usr/bin/env bash

set -e

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行"
    exit 1
fi

clear
echo "========================================"
echo "      Xray Reality 一键安装脚本"
echo "========================================"
echo

read -p "请输入监听端口 [443]: " PORT
PORT=${PORT:-443}

read -p "请输入伪装域名(SNI) [fonts.gstatic.com]: " SNI
SNI=${SNI:-fonts.gstatic.com}

echo
echo "正在安装 Xray ..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

echo
echo "正在生成 Reality 密钥..."

UUID=$(cat /proc/sys/kernel/random/uuid)

KEY_OUTPUT=$(xray x25519)

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep "Public key" | awk '{print $3}')

SHORT_ID=$(openssl rand -hex 8)

SERVER_IP=$(curl -s4 ip.sb)

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

echo
echo "检查配置..."

xray run -test -config /usr/local/etc/xray/config.json

systemctl enable xray >/dev/null 2>&1
systemctl restart xray

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision&encryption=none#Reality"

echo
echo "========================================"
echo "            安装完成"
echo "========================================"
echo
echo "服务器IP : $SERVER_IP"
echo "端口      : $PORT"
echo "UUID      : $UUID"
echo "PublicKey : $PUBLIC_KEY"
echo "ShortID   : $SHORT_ID"
echo "SNI       : $SNI"
echo
echo "VLESS链接:"
echo
echo "$VLESS_LINK"
echo
echo "Xray状态:"
systemctl --no-pager --full status xray | head -n 10
