#!/usr/bin/env bash
set -e

# Xray 版本：以后想换版本只改这一行
# 注意：v26.3.27 是 pre-26.9.8 的版本，客户端用旧核心、不用加
# support-x25519mlkem768 就能连；换成 26.9.8+ 则新旧客户端都要对应升级。
XRAY_VERSION="v26.3.27"

# 快捷命令名：下次直接输入这个就能进菜单，想换名字只改这一行
SHORTCUT_NAME="xx"
SCRIPT_URL="https://raw.githubusercontent.com/xu348025782/xray-reality-install/main/install.sh"

clear
echo "========================================"
echo "      Xray Reality 一键安装脚本"
echo "      Debian / Ubuntu / Alpine 通用"
echo "========================================"
echo

# ---------- 1. 检测系统 + init ----------
# Debian/Ubuntu: apt + systemd
# Alpine: apk + OpenRC（无 systemd，无 systemctl）
OS_ID=""
INIT="none"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
fi
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT="systemd"
elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
fi
echo "系统: ${OS_ID:-未知} / init: ${INIT}"
if [ "$INIT" = "none" ]; then
    echo "不支持的 init 系统：既没有 systemctl，也没有 rc-service"
    exit 1
fi

# ---------- 2. 依赖：整套装（给 Reality 安装用） ----------
# Alpine 默认没有 bash：先在外面跑 apk add bash 再跑本脚本
# Debian/Ubuntu: apt-get；Alpine: apk；CentOS/RHEL: yum/dnf（顺带兼容）
install_deps() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip openssl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk update
        # coreutils 提供 shuf；openrc 提供 rc-service/rc-update
        apk add --no-cache curl wget unzip openssl coreutils ca-certificates openrc
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget unzip openssl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget unzip openssl ca-certificates
    else
        echo "找不到 apt/apk/yum/dnf，请先手动装好 curl wget unzip openssl"
    fi
}

# ---------- 3. 常用软件：只装选中的那一个 ----------
# 已安装 -> 输出“已安装”；没安装 -> 装好后输出“安装完毕”
install_one_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "$name 已安装"
        return 0
    fi
    echo "正在安装 $name ..."
    local ok=0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$name"; then ok=1; fi
    elif command -v apk >/dev/null 2>&1; then
        if apk add --no-cache "$name"; then ok=1; fi
    elif command -v dnf >/dev/null 2>&1; then
        if dnf install -y "$name"; then ok=1; fi
    elif command -v yum >/dev/null 2>&1; then
        if yum install -y "$name"; then ok=1; fi
    else
        echo "找不到 apt/apk/yum/dnf，请手动安装 $name"
        return 0
    fi
    if [ "$ok" = "1" ] && command -v "$name" >/dev/null 2>&1; then
        echo "$name 安装完毕"
    else
        echo "$name 安装失败，请手动检查"
    fi
    return 0
}

common_software_menu() {
    while true; do
        echo
        echo "========================================"
        echo "      常用软件 - Xray 需要的工具"
        echo "========================================"
        echo "1. bash    - 运行脚本的解释器"
        echo "2. curl    - 下载安装器 / Xray / 查公网 IP"
        echo "3. wget    - 下载工具，和 curl 互为备用"
        echo "4. unzip   - 解压 Xray 的 zip 包"
        echo "5. openssl - 生成 ShortID"
        echo "6. sudo    - 以管理员身份执行命令"
        echo "0. 返回上级"
        echo
        read -p "请选择 [0-6]: " SUB || return 0
        case "$SUB" in
            1) install_one_tool bash || true ;;
            2) install_one_tool curl || true ;;
            3) install_one_tool wget || true ;;
            4) install_one_tool unzip || true ;;
            5) install_one_tool openssl || true ;;
            6) install_one_tool sudo || true ;;
            0) return 0 ;;
            *) echo "无效选择，请重新输入" ;;
        esac
    done
}

# ---------- 4. 系统时区：上海时间 ----------
show_time() {
    echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl 2>/dev/null | grep -E 'Time zone|Local time' || true
    fi
    if [ -f /etc/timezone ]; then
        echo "当前时区文件: $(cat /etc/timezone)"
    fi
}

set_timezone_shanghai() {
    echo
    echo "设置前:"
    show_time
    echo
    echo "正在设置为上海时间 (Asia/Shanghai)..."

    if command -v timedatectl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        # Debian / Ubuntu（systemd）
        if [ ! -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq >/dev/null 2>&1 || true
                DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata >/dev/null 2>&1 || true
            fi
        fi
        timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
        timedatectl set-ntp true 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || systemctl start systemd-timesyncd 2>/dev/null || true
        sleep 2 2>/dev/null || true
    else
        # Alpine / OpenRC / 无 systemd：没有 timedatectl
        if [ ! -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            if command -v apk >/dev/null 2>&1; then
                apk add --no-cache tzdata >/dev/null 2>&1 || true
            elif command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata >/dev/null 2>&1 || true
            fi
        fi
        if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            echo "Asia/Shanghai" > /etc/timezone
        fi
        # 同步时间：优先 chrony，其次 busybox ntpd，失败也不退出脚本
        if command -v chronyd >/dev/null 2>&1; then
            rc-service chronyd restart 2>/dev/null || chronyd 2>/dev/null || true
            sleep 2 2>/dev/null || true
            chronyc makestep 2>/dev/null || true
        elif command -v apk >/dev/null 2>&1; then
            if apk add --no-cache chrony >/dev/null 2>&1; then
                rc-update add chronyd default 2>/dev/null || true
                rc-service chronyd restart 2>/dev/null || rc-service chronyd start 2>/dev/null || true
                sleep 2 2>/dev/null || true
                chronyc makestep 2>/dev/null || true
            fi
        fi
        if command -v ntpd >/dev/null 2>&1; then
            ntpd -q -p pool.ntp.org 2>/dev/null || ntpd -q -p time.google.com 2>/dev/null || true
        fi
    fi

    echo
    echo "设置完成"
    show_time
    echo
}

# ---------- 5. 服务管理抽象：systemd / OpenRC 两套 ----------
svc_enable() {
    if [ "$INIT" = "systemd" ]; then systemctl enable xray >/dev/null 2>&1 || true
    else rc-update add xray default >/dev/null 2>&1 || rc-update add xray >/dev/null 2>&1 || true; fi
}
svc_disable() {
    if [ "$INIT" = "systemd" ]; then systemctl disable xray >/dev/null 2>&1 || true
    else rc-update del xray >/dev/null 2>&1 || true; fi
}
svc_start()   { if [ "$INIT" = "systemd" ]; then systemctl start xray; else rc-service xray start; fi; }
svc_stop()    { if [ "$INIT" = "systemd" ]; then systemctl stop xray >/dev/null 2>&1 || true; else rc-service xray stop >/dev/null 2>&1 || true; fi; }
svc_restart() { if [ "$INIT" = "systemd" ]; then systemctl restart xray; else rc-service xray restart; fi; }
svc_status()  {
    if [ "$INIT" = "systemd" ]; then systemctl is-active xray 2>/dev/null || echo "inactive"
    else rc-service xray status 2>/dev/null || echo "stopped"; fi
}

# ---------- 6. 按架构取 Xray 文件名 ----------
# Xray release 的 zip 名：Xray-linux-64.zip / Xray-linux-arm64-v8a.zip …
xray_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l|armv7) echo "arm32-v7a" ;;
        armv6l) echo "arm32-v6" ;;
        *) echo "64" ;;
    esac
}

# ---------- 7. 安装 Xray：两条路 ----------
install_xray() {
    if [ "$INIT" = "systemd" ]; then
        # Debian/Ubuntu/CentOS：官方 systemd 安装器，支持 --version pin
        bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install --version "${XRAY_VERSION}"
    else
        # Alpine/OpenRC：官方 systemd 安装器不认 Alpine，
        # Alpine 专用的 alpinelinux/install-release.sh 又没有 --version 参数，
        # 只能先下载指定版本的 zip，再用 --local 装，这样才能 pin 住 v26.3.27
        ARCH="$(xray_arch)"
        ZIP="/tmp/Xray-linux-${ARCH}.zip"
        echo "下载 Xray ${XRAY_VERSION} (${ARCH})..."
        curl -fL -o "$ZIP" "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${ARCH}.zip"
        curl -fL -o /tmp/xray-alpine-install.sh "https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh"
        # 注意：Alpine 安装器是 ash 脚本，用 sh 跑，不用 bash
        sh /tmp/xray-alpine-install.sh install --local "$ZIP"
        rm -f "$ZIP" /tmp/xray-alpine-install.sh
    fi
}

# ---------- 8. 随机端口：shuf 不存在时用 $RANDOM 兜底 ----------
gen_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-65535 -n 1
    else
        echo $((10000 + RANDOM % 55536))
    fi
}

# ---------- 9. Reality 相关：安装 / 卸载 / 查看 ----------
install_reality() {
    # 装 Reality 前先把整套依赖补齐（curl/wget/unzip/openssl 等）
    install_deps
    read -p "请输入监听端口 [留空随机生成]: " PORT
    if [ -z "$PORT" ]; then
        PORT=$(gen_port)
        echo "已随机生成端口: ${PORT}"
    fi
    read -p "请输入伪装域名(SNI) [fonts.gstatic.com]: " SNI
    SNI=${SNI:-fonts.gstatic.com}

    echo "安装/更新 Xray..."
    install_xray

    UUID=$(cat /proc/sys/kernel/random/uuid)
    KEY_OUTPUT=$(xray x25519)
    # 兼容两种输出格式：
    # 旧：PrivateKey: xxx / Password (PublicKey): yyy
    # 新：Private key: xxx / Public key: yyy
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep -i private | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep -iE 'public|password' | awk '{print $NF}')
    SHORT_ID=$(openssl rand -hex 8)
    SERVER_IP=$(curl -s4 --max-time 10 ip.sb || curl -s4 --max-time 10 ifconfig.me || hostname -I 2>/dev/null | awk '{print $1}')

    mkdir -p /usr/local/etc/xray /var/log/xray /usr/local/share/xray
    cat >/usr/local/etc/xray/config.json <<EOF
{
"log":{"loglevel":"warning"},
"inbounds":[{"listen":"0.0.0.0","port":${PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"${SNI}:443","serverNames":["${SNI}"],"privateKey":"${PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}],
"outbounds":[{"protocol":"freedom"}]
}
EOF
    # 新版官方安装器把配置目录设为 root:xray 0750、文件 0640，
    # 写完配置后按这个权限修一下，否则 xray 用户读不到会起不来
    if getent group xray >/dev/null 2>&1; then
        chgrp xray /usr/local/etc/xray/config.json 2>/dev/null || true
        chmod 640 /usr/local/etc/xray/config.json 2>/dev/null || true
    fi

    xray run -test -config /usr/local/etc/xray/config.json
    svc_enable
    svc_restart

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
    echo "系统: ${OS_ID} / init: ${INIT}"
    echo "服务状态: $(svc_status)"
    echo
    echo "$VLESS_LINK"
    echo
}

uninstall_xray() {
    echo "正在卸载 Xray..."
    svc_stop
    svc_disable
    if [ "$INIT" = "systemd" ]; then
        rm -f /etc/systemd/system/xray.service
        rm -f /etc/systemd/system/xray@.service
        rm -rf /etc/systemd/system/xray.service.d
        systemctl daemon-reload
    else
        rm -f /etc/init.d/xray
    fi
    rm -f /usr/local/bin/xray
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray
    if command -v xray >/dev/null 2>&1; then
      echo "❌ 卸载失败"
    else
      echo "✅ Xray 已彻底卸载完成"
    fi
    echo
}

view_node() {
    if [ ! -f /usr/local/etc/xray/node.info ]; then
        echo "未找到节点信息，请先安装。"
        echo
        return 0
    fi
    # shellcheck disable=SC1091
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
    echo
}

reality_menu() {
    while true; do
        if command -v xray >/dev/null 2>&1; then
            CURRENT_VERSION=$(xray version 2>/dev/null | head -n1 | awk '{print $2}')
            echo "当前检测到 Xray 已安装"
            echo "当前版本: ${CURRENT_VERSION}"
        else
            echo "当前未安装 Xray"
        fi
        echo
        echo "========================================"
        echo "      Reality 相关"
        echo "========================================"
        echo "1. 安装 / 更新 Reality"
        echo "2. 卸载 Xray"
        echo "3. 查看当前节点"
        echo "0. 返回上级"
        echo
        read -p "请选择 [0-3]: " MENU || return 0
        case "$MENU" in
            1) install_reality || true ;;
            2) uninstall_xray || true ;;
            3) view_node || true ;;
            0) return 0 ;;
            *) echo "无效选择，请重新输入" ;;
        esac
    done
}

# ---------- 10. 快捷命令 xx ----------
# 在 /usr/local/bin/xx 写一个启动器，每次运行它都会重新从 GitHub 拉最新脚本进菜单
# 自动调用时已存在就不重复提示；手动选 4 时会告诉你已存在还是刚创建好
install_shortcut() {
    local mode="${1:-manual}"
    local target="/usr/local/bin/${SHORTCUT_NAME}"
    if [ -x "$target" ]; then
        if [ "$mode" = "manual" ]; then
            echo "快捷命令 ${SHORTCUT_NAME} 已存在：下次直接输入 ${SHORTCUT_NAME} 即可进入菜单"
        fi
        return 0
    fi
    if ! printf '#!/usr/bin/env bash\nbash <(curl -Ls %s)\n' "$SCRIPT_URL" > "$target" 2>/dev/null; then
        echo "创建快捷命令失败：没有写入 /usr/local/bin 的权限，请用 root 运行"
        return 0
    fi
    chmod +x "$target" 2>/dev/null || true
    echo "快捷命令已创建：下次直接输入 ${SHORTCUT_NAME} 即可进入菜单"
    return 0
}

# ---------- 11. 一级菜单 ----------
# 第一次运行就自动创建快捷命令，之后直接输入 xx 就能进菜单
install_shortcut auto || true
while true; do
    echo
    echo "========================================"
    echo "1. 常用软件"
    echo "2. Reality 相关"
    echo "3. 系统时区调整上海时间"
    echo "4. 创建快捷命令 xx"
    echo "0. 退出"
    echo "========================================"
    read -p "请选择 [0-4]: " MAIN || exit 0
    case "$MAIN" in
        1) common_software_menu ;;
        2) reality_menu ;;
        3) set_timezone_shanghai ;;
        4) install_shortcut manual || true ;;
        0) exit 0 ;;
        *) echo "无效选择，请重新输入" ;;
    esac
done
