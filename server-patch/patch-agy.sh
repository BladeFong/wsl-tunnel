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
        -h|--help)
            echo "用法: $0 [选项]"
            echo "说明: 为 Antigravity 远程服务端安装动态隧道代理包装器"
            echo "选项:"
            echo "  -a, --apply           应用包装器补丁（默认，提供交互菜单确认/选择端点）"
            echo "  -y, --yes             静默应用，直接使用当前已激活的端点（非交互）"
            echo "  -p, --proxy <host:ip> 直接指定代理端点并应用（非交互）"
            echo "  -r, --restore         无损还原所有版本为官方原版二进制"
            echo "  -s, --status          查看当前各版本补丁状态"
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
        for t in "${targets[@]}"; do
            ver=$(basename "$(dirname "$t")")
            printf "  %-12s %s\n" "[$ver]" "$(get_wrapper_status "$t")"
        done
        echo "=================================================="
        ;;
esac
