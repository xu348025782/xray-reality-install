#!/usr/bin/env bash

set -e

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"

clear

echo "========================================"
echo "      Xray Reality 一键安装脚本"
echo "========================================"
echo

if command -v xray >/dev/null 2>&1; then
CURRENT_VERSION=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
echo "当前检测到 Xray 已安装"
echo "当前版本: ${CURRENT_VERSION}"
else
echo "当前未安装 Xray"
fi

echo
echo "1. 安装 / 更新 Reality"
echo "2. 卸载 Xray"
echo "0. 退出"
echo

read -p "请选择 [0-2]: " MENU

case "$MENU" in
1)
;;
2)
echo
echo "正在卸载 Xray..."

```
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true

    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service

    rm -rf /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray

    systemctl daemon-reload

    echo
    echo "Xray 已卸载完成"
    exit 0
    ;;
*)
    exit 0
    ;;
```

esac

echo
read -p "请输入监听端口 [443]: " PORT
PORT=${PORT:-443}

echo
read -p "请输入伪装域名(SNI) [fonts.gstatic.com]: " SNI
SNI=${SNI:-fonts.gstatic.com}

echo
echo "========================================"
echo "安装最新 Xray ..."
echo "========================================"

bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

echo
echo "生成 Reality 参数..."

UUID=$(cat /proc/sys/kernel/random/uuid)

KEY_OUTPUT=$(xray x25519)

PRIVATE_KEY=$(echo "$KEY_OUTPUT" | sed -n 's/^PrivateKey:[[:space:]]*//p')

PUBLIC_KEY=$(echo "$KEY_OUTPUT" | sed -n 's/^Password (PublicKey):[[:space:]]*//p')

SHORT_ID=$(openssl rand -hex 8)

SERVER_IP=$(curl -s4 ip.sb)

mkdir -p /usr/local/etc/xray

cat > ${XRAY_CONF} <<EOF
{
"log": {
"loglevel": "warning"
},
"inbounds": [
{
"listen": "0.0.0.0",
"port": ${PORT},
"protocol": "vless",
"settings": {
"clients": [
{
"id": "${UUID}",
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
"dest": "${SNI}:443",
"xver": 0,
"serverNames": [
"${SNI}"
],
"privateKey": "${PRIVATE_KEY}",
"shortIds": [
"${SHORT_ID}"
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
echo "检查配置文件..."

xray run -test -config ${XRAY_CONF}

echo
echo "启动 Xray..."

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

if systemctl is-active --quiet xray; then
STATUS="运行中"
else
STATUS="启动失败"
fi

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision&encryption=none#Reality"

echo
echo "========================================"
echo "            安装完成"
echo "========================================"
echo
echo "服务状态 : ${STATUS}"
echo
echo "服务器IP : ${SERVER_IP}"
echo "端口      : ${PORT}"
echo "UUID      : ${UUID}"
echo "PublicKey : ${PUBLIC_KEY}"
echo "ShortID   : ${SHORT_ID}"
echo "SNI       : ${SNI}"
echo
echo "VLESS链接:"
echo
echo "${VLESS_LINK}"
echo

if [ "${STATUS}" != "运行中" ]; then
echo "Xray 启动失败，请执行："
echo
echo "journalctl -u xray -n 50 --no-pager"
echo
fi
