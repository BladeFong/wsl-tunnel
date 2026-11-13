#!/bin/bash
set -e

# ==============================================================================
# WSL-Tunnel: Per-Session Transparent L3 Proxy for WSL2 (Mirrored Mode)
# ==============================================================================

show_help() {
    cat << 'EOF'
Usage: wsl-tunnel.sh [OPTIONS]

Options:
  -p, --proxy PROXY_URL     SOCKS5 proxy URL (e.g. socks5://127.0.0.1:7897, socks5://192.168.1.253:7890)
                            Default: socks5://127.0.0.1:7897
  -n, --name NAME           Instance / Profile name (e.g. clash, bypass, staging)
                            Note: Linux interface name limit is 15 chars; keep NAME <= 11 chars.
                            Default: clash
  -u, --user USERNAME       Target non-root Linux user to drop privileges to.
                            Default: Auto-detected (SUDO_USER or UID >= 1000)
  -t, --table TABLE_ID      Linux routing table ID (10 - 240)
                            Default: Auto-computed from instance name
  -d, --dns DNS_IP          Custom DNS server for this session
                            Default: 1.1.1.1
  -b, --bin PATH            Explicit path to tun2socks binary
  -k, --stop, --down        Stop the specified tunnel instance and clean up network devices
  -h, --help                Show this help message
EOF
    exit 0
}

# 1. 默认参数
PROXY_URL="socks5://127.0.0.1:7897"
INSTANCE_NAME="clash"
CUSTOM_USER=""
CUSTOM_TABLE=""
CUSTOM_DNS="1.1.1.1"
CUSTOM_BIN=""
STOP_MODE=false

# 辅助函数：校验参数后是否附带有效值
require_arg() {
    local opt="$1"
    local val="$2"
    if [ -z "$val" ] || [[ "$val" =~ ^- ]]; then
        echo "[ERROR] 参数 $opt 需要一个有效值！" >&2
        show_help
    fi
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--proxy)
            require_arg "$1" "$2"
            PROXY_URL="$2"
            shift 2
            ;;
        -n|--name)
            require_arg "$1" "$2"
            INSTANCE_NAME="$2"
            shift 2
            ;;
        -u|--user)
            require_arg "$1" "$2"
            CUSTOM_USER="$2"
            shift 2
            ;;
        -t|--table)
            require_arg "$1" "$2"
            CUSTOM_TABLE="$2"
            shift 2
            ;;
        -d|--dns)
            require_arg "$1" "$2"
            CUSTOM_DNS="$2"
            shift 2
            ;;
        -b|--bin)
            require_arg "$1" "$2"
            CUSTOM_BIN="$2"
            shift 2
            ;;
        -k|--stop|--down)
            STOP_MODE=true
            shift 1
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "[ERROR] 未知参数: $1" >&2
            show_help
            ;;
    esac
done

# 2. 参数合法性校验
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]{1,11}$ ]]; then
    echo "[ERROR] 实例名称 (-n/--name) 仅支持字母、数字、下划线和短横线，且长度不得超过 11 字符 (当前: '$INSTANCE_NAME', 避免超出 Linux 15 字符接口限制)" >&2
    exit 1
fi

if [ -n "$CUSTOM_TABLE" ]; then
    if [[ ! "$CUSTOM_TABLE" =~ ^[0-9]+$ ]] || [ "$CUSTOM_TABLE" -lt 10 ] || [ "$CUSTOM_TABLE" -gt 240 ]; then
        echo "[ERROR] 自定义路由表 ID (--table) 必须为 10 到 240 之间的整数 (输入值: $CUSTOM_TABLE)" >&2
        exit 1
    fi
fi

# 3. 检查执行权限 (必须以 root 运行以配置网络原语)
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 请以 root 权限运行本脚本 (例如: sudo $0 ... 或 wsl.exe -u root -e $0 ...)" >&2
    exit 1
fi

# 4. 执行同级目录可选前置钩子脚本 (Pre-start Hook)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE_HOOK="$SCRIPT_DIR/pre-start.sh"
if [ -x "$PRE_HOOK" ]; then
    "$PRE_HOOK" || true
elif [ -f "$PRE_HOOK" ]; then
    bash "$PRE_HOOK" || true
fi

# 5. 计算路由表 ID 与接口命名
if [ -n "$CUSTOM_TABLE" ]; then
    TABLE_ID="$CUSTOM_TABLE"
else
    # 根据名称散列生成 100~239 范围内的 table_id
    HASH_VAL=$(printf '%d\n' "0x$(echo -n "$INSTANCE_NAME" | md5sum | cut -c1-2)")
    TABLE_ID=$(( 100 + (HASH_VAL % 140) ))
fi

VRF_NAME="vrf-${INSTANCE_NAME}"
TUN_DEV="tun-${INSTANCE_NAME}"
TUN_IP="172.29.$((TABLE_ID % 250)).1/30"
RUN_DIR="/run/wsl-tunnel/${INSTANCE_NAME}"

# 4. 如果是停止模式 (--stop / --down)
if [ "$STOP_MODE" = true ]; then
    echo "[*] 正在停止 WSL-Tunnel 实例 [$INSTANCE_NAME]..."
    
    # 终止后台 tun2socks 进程
    pkill -f "tun2socks.*${TUN_DEV}" >/dev/null 2>&1 || true
    
    # 清理虚拟网络接口 (兼容清理历史残留的虚拟 lo 设备)
    ip link del dev "$TUN_DEV" 2>/dev/null || true
    ip link del dev "lo-${INSTANCE_NAME}" 2>/dev/null || true
    ip link del dev "$VRF_NAME" 2>/dev/null || true
    
    # 清理路由表规则
    ip route flush table "$TABLE_ID" 2>/dev/null || true

    # 清理域内环回放行规则 (raw/nat，均以本实例 VRF 设备为入口匹配)
    if command -v iptables >/dev/null 2>&1; then
        iptables -t raw -D PREROUTING -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT 2>/dev/null || true
        iptables -t nat -D PREROUTING -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT 2>/dev/null || true
    fi

    # 最后一个 VRF 实例关停时，回收前移的 l3mdev 策略规则 (多实例并存时保留)
    if ! ip -o link show type vrf 2>/dev/null | grep -q .; then
        ip rule del pref 0 l3mdev 2>/dev/null || true
    fi

    # 清理运行时 DNS 配置
    rm -rf "$RUN_DIR" 2>/dev/null || true
    rm -f "/tmp/tun2socks-${INSTANCE_NAME}.log" 2>/dev/null || true
    
    echo "[+] 实例 [$INSTANCE_NAME] 已成功关停，所有关联网络资源已释放。"
    exit 0
fi

# 5. 识别降权目标用户
TARGET_USER=""
if [ -n "$CUSTOM_USER" ]; then
    TARGET_USER="$CUSTOM_USER"
elif [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
else
    # 动态探测系统中首个 UID 在 1000~59999 的普通用户
    DETECTED_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
    if [ -n "$DETECTED_USER" ]; then
        TARGET_USER="$DETECTED_USER"
    else
        TARGET_USER=$(id -un 1000 2>/dev/null || true)
    fi
fi

# 如果仍然无法自动识别，或者目标用户不存在于系统，直接拦截并提示
if [ -z "$TARGET_USER" ] || ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "======================================================================" >&2
    echo "[ERROR] 无法自动探查到有效的普通用户，脚本运行已截停！" >&2
    echo "请在命令行显式指定降权用户参数: -u <用户名> 或 --user <用户名>" >&2
    echo "示例: sudo $0 -u <your_username> -p $PROXY_URL -n $INSTANCE_NAME" >&2
    echo "======================================================================" >&2
    exit 1
fi

TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
TARGET_SHELL=$(getent passwd "$TARGET_USER" | cut -d: -f7)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    TARGET_HOME="/home/$TARGET_USER"
fi
if [ -z "$TARGET_SHELL" ] || [ ! -x "$TARGET_SHELL" ]; then
    TARGET_SHELL="/bin/bash"
fi

# 6. 查找 tun2socks 可执行文件
T2S_BIN=""
if [ -n "$CUSTOM_BIN" ] && [ -x "$CUSTOM_BIN" ]; then
    T2S_BIN="$CUSTOM_BIN"
elif [ -n "${TUN2SOCKS_BIN:-}" ] && [ -x "$TUN2SOCKS_BIN" ]; then
    T2S_BIN="$TUN2SOCKS_BIN"
elif command -v tun2socks >/dev/null 2>&1; then
    T2S_BIN=$(command -v tun2socks)
elif [ -x "/usr/local/bin/tun2socks" ]; then
    T2S_BIN="/usr/local/bin/tun2socks"
elif [ -x "$TARGET_HOME/.local/bin/tun2socks" ]; then
    T2S_BIN="$TARGET_HOME/.local/bin/tun2socks"
fi

if [ -z "$T2S_BIN" ]; then
    echo "[ERROR] 未找到 tun2socks 可执行文件！" >&2
    echo "请从官方发布页下载 Linux amd64 版本:" >&2
    echo "  https://github.com/xjasonlyu/tun2socks/releases" >&2
    echo "并放置于 /usr/local/bin/tun2socks 或 ~/.local/bin/tun2socks，或通过 -b 参数指定路径。" >&2
    exit 1
fi

# 7. 提取代理 Host 并自动识别出接口
EXTRA_OPTS=()
temp="${PROXY_URL#*://}"
temp="${temp#*@}"             # 剥离用户名/密码
PROXY_HOST="${temp%%[:/]*}"   # 剥离端口及后置路径

if [ -n "$PROXY_HOST" ] && [ "$PROXY_HOST" != "127.0.0.1" ] && [ "$PROXY_HOST" != "localhost" ]; then
    LAN_IF=$(ip route get "$PROXY_HOST" 2>/dev/null | grep -oP 'dev \K\S+' | head -n 1 || true)
    if [ -n "$LAN_IF" ]; then
        EXTRA_OPTS+=(--interface "$LAN_IF")
    fi
fi

# 8. 启动并复用 tun2socks 守护进程
LOG_FILE="/tmp/tun2socks-${INSTANCE_NAME}.log"
if ! pgrep -f "tun2socks.*${TUN_DEV}" >/dev/null 2>&1; then
    echo "[+] 启动 Linux 原生 tun2socks 隧道守护进程 [$INSTANCE_NAME -> $PROXY_URL]..."
    nohup "$T2S_BIN" \
        --device "tun://$TUN_DEV" \
        --proxy "$PROXY_URL" \
        "${EXTRA_OPTS[@]}" \
        --loglevel warning > "$LOG_FILE" 2>&1 &
    
    for i in {1..25}; do
        if ip link show dev "$TUN_DEV" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi

if ! ip link show dev "$TUN_DEV" >/dev/null 2>&1; then
    echo "[ERROR] tun 设备 $TUN_DEV 创建失败！请查看日志: $LOG_FILE" >&2
    cat "$LOG_FILE" 2>/dev/null || true
    exit 1
fi

# 9. 配置 VRF 隔离域与内核参数
if ! ip link show "$VRF_NAME" >/dev/null 2>&1; then
    ip link add "$VRF_NAME" type vrf table "$TABLE_ID"
fi
ip link set dev "$VRF_NAME" up

sysctl -w net.ipv4.tcp_l3mdev_accept=1 >/dev/null 2>&1 || true
sysctl -w net.ipv4.udp_l3mdev_accept=1 >/dev/null 2>&1 || true

# l3mdev 策略规则前移至优先级 0。WSL2 镜像模式会在优先级 1 注入 "ipproto tcp/udp lookup 127"
# 全局规则（table 127 经 loopback0 中转 Windows 镜像回环桥），会抢先劫持 VRF 域内对 127.0.0.1
# 的路由查找；VRF 驱动对本域出向包的二次查表也仅携带 l3mdev 上下文。前移后域内流量可率先命中
# 实例路由表，且不携带 l3mdev 上下文的主会话流量完全不匹配本规则（零干扰）。
if ! ip rule show | awk '$1 == "0:"' | grep -q "l3mdev"; then
    ip rule add l3mdev pref 0
fi

# 10. 将 TUN 网卡加入 VRF 并配置默认路由与本地回环路由
CURRENT_TUN_MASTER=$(ip -d link show dev "$TUN_DEV" | grep -o 'master [^ ]*' | awk '{print $2}' || true)
if [ "$CURRENT_TUN_MASTER" != "$VRF_NAME" ]; then
    ip link set dev "$TUN_DEV" master "$VRF_NAME"
fi
ip addr add "$TUN_IP" dev "$TUN_DEV" 2>/dev/null || true
ip link set dev "$TUN_DEV" up

# 默认公网流量路由至 TUN 隧道设备
ip route replace default dev "$TUN_DEV" table "$TABLE_ID"

# VRF 域内本地回环路由：local 127.0.0.0/8 指向 VRF 设备自身。内核 VRF 驱动对该路由的出向包
# 执行 vrf_local_xmit 环回（保留 skb_dst 与 l3mdev 上下文重新入栈），使域内 connect 127.0.0.1
# 与默认域监听者（docker-proxy、本机服务等）双向互通；域内自监听的端口由 socket l3mdev 评分
# 天然优先命中，无需任何端口劫持或转发进程。
ip route replace local 127.0.0.0/8 dev "$VRF_NAME" table "$TABLE_ID"

# 11. 放行 VRF 域内环回包重新入栈的路径
# Docker 会为发布端口注入 raw 表规则 "-d 127.0.0.1 ! -i lo --dport X -j DROP" 与 nat 表 DNAT，
# 仅豁免 iif=loopback0（主会话镜像桥路径）。域内环回包经 VRF 设备重新进栈（iif=$VRF_NAME）
# 需要显式放行，并跳过 DNAT：DNAT 转发到容器的回程包无法回到域内客户端，发布端口必须像
# 主会话一样经 docker-proxy 用户态中继完成对接。
if command -v iptables >/dev/null 2>&1; then
    iptables -t raw -C PREROUTING -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT 2>/dev/null || \
        iptables -t raw -I PREROUTING 1 -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT
    iptables -t nat -C PREROUTING -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -i "$VRF_NAME" -d 127.0.0.0/8 -j ACCEPT
else
    echo "[WARN] 未检测到 iptables：Docker 发布端口的域内直连可能被其 raw 表规则拦截" >&2
fi

# 12. 配置受保护的运行时独立 DNS
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"
cat << EOF_DNS > "$RUN_DIR/resolv.conf"
nameserver $CUSTOM_DNS
nameserver 8.8.8.8
EOF_DNS

echo "=================================================="
echo " WSL-Tunnel 已就绪"
echo " 实例名称: $INSTANCE_NAME (Table: $TABLE_ID)"
echo " 代理后端: $PROXY_URL"
echo " 本地回环: 127.0.0.1 (VRF 设备环回, 宿主服务直通)"
echo " 用户身份: $TARGET_USER ($TARGET_SHELL)"
echo "=================================================="

# 14. 单向从属 Mount Namespace 隔离 DNS 并降权进入 VRF 交互终端
exec unshare -m --propagation slave bash -c "
    mount --make-rslave / 2>/dev/null || true
    mount --bind '$RUN_DIR/resolv.conf' /etc/resolv.conf
    cd '$TARGET_HOME'
    exec ip vrf exec '$VRF_NAME' setpriv \
        --reuid='$TARGET_UID' --regid='$TARGET_GID' --init-groups \
        env -i \
        HOME='$TARGET_HOME' \
        USER='$TARGET_USER' \
        LOGNAME='$TARGET_USER' \
        SHELL='$TARGET_SHELL' \
        TERM='${TERM:-xterm-256color}' \
        COLORTERM='${COLORTERM:-}' \
        LANG='${LANG:-C.UTF-8}' \
        LC_ALL='${LC_ALL:-}' \
        PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$TARGET_HOME/.local/bin' \
        WSL_INTEROP='${WSL_INTEROP:-}' \
        WSL_DISTRO_NAME='${WSL_DISTRO_NAME:-}' \
        DISPLAY='${DISPLAY:-}' \
        '$TARGET_SHELL' -l
"
