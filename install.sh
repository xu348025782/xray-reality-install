#!/usr/bin/env bash
set -e

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
echo "3. 查看当前节点"
echo "0. 退出"
echo
read -p "请选择 [0-3]: " MENU

if [ "$MENU" = "3" ]; then
    if [ ! -f /usr/local/etc/xray/node.info ]; then
        echo "未找到节点信息，请先安装。"
        exit 1
    fi
    source /usr/local/etc/xray/node.info
    echo
    echo "========================================"
    echo "          当前 Reality 节点"
    echo "========================================"
    echo "服务器IP : ${SERVER_IP}"
    echo "端口      : ${PORT}"
    echo "UUID      : ${UUID}"
    echo "PublicKey : ${PUBLIC_KEY}"
    echo "ShortID   : ${SHORT_ID}"
    echo "SNI       : ${SNI}"
    echo
    echo "VLESS链接:"
    echo "${VLESS_LINK}"
    exit 0
fi

if [ "$MENU" = "2" ]; then
    echo "正在卸载 Xray..."
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    rm -rf /etc/systemd/system/xray.service.d
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray
    systemctl daemon-reload
    if command -v xray >/dev/null 2>&1; then
      echo "❌ 卸载失败"
      exit 1
    fi
    echo "✅ Xray 已彻底卸载完成"
    exit 0
fi

if [ "$MENU" != "1" ]; then
  exit 0
fi

read -p "请输入监听端口 [443]: " PORT
PORT=${PORT:-443}
read -p "请输入伪装域名(SNI) [fonts.gstatic.com]: " SNI
SNI=${SNI:-fonts.gstatic.com}

echo "安装/更新 Xray..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

UUID=$(cat /proc/sys/kernel/random/uuid)
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | sed -n 's/^PrivateKey:[[:space:]]*//p')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | sed -n 's/^Password (PublicKey):[[:space:]]*//p')
SHORT_ID=$(openssl rand -hex 8)
SERVER_IP=$(curl -s4 ip.sb)

mkdir -p /usr/local/etc/xray
cat >/usr/local/etc/xray/config.json <<EOF
{
"log":{"loglevel":"warning"},
"inbounds":[{"listen":"0.0.0.0","port":${PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"${SNI}:443","serverNames":["${SNI}"],"privateKey":"${PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}],
"outbounds":[{"protocol":"freedom"}]
}
EOF

xray run -test -config /usr/local/etc/xray/config.json
systemctl enable xray >/dev/null 2>&1
systemctl restart xray

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&type=tcp&security=reality&sni=${SNI}&host=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Reality"

cat >/usr/local/etc/xray/node.info <<EOF
SERVER_IP="${SERVER_IP}"
PORT="${PORT}"
UUID="${UUID}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
SNI="${SNI}"
VLESS_LINK="${VLESS_LINK}"
EOF

echo
echo "安装完成"
echo "服务状态: $(systemctl is-active xray)"
echo
echo "$VLESS_LINK"
