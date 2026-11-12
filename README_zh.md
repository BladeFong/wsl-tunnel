# WSL-Tunnel

[![Linux VRF](https://img.shields.io/badge/Linux-VRF%20%2F%20l3mdev-FCC624?logo=linux&logoColor=black)](https://docs.kernel.org/networking/vrf.html)
[![Layer 3 Proxy](https://img.shields.io/badge/Network-Layer%203%20Tunnel-4A90E2)](#)
[![tun2socks](https://img.shields.io/badge/Core-tun2socks-2C3E50)](https://github.com/xjasonlyu/tun2socks)
[![Bash](https://img.shields.io/badge/Script-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)

适用于 Windows 11 WSL2（镜像网络模式）的单会话透明三层分流代理方案。无需修改 Windows 宿主网络配置，无需配置 `http_proxy` 环境变量。

[English Documentation](README.md)

---

## 背景与痛点

在 WSL2 镜像模式（`networkingMode=mirrored`）下，处理网络代理常面临以下限制：

1. **应用层代理环境变量局限**：`export http_proxy` 对部分 Go/Rust 编译工具（如各类 AI Agent CLI、Docker、原始 Socket 程序）无效，且无法代理 UDP（如 DNS 解析）。
2. **全局 TUN 模式的副作用**：在 Windows 宿主机开启 VPN 或代理软件的全局 TUN 模式，容易导致 Windows 内部网关冲突、办公内网断联、公司 IT 策略告警及 WSL2 内部 DNS 被 Fake-IP 污染。
3. **跨多网络环境需求**：无法在单个桌面上实现“终端 A 走企业 VPN/内网跳板，终端 B 走代理节点，宿主机与浏览器保持物理直连”。
4. **动态库劫持失效**：`proxychains-ng` 等工具基于 `LD_PRELOAD`，对不经过 glibc 的静态编译程序完全无效。

本项目通过 Linux 原生网络原语，在 WSL2 内部为单个终端会话提供独立的三层透明网络出口，彻底与宿主机解耦。

---

## 实现原理

```text
Windows Terminal (特定标签页)
      │
      ▼ (wsl.exe -u root -e wsl-tunnel.sh -p socks5://... -n <name>)
Linux Mount Namespace (unshare -m --propagation private) ──> 独立挂载纯净 DNS (1.1.1.1)
      │
Linux VRF 路由域 (l3mdev) ────────────> 隔离路由表 (Table ID)
      │                                   │
      ├─ 专属 dummy 网卡 (lo-<name>) ──────┴─> 提供 127.0.0.1 (满足本地 IPC/服务监听)
      │
      └─ 原生 TUN 设备 (tun-<name>)
            │ (原始三层 IP 数据包，无 ARP 依赖)
            ▼
      tun2socks (WSL2 内部用户态守护进程)
            │
            ▼ (使用物理网卡直通发起标准 TCP 连接)
   SOCKS5 代理端口 (旁路由 192.168.x.x:7890 或 本机 127.0.0.1:7897)
```

1. **三层隧道**：在 WSL2 内部启动原生 Linux 版 `tun2socks`，创建 `/dev/net/tun` 设备，自动接管三层 IP 数据包。
2. **会话级路由隔离**：利用 Linux 内核 VRF（虚拟路由转发）与 cgroups-bpf，仅将当前终端所属进程的流量绑定到该 TUN 设备，不影响其他 WSL2 终端。
3. **本地回环补齐**：Linux 默认不允许将物理 `lo` 接口加入 VRF。本方案通过 `dummy` 驱动为该 VRF 创建独立的虚拟回环设备并分配 `127.0.0.1/8`，使需要本地端口监听（如各类 CLI 授权回调、本地 RPC）的工具正常运行。
4. **DNS 防污染与私有挂载**：使用 `unshare -m --propagation private` 局部挂载专有 `resolv.conf`，规避宿主机代理软件的 Fake-IP 干扰，且绝不反向污染宿主及其他会话。

---

## 方案对比

| 指标 | 环境变量 (`http_proxy`) | 宿主全局 TUN | Proxychains | 本方案 (WSL-Tunnel) |
| :--- | :--- | :--- | :--- | :--- |
| **生效粒度** | 仅限读取变量的应用 | 全系统 / 全局 | 单命令 | **单终端会话（会话内所有命令）** |
| **Go/Rust 静态程序支持** | 部分不支持 | 支持 | **完全不支持** | **完整支持（真三层）** |
| **UDP / DNS 代理** | 不支持 | 支持 | 仅限特定 Hook | **支持** |
| **宿主机网络污染** | 无 | **高（全机路由劫持）**| 无 | **无（宿主机完全无感）** |
| **本地服务 (127.0.0.1) 监听** | 正常 | 视规则而定 | 正常 | **正常（内置专用 dummy 回环）** |
| **多代理环境并发** | 繁琐 | 不可能 | 复杂 | **支持（多标签页分别运行）** |

---

## 依赖条件

* Windows 11，已启用 WSL2 并配置 `networkingMode=mirrored`。
* WSL2 发行版为现代 Linux（如 Ubuntu 22.04/24.04，具备内核 VRF 与 dummy 模块支持）。
* 局域网或本机存在可用的 SOCKS5 代理服务端（如 OpenWrt 旁路由、Clash、v2rayA 等）。
* 下载 Linux amd64 版本的 [tun2socks](https://github.com/xjasonlyu/tun2socks/releases)。

---

## 快速使用

### 1. 安装脚本与二进制

从官方发布页 [xjasonlyu/tun2socks/releases](https://github.com/xjasonlyu/tun2socks/releases) 下载 `tun2socks-linux-amd64.zip`，并推荐安装至系统标准路径 `/usr/local/bin`：

```bash
# 解压并安装 tun2socks
sudo unzip tun2socks-linux-amd64.zip tun2socks-linux-amd64 -d /usr/local/bin/
sudo mv /usr/local/bin/tun2socks-linux-amd64 /usr/local/bin/tun2socks
sudo chmod +x /usr/local/bin/tun2socks

# 安装 wsl-tunnel.sh
sudo cp wsl-tunnel.sh /usr/local/bin/wsl-tunnel.sh
sudo chmod +x /usr/local/bin/wsl-tunnel.sh
```

### 2. 命令行启动与停止

```bash
# 语法: sudo /usr/local/bin/wsl-tunnel.sh [参数]

# 示例 1: 走宿主机代理软件（需开启 Allow LAN）
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash

# 示例 2: 走局域网旁路由
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://192.168.1.253:7890 -n bypass

# 示例 3: 停止并释放指定实例的所有网络资源
sudo /usr/local/bin/wsl-tunnel.sh -n clash --stop
```

### 3. 集成至 Windows Terminal（推荐）

打开 Windows Terminal 的 `settings.json`，在 `profiles.list` 中添加一项：

```json
{
    "name": "Ubuntu (Proxy Session)",
    "commandline": "C:\\WINDOWS\\system32\\wsl.exe -u root -e /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash",
    "hidden": false
}
```

之后在 Windows Terminal 下拉菜单中点击该配置，即可秒级打开专属隔离网络终端。

---

## 命令行参数一览

| 参数 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `-p, --proxy` | SOCKS5 代理地址（支持 `socks5://ip:port` 或 `socks5://user:pass@ip:port`） | `socks5://127.0.0.1:7897` |
| `-n, --name` | 实例标识名称（**长度建议不超过 11 字符**，见下文说明） | `clash` |
| `-u, --user` | 降权进入会话的目标 Linux 用户名 | 自动探测（`$SUDO_USER` 或 首个普通用户） |
| `-t, --table` | Linux FIB 路由表编号（`10` 到 `240`） | 根据实例名哈希自动生成 |
| `-d, --dns` | 该会话内独立的 DNS 服务器 IP | `1.1.1.1` |
| `-b, --bin` | 手动指定 `tun2socks` 二进制绝对路径 | 自动搜索（环境变量/PATH/标准目录） |
| `-k, --stop, --down` | 停止指定实例的守护进程并清理全部虚拟网卡和路由表 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

> [!NOTE]
> **网络接口命名长度说明**：Linux 内核对网络接口名称有 15 个字符的硬性上限（`IFNAMSIZ`）。脚本内部会为实例分别创建 `vrf-<name>`、`tun-<name>` 和 `lo-<name>` 虚拟设备，因此 `-n / --name` 参数传入的实例名称**请保持在 11 个字符以内**（仅使用字母、数字、下划线或短横线），避免触发内核接口名超长错误。
