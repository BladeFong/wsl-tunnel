# WSL-Tunnel

[![Linux VRF](https://img.shields.io/badge/Linux-VRF%20%2F%20l3mdev-FCC624?logo=linux&logoColor=black)](https://docs.kernel.org/networking/vrf.html)
[![Layer 3 Proxy](https://img.shields.io/badge/Network-Layer%203%20Tunnel-4A90E2)](#)
[![tun2socks](https://img.shields.io/badge/Core-tun2socks-2C3E50)](https://github.com/xjasonlyu/tun2socks)
[![Bash](https://img.shields.io/badge/Script-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

适用于 Linux 的单会话透明三层分流代理方案，并在 Windows 11 WSL2（镜像网络模式）下完成深度验证与生产实践。无需配置应用层 `http_proxy` 环境变量，无需全局 TUN 接管整机网络。

[English Documentation](README_en.md)

---

## 背景与设计初衷

在 Linux 运维、多集群管理以及开发调试环境中，经常需要将特定终端工具（如各类 Go/Rust 编译的 CLI、Docker、AI Agent）接入代理或特定网关，而常规方案往往存在不可调和的妥协：

1. **应用层代理变量局限**：`export http_proxy` 仅对主动读取该环境变量的软件生效。大量静态编译工具、原始 Socket 程序以及 UDP 请求（如 DNS 解析）会直接绕过代理。
2. **全局接管代价高昂**：在整机开启全局 TUN 或系统级 VPN 会修改系统默认路由，不仅导致局域网设备断联、内网服务冲突，还会对所有不相关进程造成网络干扰。
3. **动态链接劫持 (`LD_PRELOAD`) 失效**：`proxychains` 等工具基于 glibc 动态挂钩，对静态编译、直接发起 Linux 系统调用（Syscall）的程序（如 Go 编译产物）完全不起作用。
4. **WSL2 镜像网络的特有痛点**：在 Windows 11 WSL2 镜像模式（`networkingMode=mirrored`）下，宿主机代理软件容易造成 Fake-IP 污染与内网网关冲突；更严重的是，Linux 内核默认不允许将物理 `lo` 接口加入 VRF，导致各类开发者工具在绑定本地随机端口（`127.0.0.1:0`）时频频抛出 `cannot assign requested address`。

本项目完全基于 Linux 内核原生网络原语（TUN、VRF/l3mdev、VRF 设备环回、Mount Namespace），在操作系统内部开辟专属的三层路由域：**会话内所有命令与子进程全量透明分流，系统全局网络与宿主机物理连接则保持零干扰。**

---

## 核心原语与架构

```text
终端进程树 (当前 Shell 及其子进程)
      │
      ▼ (wsl-tunnel.sh -p socks5://... -n <name>)
Linux 挂载命名空间 (unshare -m --propagation slave) ──> 独立挂载纯净 DNS (1.1.1.1)
      │
Linux VRF 路由域 (l3mdev) ────────────> 隔离 FIB 路由表 (Table ID)
      │                                   │
      ├─ 本地回环互通 (127.0.0.0/8) ───────┴─> 直连宿主服务与 Docker 容器映射
      │
      └─ 原生 TUN 设备 (tun-<name>)
            │ (标准三层原始 IP 数据包，无 ARP 依赖)
            ▼
      tun2socks (用户态隧道守护进程)
            │
            ▼ (使用宿主合法出接口直通发起标准 TCP 连接)
   SOCKS5 代理端点 (局域网网关/旁路由 或 本机代理端口)
```

1. **原生三层隧道**：在 Linux 内部启动原生 `tun2socks` 守护进程，接管 `/dev/net/tun` 设备，以用户态 TCP/IP 栈透明接管全量 IP 数据包。
2. **会话级路由隔离**：利用内核 VRF（虚拟路由转发）与 cgroups-bpf，仅将当前终端所属进程树绑定至指定 FIB 路由表，不修改系统全局主路由表。
3. **宿主与 Docker 服务直连**：会话内 `127.0.0.1:<port>` 优先命中会话内监听，其次透明直达宿主同端口服务——本机服务与 Docker 发布端口（如 `3003`、`5432`）均可直接访问，与 `-p` 发布声明零偏移，无需任何代理规则或逃逸命令；Docker 容器与端口的增删、重启无需重跑脚本。
4. **DNS 隔离与单向从属挂载**：使用 `unshare -m --propagation slave` 局部挂载专属 `resolv.conf`，既彻底规避宿主 Fake-IP 干扰，又允许外部磁盘或新设备的挂载单向自动同步进入会话。
5. **GUI 应用兼容**：透传 WSLg 桌面会话环境，隧道终端内可直接运行 Edge 等图形应用，音频输出正常。

> [!NOTE]
> **端口空间权衡**：会话内监听的端口若与宿主机已有服务同端口，将报 `EADDRINUSE`（端口绑定检查作用于整个网络命名空间）。对开发与测试终端场景，这是保证容器服务与本地工具畅通互连的取舍。

---

## 方案特性对比

| 指标 | 环境变量 (`http_proxy`) | 整机全局 TUN / VPN | Proxychains | 本方案 (WSL-Tunnel) |
| :--- | :--- | :--- | :--- | :--- |
| **生效范围** | 仅限主动读取变量的程序 | 全局系统接管 | 单命令前缀 | **单终端会话（会话内所有程序）** |
| **Go / Rust 静态编译支持** | 部分忽略 / 行为不一 | 支持 | **完全不支持** | **完整支持（内核三层接管）** |
| **UDP 与 DNS 处理** | 不支持 | 支持 | 仅限特定 Hook | **支持（独立 DNS 挂载）** |
| **系统网络干扰** | 无 | **高（整机路由篡改）** | 无 | **无（系统全局无感）** |
| **本地服务 (127.0.0.1) 访问与监听** | 正常 | 视规则而定 | 正常 | **正常（直连宿主与 Docker，会话内监听优先）** |
| **多环境并发隔离** | 繁琐易冲突 | 无法并发 | 复杂 | **支持（多终端运行不同节点）** |

---

## 已知边界

* **明文 DNS 可能被污染**：会话内 DNS 为明文 53/UDP（`1.1.1.1` / `8.8.8.8`）。若代理端将该 UDP 直连出网（未走代理节点），墙内网络会对敏感域名注入伪造应答，表现为"同一站点时通时不通、解析到非官方 IP"。建议在代理侧让 DNS 的 UDP 走代理节点，或客户端启用加密 DNS（DoH）。

---

## 依赖条件

* **现代 Linux 系统**：内核支持 VRF（`CONFIG_NET_VRF`）以及 TUN 驱动（如 Ubuntu 22.04/24.04、Debian 12+、Arch Linux 等）。
* **iptables**：用于放行域内环回包绕过 Docker 发布端口的 raw/nat 规则；无 Docker 的环境中缺失时仅影响该场景（脚本会给出警告）。
* **若运行于 Windows WSL2**：Windows 11，已启用 WSL2 并在 `%USERPROFILE%\.wslconfig` 中配置 `networkingMode=mirrored`。
* **代理服务端点**：局域网或本机可访问的 SOCKS5 服务（如 Clash、v2rayA、OpenWrt 旁路由等）。
* **可执行文件**：从 [xjasonlyu/tun2socks/releases](https://github.com/xjasonlyu/tun2socks/releases) 下载 Linux amd64 版本的 `tun2socks`。

---

## 快速使用

### 1. 安装脚本与二进制

推荐将二进制与脚本放置于系统标准路径 `/usr/local/bin`：

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

# 示例 1: 走本机代理软件端口（若在 WSL2 中需开启 Allow LAN）
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash

# 示例 2: 走局域网旁路由 / 远程代理网关
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://192.168.1.253:7890 -n bypass

# 示例 3: 释放并停止指定实例的虚拟网卡与守护进程
sudo /usr/local/bin/wsl-tunnel.sh -n clash --stop
```

### 3. Windows Terminal 集成（WSL2 场景推荐）

在 Windows Terminal 的 `settings.json` 中添加一个专属配置项：

```json
{
    "name": "Ubuntu (Proxy Session)",
    "commandline": "C:\\WINDOWS\\system32\\wsl.exe -u root -e /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash",
    "hidden": false
}
```

在 Windows Terminal 下拉菜单中点击该选项，即可秒级打开专属隔离网络终端。

### 4. 前置扩展钩子（可选）

若在 `wsl-tunnel.sh` 同级目录下存在 `pre-start.sh`，脚本将在初始化网络前自动调用执行。适用于个性化环境准备（如提前唤醒外部磁盘、挂载网络存储等），彻底与核心脚本解耦。

---

## 命令行参数一览

| 参数 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `-p, --proxy` | SOCKS5 代理地址（支持 `socks5://ip:port` 或带凭证的 `socks5://user:pass@ip:port`） | `socks5://127.0.0.1:7897` |
| `-n, --name` | 实例标识名称（**长度建议不超过 11 字符**，见下文说明） | `clash` |
| `-u, --user` | 降权进入会话的目标 Linux 用户名 | 自动探测（`$SUDO_USER` 或 首个普通用户） |
| `-t, --table` | Linux FIB 路由表编号（`10` 到 `240`） | 根据实例名哈希自动生成 |
| `-d, --dns` | 该会话内独立的 DNS 服务器 IP | `1.1.1.1` |
| `-b, --bin` | 手动指定 `tun2socks` 二进制绝对路径 | 自动搜索（环境变量/PATH/标准目录） |
| `-k, --stop, --down` | 停止指定实例的守护进程并清理全部虚拟网卡和路由表 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

> [!NOTE]
> **网络接口命名长度说明**：Linux 内核对网络接口名称有 15 个字符的硬性上限（`IFNAMSIZ`）。脚本内部会为实例分别创建 `vrf-<name>` 与 `tun-<name>` 虚拟设备，因此 `-n / --name` 参数传入的实例名称**请保持在 11 个字符以内**（仅使用字母、数字、下划线或短横线），避免触发内核接口名超长错误。

---

## 开源协议

本项目采用 [MIT 许可证](LICENSE)。
