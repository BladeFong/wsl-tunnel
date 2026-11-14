#!/bin/bash
# server-patch 通用代理切换器与函数库 (Proxy Switcher & Common Library)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_FILE="$SCRIPT_DIR/endpoints.cache"
CURRENT_FILE="$SCRIPT_DIR/current_endpoint"

# 初始化缓存与当前端点配置
init_cache() {
    if [ ! -f "$CACHE_FILE" ]; then
        cat << 'EOF' > "$CACHE_FILE"
127.0.0.1:7897
192.168.1.253:7890
EOF
    fi

    if [ ! -f "$CURRENT_FILE" ]; then
        echo "127.0.0.1:7897" > "$CURRENT_FILE"
    fi
}

# 获取当前全局激活的代理端点
get_current_endpoint() {
    init_cache
    local cur
    cur=$(head -n 1 "$CURRENT_FILE" 2>/dev/null | tr -d '\r' | xargs)
    if [ -z "$cur" ]; then
        cur="127.0.0.1:7897"
    fi
    echo "$cur"
}

# 设置当前全局激活的代理端点
set_current_endpoint() {
    local target="$1"
    init_cache
    echo "$target" > "$CURRENT_FILE"
    # 同时确保追加到候选缓存中
    if ! grep -Fxq "$target" "$CACHE_FILE" 2>/dev/null; then
        echo "$target" >> "$CACHE_FILE"
    fi
}

# 交互式切换全局代理端点
choose_and_set_endpoint() {
    init_cache
    local current_ep
    current_ep=$(get_current_endpoint)
    
    local endpoints=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            endpoints+=("$line")
        fi
    done < "$CACHE_FILE"

    echo "=================================================="
    echo " 远程服务端 (Remote Server) 代理端点切换"
    echo " 当前生效: $current_ep"
    echo "=================================================="
    echo "[?] 请选择要切换的目标代理端点 (SOCKS5/HTTP):"
    
    local idx=1
    local default_choice=1
    for ep in "${endpoints[@]}"; do
        local tag=""
        if [ "$ep" = "$current_ep" ]; then
            tag="[当前生效]"
            default_choice=$idx
        fi
        
        local desc=""
        if [ "$ep" = "127.0.0.1:7897" ]; then
            desc="(本机 Clash Verge / 默认)"
        elif [ "$ep" = "192.168.1.253:7890" ]; then
            desc="(局域网旁路由网关)"
        else
            desc="(已缓存)"
        fi
        
        printf "  %2d) %-22s %-22s %s\n" "$idx" "$ep" "$desc" "$tag"
        idx=$((idx + 1))
    done
    printf "  %2d) [输入新的 IP:端口并缓存]\n" "$idx"
    echo "--------------------------------------------------"

    local choice
    read -r -p "请输入选项编号 [默认: $default_choice]: " choice || true
    choice=$(echo "$choice" | xargs)
    if [ -z "$choice" ]; then
        choice="$default_choice"
    fi

    local selected=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$idx" ]; then
        selected="${endpoints[$((choice - 1))]}"
    elif [ "$choice" -eq "$idx" ]; then
        local new_ep
        while true; do
            read -r -p "请输入代理地址 (格式 host:port, 例如 192.168.1.200:7890): " new_ep || true
            new_ep=$(echo "$new_ep" | xargs)
            if [[ "$new_ep" =~ ^[0-9a-zA-Z.-]+:[0-9]+$ ]]; then
                break
            else
                echo "[!] 格式不合法，请使用 host:port 格式（如 192.168.1.200:7890）"
            fi
        done
        selected="$new_ep"
    else
        echo "[!] 无效选项，保持当前: $current_ep"
        selected="$current_ep"
    fi

    set_current_endpoint "$selected"
    echo "=================================================="
    echo "[✓] 全局代理已成功切换为: $selected"
    echo "    所有已打补丁的客户端下次启动将自动使用此端点。"
    echo "=================================================="
}

# 为单个目标二进制应用动态包装器
apply_wrapper() {
    local target_bin="$1"
    local bin_dir
    bin_dir="$(dirname "$target_bin")"
    local bin_name
    bin_name="$(basename "$target_bin")"
    local real_bin="$bin_dir/${bin_name}.real"

    if [ ! -f "$target_bin" ] && [ ! -f "$real_bin" ]; then
        echo "[!] 目标文件不存在: $target_bin"
        return 1
    fi

    # 首次应用时备份原二进制
    if [ -f "$target_bin" ] && [ ! -f "$real_bin" ]; then
        mv "$target_bin" "$real_bin"
        echo "[+] 已备份原二进制: $bin_name -> ${bin_name}.real"
    fi

    # 写入动态读取配置的通用包装脚本
    cat << EOF > "$target_bin"
#!/bin/bash
REAL_BIN="\$(dirname "\$0")/${bin_name}.real"

# 1. 自动尝试加入活跃的 wsl-tunnel VRF cgroup
for cgroup_file in /sys/fs/cgroup/non-systemd/vrf/vrf-*/cgroup.procs; do
    if [ -w "\$cgroup_file" ]; then
        echo \$\$ > "\$cgroup_file" 2>/dev/null && break
    fi
done

# 2. 动态读取当前激活的代理端点 (单次读 1 行文件，耗时 < 1ms)
CONF_FILE="${CURRENT_FILE}"
if [ -f "\$CONF_FILE" ]; then
    PROXY_ADDR="\$(head -n 1 "\$CONF_FILE" 2>/dev/null | tr -d '\r' | xargs)"
fi
PROXY_ADDR="\${PROXY_ADDR:-127.0.0.1:7897}"

# 3. 注入代理环境变量 (双重保险)
export ALL_PROXY="socks5://\${PROXY_ADDR}"
export all_proxy="socks5://\${PROXY_ADDR}"
export HTTP_PROXY="http://\${PROXY_ADDR}"
export http_proxy="http://\${PROXY_ADDR}"
export HTTPS_PROXY="http://\${PROXY_ADDR}"
export https_proxy="http://\${PROXY_ADDR}"
export NO_PROXY="localhost,127.0.0.1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"
export no_proxy="localhost,127.0.0.1,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8"

exec "\$REAL_BIN" "\$@"
EOF
    chmod +x "$target_bin"
    echo "[✓] 动态包装器已就绪: $target_bin"
}

# 还原单个目标二进制
restore_wrapper() {
    local target_bin="$1"
    local bin_dir
    bin_dir="$(dirname "$target_bin")"
    local bin_name
    bin_name="$(basename "$target_bin")"
    local real_bin="$bin_dir/${bin_name}.real"

    if [ -f "$real_bin" ]; then
        mv -f "$real_bin" "$target_bin"
        chmod +x "$target_bin"
        echo "[✓] 已还原原版二进制: $target_bin"
    fi
}

# 获取单个目标二进制的补丁状态
get_wrapper_status() {
    local target_bin="$1"
    local bin_dir
    bin_dir="$(dirname "$target_bin")"
    local bin_name
    bin_name="$(basename "$target_bin")"
    local real_bin="$bin_dir/${bin_name}.real"

    if [ -f "$real_bin" ]; then
        local cur_ep
        cur_ep=$(get_current_endpoint)
        echo "已打补丁 (动态跟随全局端点: $cur_ep)"
    elif [ -f "$target_bin" ]; then
        echo "原版二进制 (未打补丁)"
    else
        echo "不存在"
    fi
}

# 仅在直接执行时处理命令行交互
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -eq 0 ]; then
        choose_and_set_endpoint
        exit 0
    fi

    case "$1" in
        -s|--status)
            echo "当前全局激活代理端点: $(get_current_endpoint)"
            exit 0
            ;;
        -h|--help)
            echo "用法: $0 [选项 | 目标端点]"
            echo "说明: 交互式切换或直接指定所有客户端包装器的代理端点"
            echo "示例:"
            echo "  $0                      # 交互式菜单选择"
            echo "  $0 192.168.1.253:7890   # 直接指定并切换"
            echo "  $0 --status             # 查看当前端点"
            exit 0
            ;;
        *)
            TARGET="$1"
            if [[ "$TARGET" =~ ^[0-9a-zA-Z.-]+:[0-9]+$ ]]; then
                set_current_endpoint "$TARGET"
                echo "[✓] 全局代理已切换为: $TARGET"
            else
                echo "[!] 格式不合法，请使用 host:port 格式（如 192.168.1.253:7890）"
                exit 1
            fi
            ;;
    esac
fi
