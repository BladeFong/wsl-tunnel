# WSL-Tunnel

[![Linux VRF](https://img.shields.io/badge/Linux-VRF%20%2F%20l3mdev-FCC624?logo=linux&logoColor=black)](https://docs.kernel.org/networking/vrf.html)
[![Layer 3 Proxy](https://img.shields.io/badge/Network-Layer%203%20Tunnel-4A90E2)](#)
[![tun2socks](https://img.shields.io/badge/Core-tun2socks-2C3E50)](https://github.com/xjasonlyu/tun2socks)
[![Bash](https://img.shields.io/badge/Script-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A per-session transparent Layer 3 proxy solution for Linux, verified and battle-tested on Windows 11 WSL2 (mirrored networking mode). Routes designated terminal sessions through SOCKS5 without modifying host networking or relying on `http_proxy` environment variables.

[中文文档 (Chinese)](README.md)

---

## Background & Motivation

In Linux administration, multi-cluster management, and development workflows, routing specific terminal tools (e.g. Go/Rust CLI binaries, container tools, AI agents) through a designated proxy or gateway is a common requirement. Conventional approaches typically present compromises:

1. **Environment Variable Inconsistencies**: `export http_proxy` only works with applications that cooperatively inspect the variable. Statically compiled binaries, raw socket programs, and UDP traffic (such as DNS lookups) routinely bypass or ignore them.
2. **Global Tunneling Pitfalls**: Running a full-system TUN or VPN client hijacks the default route across the entire machine, disrupting local network devices, conflicting with corporate intranet policies, and causing unwanted routing side-effects.
3. **`LD_PRELOAD` Incompatibility**: Interception tools like `proxychains` rely on dynamic `glibc` hooks, rendering them completely ineffective for statically compiled binaries (e.g., Go programs) that issue direct Linux kernel syscalls.
4. **WSL2 Mirrored Mode Specifics**: In Windows 11 WSL2 with `networkingMode=mirrored`, host-side proxies often inject Fake-IP addresses into WSL2's DNS and conflict with LAN routes. Furthermore, because the Linux kernel forbids enslaving the physical loopback (`lo`) interface to a VRF, developer CLI tools fail when binding ephemeral ports (`127.0.0.1:0`) with `cannot assign requested address`.

WSL-Tunnel solves this using native Linux kernel networking primitives (`/dev/net/tun`, `VRF/l3mdev`, VRF device loopback, and private mount namespaces) to construct a dedicated Layer 3 routing domain for a single terminal session: **all commands and child processes in that session route transparently through the proxy, while system-wide networking remains completely untouched.**

---

## Core Primitives & Architecture

```text
Terminal Process Tree (Current shell and its child processes)
      │
      ▼ (wsl-tunnel.sh -p socks5://... -n <name>)
Linux Mount Namespace (unshare -m --propagation slave) ──> Bind-mounts clean DNS (1.1.1.1)
      │
Linux VRF Domain (l3mdev) ────────────> Dedicated FIB table (Table ID)
      │                                   │
      ├─ VRF Device Loopback (vrf_local_xmit) ─────┴─> local 127.0.0.0/8 (Bidirectional access to host & Docker mapped ports)
      │
      └─ Native TUN Device (tun-<name>)
            │ (Raw L3 IP packets, zero ARP overhead)
            ▼
      tun2socks (In-Linux user-space TCP/IP daemon)
            │
            ▼ (Direct TCP stream over default outbound interface)
   SOCKS5 Proxy Endpoint (Local client port or LAN bypass gateway)
```

1. **Pure L3 Tunneling**: Launches a native `tun2socks` daemon attached to `/dev/net/tun`, processing raw IP packets via a user-space TCP/IP stack.
2. **Per-Session VRF Isolation**: Associates the current shell process tree with a dedicated Virtual Routing and Forwarding table via `cgroups-bpf`, leaving the system's global routing table intact.
3. **Bidirectional Loopback Interconnect (VRF Device Loopback)**: Injects a `local 127.0.0.0/8` route pointing at the VRF device itself into the instance routing table. The kernel VRF driver's `vrf_local_xmit` loop re-injects loopback packets back into the local stack while preserving `skb_dst` and the l3mdev context; combined with `net.ipv4.tcp_l3mdev_accept=1`, this yields **bidirectional** connectivity between in-session `connect 127.0.0.1:<port>` and default-namespace listeners (`docker-proxy`, host services, etc.). Two hardening measures accompany this: the l3mdev policy rule is promoted to priority 0 (so it is not preempted by the priority-1 loopback hijack rule `ipproto tcp/udp lookup 127` injected by WSL2 mirrored mode, with zero impact on main-session traffic that carries no l3mdev context), and `iif vrf-<name>` exemptions are added for the raw-table DROP and nat-table DNAT rules that Docker installs for published ports (loopback packets re-entering the stack via the VRF device must be explicitly accepted and must skip DNAT — published ports are relayed by user-space `docker-proxy` exactly as the main session does).
4. **DNS Isolation with Slave Propagation**: Uses `unshare -m --propagation slave` to bind-mount a clean `/etc/resolv.conf`, eliminating host Fake-IP interference while allowing dynamically attached host disks or hot-plugged devices to propagate into the session automatically.

> [!NOTE]
> **Loopback Port Semantics & Space Trade-off**:
> Connections to `127.0.0.1:<port>` from within the session preferentially hit **in-domain listeners** (the kernel naturally scores sockets by their l3mdev binding); when no in-domain listener exists, the connection transparently reaches the same port on the default namespace. Port semantics match Docker `-p` publish declarations exactly: no offset, no proxy rules, no escape commands. The trade-off is that bind-conflict checking applies to the whole network namespace: binding a port inside the session that a host service already listens on yields `EADDRINUSE` (`Address already in use`). For developer and test terminal environments, this is the optimal balance for local container integration.

---

## Feature Comparison

| Feature | `http_proxy` Env | System-Wide TUN / VPN | Proxychains | WSL-Tunnel |
| :--- | :--- | :--- | :--- | :--- |
| **Scope** | Cooperative apps only | Entire machine | Single command | **Per-terminal session (all child commands)** |
| **Go / Rust Static Binaries** | Often ignored | Supported | **Broken** | **Fully supported (Native L3)** |
| **UDP & DNS Handling** | No | Yes | Partial | **Yes (Isolated DNS mount)** |
| **Host System Interference** | None | **High (Host hijacked)** | None | **None (Global networking untouched)** |
| **Local `127.0.0.1` Access & Binding** | Yes | Conditional | Yes | **Yes (VRF loopback, bidirectional; in-domain listeners take precedence)** |
| **Concurrent Multi-Gateways** | Clunky | Impossible | Complex | **Yes (Multiple tabs with distinct proxies)** |

---

## Prerequisites

* **Modern Linux System**: Linux kernel with VRF support (`CONFIG_NET_VRF`) and TUN driver (e.g., Ubuntu 22.04/24.04, Debian 12+, Arch Linux).
* **iptables**: Used to exempt VRF loopback packets from the raw/nat rules Docker installs for published ports; on hosts without Docker, a missing iptables only affects that scenario (the script emits a warning).
* **If running on Windows WSL2**: Windows 11 with WSL2 enabled and configured with `networkingMode=mirrored` in `%USERPROFILE%\.wslconfig`.
* **Accessible SOCKS5 Proxy**: Local proxy client (with Allow LAN if accessed from WSL) or a LAN bypass router.
* **tun2socks Binary**: Download the Linux amd64 binary from [xjasonlyu/tun2socks/releases](https://github.com/xjasonlyu/tun2socks/releases).

---

## Quick Start

### 1. Place the Script and Binary

Install `tun2socks` and `wsl-tunnel.sh` into `/usr/local/bin`:

```bash
# Extract and install tun2socks
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

# Example 1: Route via local proxy client
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash

# Example 2: Route via LAN gateway or remote proxy
sudo /usr/local/bin/wsl-tunnel.sh -p socks5://192.168.1.253:7890 -n bypass

# Example 3: Stop and tear down a tunnel instance
sudo /usr/local/bin/wsl-tunnel.sh -n clash --stop
```

### 3. Windows Terminal Integration (Recommended for WSL2)

Add a profile to your Windows Terminal `settings.json`:

```json
{
    "name": "Ubuntu (Proxy Session)",
    "commandline": "C:\\WINDOWS\\system32\\wsl.exe -u root -e /usr/local/bin/wsl-tunnel.sh -p socks5://127.0.0.1:7897 -n clash",
    "hidden": false
}
```

Launching this profile opens a dedicated tab routed transparently through the proxy while other tabs and Windows applications remain direct.

### 4. Pre-start Hook (Optional)

If a script named `pre-start.sh` exists in the same directory as `wsl-tunnel.sh`, it will be executed automatically before initializing network interfaces. This allows custom environment preparation (e.g., waking up external disks or mounting network shares) without modifying core script logic.

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
> **Instance Name Length Limit**: Linux kernel interface names are strictly limited to 15 characters (`IFNAMSIZ`). Because WSL-Tunnel creates device names with prefixes (`vrf-<name>`, `tun-<name>`), the instance name passed to `-n / --name` **must not exceed 11 characters** (alphanumeric, underscore, or hyphen).

---

## License

This project is licensed under the [MIT License](LICENSE).
