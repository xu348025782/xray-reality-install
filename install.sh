#!/usr/bin/env bash
set -e

# Xray 版本：以后想换版本只改这一行
# 注意：v26.3.27 是 pre-26.9.8 的版本，客户端用旧核心、不用加
# support-x25519mlkem768 就能连；换成 26.9.8+ 则新旧客户端都要对应升级。
XRAY_VERSION="v26.3.27"

# 快捷命令名：下次直接输入这个就能进菜单，想换名字只改这一行
SHORTCUT_NAME="xx"
SCRIPT_URL="https://raw.githubusercontent.com/xu348025782/xray-reality-install/main/install.sh"
# 本地保存的脚本：xx 只跑这份本地文件，不联网、不默认更新；
# 只有菜单 7 更新脚本时，才从上面的 SCRIPT_URL 拉新版覆盖它
LOCAL_SCRIPT="/usr/local/bin/xray-reality-install.sh"

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
    local name="$1" bin="$1"
    # 包名和命令名不一定一样：nftables 包提供的命令是 nft，不是 nftables，
    # 按包名查命令会误报“安装失败”（2026-11-16 在 Alpine 上实测到过）
    case "$name" in
        nftables) bin="nft" ;;
    esac
    if command -v "$bin" >/dev/null 2>&1; then
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
    if [ "$ok" = "1" ] && command -v "$bin" >/dev/null 2>&1; then
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

# ---------- 10. nftables 端口转发：中转机 -> 落地机 ----------
# 规则数据文件：一行一条，格式 proto|本机端口|落地机地址|落地机端口
# proto: tcp / udp / tcp+udp；落地机地址 v4 或 v6 都行
# 注意：地址族要跟客户端连中转机的方式一致——写 v6 地址就是 v6 转发，
# 客户端要连中转机的 v6 地址；写 v4 就是 v4 转发。只做 DNAT 不够，
# 还要 masquerade，否则落地机回包直回客户端、源地址对不上会被丢。
NFT_RULES_FILE="/usr/local/etc/nft-forward.rules"
NFT_GEN_FILE="/etc/nftables-forward.nft"

nft_valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -ge 1 ] && [ "$1" -le 65535 ] ;;
    esac
}

nft_is_v6() {
    case "$1" in *:* ) return 0 ;; *) return 1 ;; esac
}

nft_valid_ip() {
    local ip="$1" a b c d extra o
    if nft_is_v6 "$ip"; then
        case "$ip" in
            *[!0-9a-fA-F:.]*) return 1 ;;
            *:* ) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$ip" in *[!0-9.]*) return 1 ;; esac
    IFS=. read -r a b c d extra <<EOF
$ip
EOF
    [ -n "$extra" ] || [ -z "$a" ] || [ -z "$b" ] || [ -z "$c" ] || [ -z "$d" ] && return 1
    for o in "$a" "$b" "$c" "$d"; do
        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

nft_ensure_installed() {
    if command -v nft >/dev/null 2>&1; then return 0; fi
    echo "未找到 nft，正在安装 nftables..."
    install_one_tool nftables || true
    if command -v nft >/dev/null 2>&1; then return 0; fi
    echo "nftables 安装失败，请手动安装后再试"
    return 1
}

nft_enable_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' > /etc/sysctl.d/99-nft-forward.conf 2>/dev/null || true
    return 0
}

# 按数据文件生成 nft 规则文件：v4 走 table ip，v6 走 table ip6，
# 每条都是 prerouting DNAT + postrouting masquerade，tcp+udp 展开成两条
nft_gen_file() {
    local v4pre v4post v6pre v6post proto listen target tport protos p
    v4pre=$(mktemp); v4post=$(mktemp); v6pre=$(mktemp); v6post=$(mktemp)
    : > "$v4pre"; : > "$v4post"; : > "$v6pre"; : > "$v6post"
    if [ -f "$NFT_RULES_FILE" ]; then
        while IFS='|' read -r proto listen target tport || [ -n "$proto" ]; do
            [ -z "$proto" ] && continue
            case "$proto" in
                tcp|udp) protos="$proto" ;;
                tcp+udp) protos="tcp udp" ;;
                *) continue ;;
            esac
            for p in $protos; do
                if nft_is_v6 "$target"; then
                    echo "        $p dport $listen dnat ip6 to [$target]:$tport" >> "$v6pre"
                    echo "        ip6 daddr $target $p dport $tport masquerade" >> "$v6post"
                else
                    echo "        $p dport $listen dnat ip to $target:$tport" >> "$v4pre"
                    echo "        ip daddr $target $p dport $tport masquerade" >> "$v4post"
                fi
            done
        done < "$NFT_RULES_FILE"
    fi
    {
        echo "# 由 xray-reality-install-multi.sh 的 nftables 端口转发菜单生成"
        echo "# 请勿手动改，改规则用菜单 6；数据文件：$NFT_RULES_FILE"
        if [ -s "$v4pre" ]; then
            echo "table ip nft_forward {"
            echo "    chain prerouting {"
            echo "        type nat hook prerouting priority dstnat; policy accept;"
            cat "$v4pre"
            echo "    }"
            echo "    chain postrouting {"
            echo "        type nat hook postrouting priority srcnat; policy accept;"
            cat "$v4post"
            echo "    }"
            echo "}"
        fi
        if [ -s "$v6pre" ]; then
            echo "table ip6 nft_forward {"
            echo "    chain prerouting {"
            echo "        type nat hook prerouting priority dstnat; policy accept;"
            cat "$v6pre"
            echo "    }"
            echo "    chain postrouting {"
            echo "        type nat hook postrouting priority srcnat; policy accept;"
            cat "$v6post"
            echo "    }"
            echo "}"
        fi
    } > "$NFT_GEN_FILE"
    rm -f "$v4pre" "$v4post" "$v6pre" "$v6post"
    return 0
}

nft_forward_is_active() {
    command -v nft >/dev/null 2>&1 || return 1
    nft list tables 2>/dev/null | grep -q "nft_forward"
}

# 持久化：让主配置文件 include 生成的文件，重启后还在。
# 若主配置里已有 policy drop 的 filter 表，先不自动设开机自启，
# 避免重启后 filter 挡住 SSH 和转发端口——先在 filter 里放行再手动开。
nft_persist() {
    local main=""
    if [ -f /etc/nftables.conf ]; then main="/etc/nftables.conf"
    elif [ -f /etc/nftables.nft ]; then main="/etc/nftables.nft"
    elif [ "$INIT" = "systemd" ]; then main="/etc/nftables.conf"
    else main="/etc/nftables.nft"; fi
    if [ ! -f "$main" ]; then
        printf 'flush ruleset\ninclude "%s"\n' "$NFT_GEN_FILE" > "$main" 2>/dev/null || return 0
    elif ! grep -q "nftables-forward.nft" "$main" 2>/dev/null; then
        echo "include \"$NFT_GEN_FILE\"" >> "$main" 2>/dev/null || true
    fi
    if grep -q "policy drop" "$main" 2>/dev/null; then
        echo "注意：主 nftables 配置里有 policy drop 的 filter 表，"
        echo "本次未自动设置 nftables 开机自启，请先在 filter 里放行 SSH 端口和转发端口，再手动设置开机自启。"
        return 0
    fi
    if [ "$INIT" = "systemd" ]; then
        systemctl enable nftables >/dev/null 2>&1 || true
    else
        rc-update add nftables default >/dev/null 2>&1 || true
    fi
    echo "已设置开机自启（重启后转发规则还在）"
    return 0
}

# 生成 -> 检查 -> 加载 -> 持久化；检查不过就不应用，数据文件已保存可再试
nft_apply() {
    nft_ensure_installed || return 1
    nft_enable_forwarding
    nft_gen_file
    if ! nft -c -f "$NFT_GEN_FILE" 2>/tmp/nft-check.err; then
        echo "nft 规则检查未通过，未应用："
        cat /tmp/nft-check.err 2>/dev/null || true
        rm -f /tmp/nft-check.err
        return 1
    fi
    rm -f /tmp/nft-check.err
    nft delete table ip nft_forward 2>/dev/null || true
    nft delete table ip6 nft_forward 2>/dev/null || true
    if ! nft -f "$NFT_GEN_FILE" 2>/tmp/nft-apply.err; then
        echo "nft 规则加载失败："
        cat /tmp/nft-apply.err 2>/dev/null || true
        rm -f /tmp/nft-apply.err
        return 1
    fi
    rm -f /tmp/nft-apply.err
    nft_persist
    return 0
}

nft_forward_list() {
    echo
    if [ ! -f "$NFT_RULES_FILE" ] || [ ! -s "$NFT_RULES_FILE" ]; then
        echo "当前没有转发规则"
    else
        echo "已添加的转发规则："
        awk -F'|' '{printf "%d. %s  本机:%s  ->  %s:%s\n", NR, $1, $2, $3, $4}' "$NFT_RULES_FILE"
    fi
    echo
    if nft_forward_is_active; then
        echo "转发状态：已启动"
        nft list table ip nft_forward 2>/dev/null || true
        nft list table ip6 nft_forward 2>/dev/null || true
    else
        echo "转发状态：已停止"
    fi
    echo
    return 0
}

nft_forward_add() {
    local proto_choice proto listen target tport confirm
    echo
    echo "添加转发规则"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. TCP+UDP"
    read -p "请选择协议 [1-3]: " proto_choice || return 0
    case "$proto_choice" in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="tcp+udp" ;;
        *) echo "无效选择"; return 0 ;;
    esac
    read -p "本机监听端口 [回车随机 10000-65535，或自己输入]: " listen || return 0
    if [ -z "$listen" ]; then
        listen=$(gen_port)
        echo "已随机生成本机端口: ${listen}"
    fi
    if ! nft_valid_port "$listen"; then
        echo "端口无效：请输入 1-65535"
        return 0
    fi
    read -p "落地机地址 (v4 或 v6): " target || return 0
    if ! nft_valid_ip "$target"; then
        echo "地址无效：请输入落地机的 v4 或 v6 地址"
        return 0
    fi
    if nft_is_v6 "$target"; then
        echo "提示：v6 地址 = v6 转发，客户端要连中转机的 v6 地址"
    else
        echo "提示：v4 地址 = v4 转发，客户端要连中转机的 v4 地址"
    fi
    while true; do
        read -p "落地机端口 (自己输入，没有默认值): " tport || return 0
        if nft_valid_port "$tport"; then break; fi
        echo "端口无效：请输入 1-65535"
    done
    if [ -f "$NFT_RULES_FILE" ] && grep -q "^${proto}|${listen}|" "$NFT_RULES_FILE" 2>/dev/null; then
        echo "该协议 + 本机端口已有规则，请先删除旧规则再添加"
        return 0
    fi
    echo
    echo "确认添加：${proto}  本机:${listen}  ->  ${target}:${tport}"
    read -p "确认吗？[Y/n]: " confirm || return 0
    case "$confirm" in
        n|N) echo "已取消"; return 0 ;;
    esac
    mkdir -p "$(dirname "$NFT_RULES_FILE")" 2>/dev/null || true
    echo "${proto}|${listen}|${target}|${tport}" >> "$NFT_RULES_FILE"
    if nft_apply; then
        echo "转发规则已添加并生效：${proto} ${listen} -> ${target}:${tport}"
    else
        echo "规则已保存，但本次未生效，请按上面提示检查后再从菜单 6 启动"
    fi
    echo
    return 0
}

nft_forward_delete() {
    local num total
    nft_forward_list || true
    [ ! -f "$NFT_RULES_FILE" ] || [ ! -s "$NFT_RULES_FILE" ] && return 0
    total=$(wc -l < "$NFT_RULES_FILE")
    read -p "输入要删除的规则编号 [1-${total}]，回车取消: " num || return 0
    [ -z "$num" ] && return 0
    case "$num" in *[!0-9]*) echo "编号无效"; return 0 ;; esac
    if [ "$num" -lt 1 ] || [ "$num" -gt "$total" ]; then echo "编号超出范围"; return 0; fi
    awk -v n="$num" 'NR != n' "$NFT_RULES_FILE" > "${NFT_RULES_FILE}.tmp" && mv "${NFT_RULES_FILE}.tmp" "$NFT_RULES_FILE"
    if [ -s "$NFT_RULES_FILE" ]; then
        if nft_forward_is_active; then nft_apply || true; fi
    else
        nft delete table ip nft_forward 2>/dev/null || true
        nft delete table ip6 nft_forward 2>/dev/null || true
        nft_gen_file
    fi
    echo "已删除第 ${num} 条规则"
    echo
    return 0
}

nft_forward_clear() {
    local confirm
    nft_forward_list || true
    [ ! -f "$NFT_RULES_FILE" ] || [ ! -s "$NFT_RULES_FILE" ] && return 0
    read -p "确认清空全部转发规则？[y/N]: " confirm || return 0
    case "$confirm" in
        y|Y) ;;
        *) echo "已取消"; return 0 ;;
    esac
    : > "$NFT_RULES_FILE"
    nft delete table ip nft_forward 2>/dev/null || true
    nft delete table ip6 nft_forward 2>/dev/null || true
    nft_gen_file
    echo "已清空全部转发规则"
    echo
    return 0
}

nft_forward_toggle() {
    if nft_forward_is_active; then
        nft delete table ip nft_forward 2>/dev/null || true
        nft delete table ip6 nft_forward 2>/dev/null || true
        echo "转发已停止（规则已保存，选 5 再启动会重新加载）"
    else
        if [ ! -f "$NFT_RULES_FILE" ] || [ ! -s "$NFT_RULES_FILE" ]; then
            echo "当前没有转发规则，请先选 1 添加"
            return 0
        fi
        if nft_apply; then
            echo "转发已启动"
        else
            echo "转发启动失败，请按上面提示检查"
        fi
    fi
    echo
    return 0
}

nft_forward_menu() {
    while true; do
        echo
        echo "========================================"
        echo "      nftables 端口转发"
        echo "========================================"
        if nft_forward_is_active; then
            echo "转发状态：已启动"
        else
            echo "转发状态：已停止"
        fi
        echo "1. 添加转发规则"
        echo "2. 查看转发规则"
        echo "3. 删除转发规则"
        echo "4. 清空所有转发规则"
        echo "5. 启动 / 停止转发"
        echo "0. 返回上级"
        echo
        read -p "请选择 [0-5]: " SUB || return 0
        case "$SUB" in
            1) nft_forward_add || true ;;
            2) nft_forward_list || true ;;
            3) nft_forward_delete || true ;;
            4) nft_forward_clear || true ;;
            5) nft_forward_toggle || true ;;
            0) return 0 ;;
            *) echo "无效选择，请重新输入" ;;
        esac
    done
}

# ---------- 11. 快捷命令 xx + 本地保存 + 更新脚本 ----------
# xx 是本地模式：只跑 LOCAL_SCRIPT，不联网拉取，所以平时进菜单不会默认更新。
# 只有菜单 7 更新脚本时，才从 GitHub 拉新版覆盖 LOCAL_SCRIPT，再重进菜单。
# 本地文件不存在时（比如被误删），xx 才回落到从 GitHub 拉一次。
install_shortcut() {
    local mode="${1:-manual}"
    local target="/usr/local/bin/${SHORTCUT_NAME}"
    if [ -x "$target" ] && grep -qF "$LOCAL_SCRIPT" "$target" 2>/dev/null; then
        if [ "$mode" = "manual" ]; then
            echo "快捷命令 ${SHORTCUT_NAME} 已存在：下次直接输入 ${SHORTCUT_NAME} 即可进入菜单"
        fi
        return 0
    fi
    if ! printf '#!/usr/bin/env bash\nif [ -f "%s" ]; then\n  exec bash "%s" "$@"\nelse\n  bash <(curl -Ls %s)\nfi\n' "$LOCAL_SCRIPT" "$LOCAL_SCRIPT" "$SCRIPT_URL" > "$target" 2>/dev/null; then
        echo "创建快捷命令失败：没有写入 /usr/local/bin 的权限，请用 root 运行"
        return 0
    fi
    chmod +x "$target" 2>/dev/null || true
    echo "快捷命令已创建：下次直接输入 ${SHORTCUT_NAME} 即可进入菜单"
    return 0
}

# 把当前运行的脚本存一份到本地，供 xx 下次直接跑。
# 从文件跑的（bash /路径/脚本.sh）：直接复制那个文件；
# 从管道跑的（bash <(curl …)）：BASH_SOURCE 是 /dev/fd/…，没法复制，
# 就从 GitHub 再拉一次存下来——反正这次跑的版本就是刚拉下来的那份。
# 从 xx 本地模式跑的：源文件就是 LOCAL_SCRIPT 本身，跳过不重复保存。
save_local_copy() {
    local src="${BASH_SOURCE[0]:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        case "$src" in /dev/fd/*|/proc/self/fd/*) src="" ;; esac
    else
        src=""
    fi
    if [ -n "$src" ]; then
        if [ "$src" != "$LOCAL_SCRIPT" ]; then
            cp "$src" "$LOCAL_SCRIPT" 2>/dev/null || true
            chmod +x "$LOCAL_SCRIPT" 2>/dev/null || true
        fi
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then return 0; fi
    if curl -fsSL "$SCRIPT_URL" -o "${LOCAL_SCRIPT}.tmp" 2>/dev/null; then
        if bash -n "${LOCAL_SCRIPT}.tmp" 2>/dev/null; then
            mv "${LOCAL_SCRIPT}.tmp" "$LOCAL_SCRIPT" 2>/dev/null || true
            chmod +x "$LOCAL_SCRIPT" 2>/dev/null || true
        else
            rm -f "${LOCAL_SCRIPT}.tmp"
        fi
    fi
    return 0
}

# 菜单 7 更新脚本：唯一会联网拉新版的地方。
# 下载 -> bash -n 检查 -> 和本地版比对：一样就报已是最新，不同就覆盖本地
# 并用 exec 重进新版菜单；下载或检查失败就留在旧版不动。
update_script() {
    local tmp="/tmp/xray-reality-install-new.sh"
    echo "正在从 GitHub 检查最新版..."
    if ! command -v curl >/dev/null 2>&1; then
        install_one_tool curl || true
    fi
    if ! curl -fsSL "$SCRIPT_URL" -o "$tmp" 2>/dev/null; then
        echo "更新失败：下载不到最新版，请检查网络或 GitHub 仓库，当前仍是旧版"
        rm -f "$tmp"
        return 0
    fi
    if ! bash -n "$tmp" 2>/dev/null; then
        echo "更新失败：下载到的新版语法检查没过，已丢弃，当前仍是旧版"
        rm -f "$tmp"
        return 0
    fi
    if [ -f "$LOCAL_SCRIPT" ] && cmp -s "$tmp" "$LOCAL_SCRIPT"; then
        echo "已是最新版本，无需更新"
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$LOCAL_SCRIPT" 2>/dev/null || { echo "更新失败：写不进 $LOCAL_SCRIPT，请用 root 运行"; rm -f "$tmp"; return 0; }
    chmod +x "$LOCAL_SCRIPT" 2>/dev/null || true
    echo "更新成功，正在进入新版菜单..."
    sleep 1 2>/dev/null || true
    exec bash "$LOCAL_SCRIPT"
}

# ---------- 12. 切换 V4/V6 优先：gai.conf 版 ----------
# 借鉴 ssh_tool 第 10 项的做法：优先 V4 就是在 /etc/gai.conf 里加
# precedence ::ffff:0:0/96  100，优先 V6 就是删掉这行恢复默认。
# 只改 gai.conf，不做 Alpine 特殊处理；不提供禁用 IPv6 的选项。
# 注意：只影响出站解析域名时选 v4 还是 v6，不影响 Reality 地址（写死的 IP）。
ip_priority_menu() {
    local GAI_CONF="/etc/gai.conf"
    while true; do
        echo
        echo "========================================"
        echo "      切换 V4/V6 优先"
        echo "========================================"
        if grep -qE '^\s*precedence\s+::ffff:0:0/96\s+100' "$GAI_CONF" 2>/dev/null; then
            echo "当前网络优先级设置：IPv4 优先"
        else
            echo "当前网络优先级设置：IPv6 优先"
        fi
        echo "1. 优先 V4"
        echo "2. 优先 V6"
        echo "0. 返回上级"
        echo
        read -p "请选择 [0-2]: " SUB || return 0
        case "$SUB" in
            1)
                [ ! -f "${GAI_CONF}.bak" ] && cp "$GAI_CONF" "${GAI_CONF}.bak" 2>/dev/null || true
                [ ! -f "$GAI_CONF" ] && touch "$GAI_CONF" 2>/dev/null || true
                sed -i '/^\s*precedence\s\+::ffff:0:0\/96/d' "$GAI_CONF" 2>/dev/null || true
                echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
                # IPv6 被禁用的话，优先 V4 也连不上 v6，先问要不要重新开启
                v6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "")
                if [ "$v6_disabled" = "1" ]; then
                    echo
                    echo "IPv6 已禁用，是否需要开启？[Y/N]"
                    read -p "是否需要开启？[Y/N]: " choice || true
                    if [[ "$choice" =~ [Yy] ]]; then
                        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
                        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
                        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
                        sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
                        sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
                        sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf 2>/dev/null || true
                        {
                            echo "net.ipv6.conf.all.disable_ipv6 = 0"
                            echo "net.ipv6.conf.default.disable_ipv6 = 0"
                            echo "net.ipv6.conf.lo.disable_ipv6 = 0"
                        } >> /etc/sysctl.conf 2>/dev/null || true
                        sysctl -p >/dev/null 2>&1 || true
                    fi
                fi
                echo
                echo "已切换为 IPv4 优先（IPv6 仍然可用，只是优先级降低）"
                echo
                ;;
            2)
                [ ! -f "${GAI_CONF}.bak" ] && cp "$GAI_CONF" "${GAI_CONF}.bak" 2>/dev/null || true
                [ ! -f "$GAI_CONF" ] && touch "$GAI_CONF" 2>/dev/null || true
                # 移除 IPv4 优先规则即可恢复默认 IPv6 优先
                sed -i '/^\s*precedence\s\+::ffff:0:0\/96/d' "$GAI_CONF" 2>/dev/null || true
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
                echo
                echo "已切换为 IPv6 优先（IPv4 仍然可用，只是优先级降低）"
                echo
                ;;
            0) return 0 ;;
            *) echo "无效选择，请重新输入" ;;
        esac
    done
}

# ---------- 12. 本机信息：借鉴 ssh_tool 第 1 项 ----------
# 显示内容和 ssh_tool 第 1 项一致：主机名、运营商、系统版本、内核、
# CPU（架构/型号/核心数/占用）、内存、虚拟内存、硬盘、总收发流量、
# 拥堵算法、公网 v4/v6、地理位置、系统时间、运行时长；另加一行网络优先级。
# 配色也和 ssh_tool 一样：项目白色、数值紫色（非终端时不上色）。
# 只读不改任何配置；查公网 IP 和地理位置要联网（curl -m 2，超时就显示未知）。
# 看完按任意键才回菜单（执行完成 / 按任意键返回...），不直接把菜单打出来。
show_local_info() {
    local hostname_val os_info kernel_version cpu_arch cpu_info cpu_cores
    local cpu_usage cpu_stat1 cpu_stat2 mem_info swap_info disk_info
    local rx_str tx_str traffic_nums
    local congestion_algorithm queue_algorithm ipv4_address ipv6_address
    local country city isp_info current_time runtime priority_text
    local C_WHITE C_PURPLE C_GREEN C_YELLOW C_NC
    # 颜色：项目白色、具体数值紫色，和 ssh_tool 第 1 项一样；
    # 不是终端（比如重定向到文件）就不上色
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
        C_WHITE=$'\033[1;97m'; C_PURPLE=$'\033[1;35m'
        C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_NC=$'\033[0m'
    else
        C_WHITE=""; C_PURPLE=""; C_GREEN=""; C_YELLOW=""; C_NC=""
    fi
    hostname_val=$(hostname 2>/dev/null || echo "未知")
    kernel_version=$(uname -r 2>/dev/null || echo "未知")
    cpu_arch=$(uname -m 2>/dev/null || echo "未知")
    cpu_cores=$(nproc 2>/dev/null || echo "未知")

    # CPU 型号：x86_64 读 /proc/cpuinfo，其他架构用 lscpu
    if [ "$cpu_arch" = "x86_64" ]; then
        cpu_info=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | sed -e 's/model name[[:space:]]*: //')
    else
        cpu_info=$(lscpu 2>/dev/null | grep 'Model name' | sed -e 's/Model name[[:space:]]*: //')
    fi
    [ -z "$cpu_info" ] && cpu_info="未知"

    # CPU 占用：不用 top 解析——top 在容器里算出的数会错（ssh_tool 在这台
    # Alpine 上就显示过 3282.00%），改成读两次 /proc/stat 自己算：
    # 占用 = 100 * (1 - 空闲增量 / 总增量)，结果一定在 0-100 之间
    cpu_usage=""
    if [ -r /proc/stat ]; then
        cpu_stat1=$(awk '/^cpu /{t=0; for (i=2; i<=NF; i++) t+=$i; print t, $5+$6}' /proc/stat 2>/dev/null || true)
        sleep 0.5 2>/dev/null || true
        cpu_stat2=$(awk '/^cpu /{t=0; for (i=2; i<=NF; i++) t+=$i; print t, $5+$6}' /proc/stat 2>/dev/null || true)
        cpu_usage=$(awk -v a="$cpu_stat1" -v b="$cpu_stat2" 'BEGIN{split(a, A, " "); split(b, B, " "); dt=B[1]-A[1]; di=B[2]-A[2]; if (dt > 0) printf "%.2f", 100*(1-di/dt)}' 2>/dev/null || true)
    fi
    [ -z "$cpu_usage" ] && cpu_usage="未知"

    # 内存 / 虚拟内存
    if command -v free >/dev/null 2>&1; then
        mem_info=$(free -b 2>/dev/null | awk 'NR==2 && $2 > 0 {printf "%.2f/%.2f MB (%.2f%%)", $3/1024/1024, $2/1024/1024, $3*100/$2}' || true)
        swap_info=$(free -m 2>/dev/null | awk 'NR==3 {if ($2 == 0) print "0MB/0MB (0%)"; else printf "%sMB/%sMB (%d%%)", $3, $2, $3*100/$2}' || true)
    fi
    [ -z "$mem_info" ] && mem_info="未知"
    [ -z "$swap_info" ] && swap_info="未知"

    # 硬盘占用（根分区）：直接用 df -h 原值带单位显示，不用 %d 截断，
    # 否则 Used 是 M、Size 是 G 时会显示成 "49/7GB" 这种错数
    disk_info=$(df -h 2>/dev/null | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}' || true)
    [ -z "$disk_info" ] && disk_info="未知"

    # 总接收 / 总发送（/proc/net/dev 各网卡求和），分别存成两个字符串好上色
    rx_str="未知"; tx_str="未知"
    if [ -r /proc/net/dev ]; then
        traffic_nums=$(awk 'BEGIN { rx_total = 0; tx_total = 0 }
            NR > 2 { rx_total += $2; tx_total += $10 }
            END {
                rx_units = "Bytes"; tx_units = "Bytes";
                if (rx_total > 1024) { rx_total /= 1024; rx_units = "KB"; }
                if (rx_total > 1024) { rx_total /= 1024; rx_units = "MB"; }
                if (rx_total > 1024) { rx_total /= 1024; rx_units = "GB"; }
                if (tx_total > 1024) { tx_total /= 1024; tx_units = "KB"; }
                if (tx_total > 1024) { tx_total /= 1024; tx_units = "MB"; }
                if (tx_total > 1024) { tx_total /= 1024; tx_units = "GB"; }
                printf("%.2f %s %.2f %s", rx_total, rx_units, tx_total, tx_units);
            }' /proc/net/dev 2>/dev/null || true)
        if [ -n "$traffic_nums" ]; then
            rx_str=$(echo "$traffic_nums" | awk '{print $1, $2}')
            tx_str=$(echo "$traffic_nums" | awk '{print $3, $4}')
        fi
    fi

    congestion_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    queue_algorithm=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")

    # 系统版本：lsb_release 没有就读 /etc/os-release，再没有就读发行文件
    os_info=$(lsb_release -ds 2>/dev/null || true)
    if [ -z "$os_info" ]; then
        if [ -f "/etc/os-release" ]; then
            os_info=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | sed -e 's/^PRETTY_NAME=//' -e 's/^"//' -e 's/"$//')
        elif [ -f "/etc/debian_version" ]; then
            os_info="Debian $(cat /etc/debian_version 2>/dev/null)"
        elif [ -f "/etc/redhat-release" ]; then
            os_info=$(cat /etc/redhat-release 2>/dev/null)
        else
            os_info="Unknown"
        fi
    fi

    # 公网 IP 和地理位置：curl 不在或超时就显示未知
    if command -v curl >/dev/null 2>&1; then
        ipv4_address=$(curl -s -m 2 ipv4.ip.sb 2>/dev/null || true)
        ipv6_address=$(curl -s -m 2 ipv6.ip.sb 2>/dev/null || true)
        country=$(curl -s -m 2 ipinfo.io/country 2>/dev/null || true)
        city=$(curl -s -m 2 ipinfo.io/city 2>/dev/null || true)
        isp_info=$(curl -s -m 2 ipinfo.io/org 2>/dev/null || true)
    fi
    [ -z "$ipv4_address" ] && ipv4_address="未知"
    [ -z "$ipv6_address" ] && ipv6_address="未知"
    [ -z "$isp_info" ] && isp_info="未知"

    current_time=$(date "+%Y-%m-%d %I:%M %p" 2>/dev/null || echo "未知")
    runtime=$(awk -F. '{run_days=int($1 / 86400); run_hours=int(($1 % 86400) / 3600); run_minutes=int(($1 % 3600) / 60); if (run_days > 0) printf("%d天 ", run_days); if (run_hours > 0) printf("%d时 ", run_hours); printf("%d分\n", run_minutes)}' /proc/uptime 2>/dev/null || echo "未知")

    # 网络优先级：和菜单 8 同一个判断——gai.conf 里有 precedence 100 就是 V4 优先，
    # 没有就是 V6 优先（默认）；musl 系统（Alpine）不读 gai.conf，顺带注明不生效
    if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100([[:space:]]|$)' /etc/gai.conf 2>/dev/null; then
        priority_text="IPv4 优先"
    else
        priority_text="IPv6 优先（默认）"
    fi
    if ls /lib/ld-musl-* >/dev/null 2>&1 || ldd --version 2>&1 | grep -qi musl; then
        priority_text="$priority_text（gai.conf 不生效）"
    fi

    echo
    echo -e "${C_WHITE}系统信息详情${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}主机名: ${C_PURPLE}${hostname_val}${C_NC}"
    echo -e "${C_WHITE}运营商: ${C_PURPLE}${isp_info}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}系统版本: ${C_PURPLE}${os_info}${C_NC}"
    echo -e "${C_WHITE}Linux版本: ${C_PURPLE}${kernel_version}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}CPU架构: ${C_PURPLE}${cpu_arch}${C_NC}"
    echo -e "${C_WHITE}CPU型号: ${C_PURPLE}${cpu_info}${C_NC}"
    echo -e "${C_WHITE}CPU核心数: ${C_PURPLE}${cpu_cores}${C_NC}"
    echo "------------------------"
    if [ "$cpu_usage" = "未知" ]; then
        echo -e "${C_WHITE}CPU占用: ${C_PURPLE}未知${C_NC}"
    else
        echo -e "${C_WHITE}CPU占用: ${C_PURPLE}${cpu_usage}%${C_NC}"
    fi
    echo -e "${C_WHITE}物理内存: ${C_PURPLE}${mem_info}${C_NC}"
    echo -e "${C_WHITE}虚拟内存: ${C_PURPLE}${swap_info}${C_NC}"
    echo -e "${C_WHITE}硬盘占用: ${C_PURPLE}${disk_info}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}总接收: ${C_PURPLE}${rx_str}${C_NC}"
    echo -e "${C_WHITE}总发送: ${C_PURPLE}${tx_str}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}网络拥堵算法: ${C_PURPLE}${congestion_algorithm} ${queue_algorithm}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}公网IPv4地址: ${C_PURPLE}${ipv4_address}${C_NC}"
    echo -e "${C_WHITE}公网IPv6地址: ${C_PURPLE}${ipv6_address}${C_NC}"
    echo -e "${C_WHITE}网络优先级: ${C_PURPLE}${priority_text}${C_NC}"
    echo "------------------------"
    if [ -n "$country" ] || [ -n "$city" ]; then
        echo -e "${C_WHITE}地理位置: ${C_PURPLE}${country} ${city}${C_NC}"
    else
        echo -e "${C_WHITE}地理位置: ${C_PURPLE}未知${C_NC}"
    fi
    echo -e "${C_WHITE}系统时间: ${C_PURPLE}${current_time}${C_NC}"
    echo "------------------------"
    echo -e "${C_WHITE}系统运行时长: ${C_PURPLE}${runtime}${C_NC}"
    echo
    # 和 ssh_tool 一样：看完按任意键才回菜单，不直接把菜单打出来
    echo -e "${C_GREEN}执行完成${C_NC}"
    echo -e "${C_YELLOW}按任意键返回...${C_NC}"
    read -n 1 -s -r -p "" 2>/dev/null || true
    echo ""
    clear 2>/dev/null || true
    return 0
}

# ---------- 13. 一级菜单 ----------
# 第一次运行先把当前脚本存到本地、再自动创建快捷命令，
# 之后直接输入 xx 就能进菜单（跑本地文件，不默认更新）
save_local_copy || true
install_shortcut auto || true
while true; do
    echo
    echo "========================================"
    echo "1. 本机信息"
    echo "2. 常用软件"
    echo "3. Reality 相关"
    echo "4. 系统时区调整上海时间"
    echo "5. 创建快捷命令 xx"
    echo "6. nftables 端口转发"
    echo "7. 更新脚本"
    echo "8. 切换 V4/V6 优先"
    echo "0. 退出"
    echo "========================================"
    read -p "请选择 [0-8]: " MAIN || exit 0
    case "$MAIN" in
        1) show_local_info ;;
        2) common_software_menu ;;
        3) reality_menu ;;
        4) set_timezone_shanghai ;;
        5) install_shortcut manual || true ;;
        6) nft_forward_menu ;;
        7) update_script || true ;;
        8) ip_priority_menu ;;
        0) exit 0 ;;
        *) echo "无效选择，请重新输入" ;;
    esac
done
