# paqet-tunnel

Easy installer for tunneling VPN traffic through a middle server using [paqet](https://github.com/hanselime/paqet) — raw packet-level tunneling that bypasses network restrictions.

**PVN optimized installer:** v2.1.0-pvn1  
**Original full-menu installer:** v2.0.0

## PVN low-overhead installer (recommended)

The optimized installer uses an explicit KCP manual profile that also works with the current upstream Paqet binary. It is tuned to reduce unnecessary ACK/retransmit traffic on healthy links while retaining large windows for high-throughput Iran ↔ abroad paths.

Run on both servers as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DashSaman/paqet-tunnel/main/install-optimized.sh)
```

The recommended profile is generated explicitly:

```yaml
mode: "manual"
nodelay: 0
interval: 10
resend: 0
nocongestion: 1
wdelay: true
acknodelay: false
mtu: 1420
rcvwnd: 4096
sndwnd: 4096
block: "aes-128"
smuxbuf: 8388608
streambuf: 4194304
smuxkalive: 5
smuxktimeout: 20
```

The optimized installer also:

- starts with `conn: 1` for minimum session/pcap overhead and lets you raise it when needed;
- uses a 16 MiB pcap receive buffer on the abroad/server side and 8 MiB on the entry/client side;
- installs idempotent NOTRACK/RST protection rules through a persistent systemd oneshot service;
- creates one systemd service per client tunnel;
- can back up and convert existing `/opt/paqet/config*.yaml` files to the low-overhead profile;
- keeps the encryption enabled with `aes-128`.

> `efficient` mode in the DashSaman Paqet fork is the source-level equivalent of this profile. The installer deliberately writes the explicit `manual` values so it remains compatible with an upstream binary as well.

## How it works

Clients connect to **Server A** (the Iran entry point), which tunnels traffic over an encrypted paqet/KCP link to **Server B** (abroad), where your V2Ray/X-UI runs.

```text
Client ──▶ Server A (Iran) ══ paqet tunnel ══▶ Server B (abroad) ──▶ V2Ray
```

## Optimized setup

**1. Server B (abroad)**

Choose `1) Setup foreign/server (Server B)`, select the Paqet listen port and copy the generated key.

**2. Server A (Iran)**

Choose `2) Setup entry/client tunnel (Server A)`, enter Server B's IP/port/key, choose a tunnel name and the forwarded application ports.

For an existing installation choose:

```text
3) Optimize existing Paqet config(s)
```

The script creates timestamped backups before changing existing configuration files.

## Original full-menu installer

The original forked v2.0.0 wizard is still available unchanged:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DashSaman/paqet-tunnel/main/install.sh)
```

It includes connection strings, health checks, edit/manage menus and the original KCP presets.

## Important notes

- Start with `conn: 1`. More connections can help aggregate multi-flow throughput on some multi-core servers, but they also create extra KCP/SMUX and packet-I/O state.
- The low-overhead profile is intended for healthy/high-throughput paths. On a strongly lossy or throttled route, compare it against `fast3` before deciding which profile is better.
- Paqet's KCP settings must match where protocol behavior requires it; always test both ends as a pair.
- Do not disable encryption just to chase CPU savings. The optimized installer keeps `aes-128` enabled.
- If MTU 1420 is not clean on a particular path, retry with a lower value such as 1400 or 1350 and compare actual goodput/drop rate.

## V2Ray / X-UI target

On Server B, make sure the target service accepts the address Paqet forwards to. The default generated forward target is `127.0.0.1:PORT`, so your application must accept localhost connections on that port.

## Commands

```bash
# Server B
systemctl status paqet
journalctl -u paqet -f

# Server A
systemctl status paqet-<name>
journalctl -u paqet-<name> -f

# Firewall helper
systemctl status paqet-firewall

# Show generated low-overhead values
grep -H -E 'mode:|nodelay:|interval:|resend:|mtu:|rcvwnd:|sndwnd:|smux' /opt/paqet/config*.yaml
```

## Troubleshooting

- If the service does not start, run `journalctl -u paqet -n 100 --no-pager` or the corresponding `paqet-<name>` unit.
- If the tunnel is alive but throughput is poor, compare direct route latency/loss first; identical KCP settings can behave very differently on different datacenter paths.
- If the latest upstream binary cannot be downloaded, download the Paqet release manually and place it at `/opt/paqet/paqet` with executable permission.
- For an existing installation, keep the `.bak.TIMESTAMP` config created by the optimizer until the new profile has been load-tested.

## Requirements

Linux, root access, `curl`, `libpcap`, `iproute2`, `iptables`, and systemd. The installer handles the common package dependencies automatically.

## Credits & License

Built on [paqet](https://github.com/hanselime/paqet) by hanselime. The Paqet source and this installer are distributed under their respective MIT license terms; original copyright/license notices are retained.
