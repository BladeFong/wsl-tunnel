#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/switch.sh"

AGY_SERVER_BASE="$HOME/.antigravity-server/bin"

# 探测所有版本的 language_server 路径
find_targets() {
    local targets=()
    if [ -d "$AGY_SERVER_BASE" ]; then
        for ver_dir in "$AGY_SERVER_BASE"/*; do
            if [ -d "$ver_dir" ]; then
                targets+=("$ver_dir/language_server")
            fi
        done
    fi
    echo "${targets[@]}"
}

# 探测当前活跃版本
get_active_version() {
    local agentapi="$HOME/.gemini/antigravity/bin/agentapi"
    if [ -f "$agentapi" ]; then
        local ver
        ver=$(grep -oE '\.antigravity-server/bin/[^/]+/' "$agentapi" 2>/dev/null | awk -F'/' '{print $3}' | head -n 1)
        if [ -n "$ver" ] && [ -d "$AGY_SERVER_BASE/$ver" ]; then
            echo "$ver"
            return 0
        fi
    fi

    local proc_ver
    proc_ver=$(pgrep -af "language_server" 2>/dev/null | grep -oE '\.antigravity-server/bin/[^/]+/' | awk -F'/' '{print $3}' | head -n 1)
    if [ -n "$proc_ver" ] && [ -d "$AGY_SERVER_BASE/$proc_ver" ]; then
        echo "$proc_ver"
        return 0
    fi

    if [ -d "$AGY_SERVER_BASE" ]; then
        local latest
        latest=$(ls -1 "$AGY_SERVER_BASE" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$latest" ] && [ -d "$AGY_SERVER_BASE/$latest" ]; then
            echo "$latest"
            return 0
        fi
    fi

    return 1
}

# 安全清理旧版本目录
clean_old_versions() {
    local active_ver
    active_ver=$(get_active_version || true)

    if [ -z "$active_ver" ]; then
        echo "[!] 未能确定当前活跃的 Antigravity 服务端版本，为保证安全终止清理。"
        return 1
    fi

    echo "[*] 当前活跃版本: $active_ver (将被保留)"

    local old_dirs=()
    for dir in "$AGY_SERVER_BASE"/*; do
        if [ -d "$dir" ]; then
            local v
            v=$(basename "$dir")
            if [ "$v" != "$active_ver" ]; then
                old_dirs+=("$dir")
            fi
        fi
    done

    if [ ${#old_dirs[@]} -eq 0 ]; then
        echo "[✓] 没有发现旧版本目录，无需清理。"
        return 0
    fi

    echo "[*] 发现以下旧版本可清理:"
    for d in "${old_dirs[@]}"; do
        local sz
        sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        echo "    - $(basename "$d") ($sz)"
    done

    if [ "$NON_INTERACTIVE" = false ]; then
        echo -n "确认删除以上旧版本以释放磁盘空间？[Y/n]: "
        read -r confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            echo "[*] 操作已取消。"
            return 0
        fi
    fi

    for d in "${old_dirs[@]}"; do
        echo "[*] 正在删除: $d ..."
        rm -rf "$d"
    done
    echo "=================================================="
    echo "[✓] 旧版本清理完成！已保留活跃版本 [$active_ver]。"
    echo "=================================================="
}

ACTION="apply"
CUSTOM_PROXY=""
NON_INTERACTIVE=false

while [ $# -gt 0 ]; do
    case "$1" in
        -a|--apply)
            ACTION="apply"
            shift
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        -p|--proxy)
            CUSTOM_PROXY="$2"
            shift 2
            ;;
        -r|--restore)
            ACTION="restore"
            shift
            ;;
        -s|--status)
            ACTION="status"
            shift
            ;;
        -c|--clean)
            ACTION="clean"
            shift
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo "说明: 为 Antigravity 远程服务端安装动态隧道代理包装器"
            echo "选项:"
            echo "  -a, --apply           应用包装器补丁（默认，提供交互菜单确认/选择端点）"
            echo "  -y, --yes             静默执行（直接使用当前端点 / 自动确认）"
            echo "  -p, --proxy <host:ip> 直接指定代理端点并应用（非交互）"
            echo "  -r, --restore         无损还原所有版本为官方原版二进制"
            echo "  -s, --status          查看当前各版本补丁状态"
            echo "  -c, --clean           安全清理废弃的历史旧版本以释放磁盘空间"
            echo "  -h, --help            显示本帮助信息"
            exit 0
            ;;
        *)
            echo "[!] 未知参数: $1 (查看帮助: $0 -h)"
            exit 1
            ;;
    esac
done

targets=($(find_targets))
if [ ${#targets[@]} -eq 0 ]; then
    echo "[!] 未在 $AGY_SERVER_BASE 找到任何 Antigravity 服务端版本目录"
    exit 0
fi

case "$ACTION" in
    apply)
        if [ -n "$CUSTOM_PROXY" ]; then
            set_current_endpoint "$CUSTOM_PROXY"
        elif [ "$NON_INTERACTIVE" = false ]; then
            choose_and_set_endpoint
        fi
        
        cur_ep=$(get_current_endpoint)
        echo "[*] 正在为 Antigravity 服务端安装动态包装器 (生效端点: $cur_ep)..."
        for t in "${targets[@]}"; do
            apply_wrapper "$t"
        done
        echo "=================================================="
        echo "[✓] 动态包装器就绪！共处理 ${#targets[@]} 个版本。"
        echo "    已配置代理: $cur_ep (后续可随时运行 switch.sh 切换)"
        echo "=================================================="
        ;;
    restore)
        echo "[*] 正在还原 Antigravity 服务端原版二进制..."
        for t in "${targets[@]}"; do
            restore_wrapper "$t"
        done
        echo "=================================================="
        echo "[✓] 还原操作完成。"
        echo "=================================================="
        ;;
    status)
        echo "=================================================="
        echo " Antigravity Server 补丁状态"
        echo " 基础路径: $AGY_SERVER_BASE"
        echo "=================================================="
        active_ver=$(get_active_version || true)
        for t in "${targets[@]}"; do
            ver=$(basename "$(dirname "$t")")
            tag=""
            if [ "$ver" = "$active_ver" ]; then
                tag=" (active)"
            fi
            printf "  %-12s %s%s\n" "[$ver]" "$(get_wrapper_status "$t")" "$tag"
        done
        echo "=================================================="
        ;;
    clean)
        clean_old_versions
        ;;
esac
