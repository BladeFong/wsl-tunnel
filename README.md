# WSL-Tunnel

A per-session transparent Layer 3 proxy solution for Windows 11 WSL2 (`networkingMode=mirrored`). Routes designated terminal sessions through SOCKS5 without modifying host networking or relying on `http_proxy` environment variables.

[中文文档 (Chinese)](README_zh.md)

---

## Background & Motivation

In WSL2 mirrored networking mode, routing specific terminal tools through proxies typically presents compromises:

1. **Environment Variable Inconsistencies**: Many CLI applications (especially statically compiled Go/Rust tools, container CLIs, and AI Agent workflows) bypass `http_proxy` / `all_proxy` or fail to handle UDP DNS queries.
2. **Global Host TUN Mode Pitfalls**: Running global TUN clients on the Windows host often creates routing conflicts with enterprise VPNs, disconnects LAN devices, and causes DNS poisoning in WSL2 due to host-side Fake-IP resolution.
3. **Multi-Environment Concurrency**: Developers often need Terminal A connected to a staging network, Terminal B to a proxy gateway, while keeping the Windows host and browsers on direct physical connections.
4. **`LD_PRELOAD` Incompatibility**: Tools like `proxychains-ng` fail on statically linked binaries because Go programs issue raw syscalls rather than calling dynamic `glibc` hooks.

WSL-Tunnel addresses this directly in the Linux kernel by creating an isolated Layer 3 routing domain for each designated terminal session inside WSL2.

---

## Architecture

```text
Windows Terminal Profile
      │
      ▼ (wsl.exe -u root -e wsl-tunnel.sh -p socks5://... -n <name>)
Linux Mount Namespace (unshare -m --propagation private) ──> Bind-mounts clean DNS (1.1.1.1)
      │
Linux VRF Domain (l3mdev) ────────────> Dedicated FIB table (Table ID)
      │                                   │
      ├─ Dummy Interface (lo-<name>) ─────┴─> Provides 127.0.0.1/8 inside VRF
      │
      └─ Native TUN Device (tun-<name>)
            │ (Raw L3 IP packets, zero ARP overhead)
            ▼
      tun2socks (Daemon running inside WSL2)
            │
            ▼ (Standard TCP stream over physical interface)
   SOCKS5 Proxy (Local host 127.0.0.1:7897 or LAN Gateway 192.168.x.x:7890)
```

* **Pure L3 Tunneling**: Launches an in-WSL `tun2socks` daemon attached to a native `/dev/net/tun` interface, processing raw IP packets via a userspace TCP/IP stack.
* **Per-Session VRF Isolation**: Associates the current shell process tree with a dedicated Virtual Routing and Forwarding table via `cgroups-bpf`, preventing route leakage to other WSL sessions.
* **VRF Loopback Emulation**: Because the Linux kernel forbids enslaving the global `lo` interface to a VRF, a dedicated `dummy` network device assigned `127.0.0.1/8` is attached to the VRF. This ensures local IPC and ephemeral listeners (e.g., `127.0.0.1:0` used by CLI login flows and agents) bind and function normally.
* **DNS Isolation**: Uses `unshare -m --propagation private` to bind-mount a clean `/etc/resolv.conf` exclusively within that terminal process tree, eliminating host-side Fake-IP interference without modifying global system files or leaking mounts to other sessions.

---

## Feature Comparison

| Feature | `http_proxy` Env | Host Global TUN | Proxychains | WSL-Tunnel |
| :--- | :--- | :--- | :--- | :--- |
| **Scope** | Cooperative apps only | System-wide | Per-command | **Per-terminal session** |
| **Go / Rust Static Binaries** | Often ignored | Supported | **Broken** | **Fully supported (Native L3)** |
| **UDP & DNS Handling** | No | Yes | Partial | **Yes** |
| **Host System Interference** | None | **High (Host hijacked)** | None | **None (Host untouched)** |
| **Local `127.0.0.1` Binding** | Yes | Conditional | Yes | **Yes (Dedicated dummy lo)** |
| **Concurrent Multi-Gateways** | Clunky | Impossible | Complex | **Yes (Multiple tabs)** |

---

## Prerequisites

* Windows 11 with WSL2 enabled and configured with `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`.
* Modern Linux distribution in WSL2 (e.g., Ubuntu 22.04 or 24.04 with standard VRF and dummy module support).
* An accessible SOCKS5 proxy server (e.g., local proxy client with Allow LAN, router gateway, or remote proxy).
* Download the Linux amd64 binary of [tun2socks](https://github.com/xjasonlyu/tun2socks/releases).

---

## Quick Start

### 1. Place the Script and Binary

Download `tun2socks` from [xjasonlyu/tun2socks/releases](https://github.com/xjasonlyu/tun2socks/releases) (`tun2socks-linux-amd64.zip`), then install the binary and script into `/usr/local/bin`:

```bash
# Install tun2socks
sudo unzip tun2socks-linux-amd64.zip tun2socks-linux-amd64 -d /usr/local/bin/
sudo mv /usr/local/bin/tun2socks-linux-amd64 /usr/local/bin/tun2socks
sudo chmod +x /usr/local/bin/tun2socks

# Install wsl-tunnel.sh
sudo cp wsl-tunnel.sh /usr/local/bin/wsl-tunnel.sh
sudo chmod +x /usr/local/bin/wsl-tunnel.sh
```

### 2. Manual CLI Usage

```bash
# Syntax: sudo /usr/local/bin/wsl-tunnel.sh [OPTIONS]

# Example 1: Route via a local proxy client
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash

# Example 2: Route via a LAN gateway / bypass router
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://192.168.1.253:7890 -n bypass

# Example 3: Stop and tear down a tunnel instance
sudo /usr/local/bin/wsl-tunnel.sh -n clash --stop
```

### 3. Windows Terminal Integration (Recommended)

Add a profile to your Windows Terminal `settings.json`:

```json
{
    "name": "Ubuntu (Proxy Session)",
    "commandline": "C:\\WINDOWS\\system32\\wsl.exe -u root -e /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash",
    "hidden": false
}
```

Launching this profile creates a dedicated tab running transparently through the specified proxy endpoint while all other tabs and Windows applications remain direct.

---

## CLI Options

| Flag | Description | Default |
| :--- | :--- | :--- |
| `-p, --proxy` | SOCKS5 proxy URL (`socks5://ip:port` or `socks5://user:pass@ip:port`) | `socks5://127.0.0.1:7897` |
| `-n, --name` | Instance profile name (**Must be ≤ 11 characters**, see note below) | `clash` |
| `-u, --user` | Target non-root Linux username to drop privileges to | Auto-detected |
| `-t, --table` | Linux FIB routing table ID (`10` - `240`) | Auto-hashed from name |
| `-d, --dns` | Custom DNS server IP address | `1.1.1.1` |
| `-b, --bin` | Custom path to the `tun2socks` binary | Auto-detected |
| `-k, --stop, --down` | Tear down the tunnel daemon and release all network devices | - |
| `-h, --help` | Display help message and exit | - |

> [!NOTE]
> **Instance Name Length Limit**: Linux kernel interface names are strictly limited to 15 characters (`IFNAMSIZ`). Because WSL-Tunnel creates device names with prefixes (`vrf-<name>`, `tun-<name>`, `lo-<name>`), the instance name passed to `-n / --name` **must not exceed 11 characters** (alphanumeric, underscore, or hyphen).
