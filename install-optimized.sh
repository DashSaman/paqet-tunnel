#!/usr/bin/env bash
# PVN low-overhead Paqet installer
# Compatible with upstream hanselime/paqet by using an explicit manual KCP profile.
# This keeps wire overhead conservative without requiring a custom Paqet binary.

set -Eeuo pipefail

VERSION="2.1.0-pvn1"
PAQET_REPO="${PAQET_REPO:-hanselime/paqet}"
PAQET_DIR="${PAQET_DIR:-/opt/paqet}"
PAQET_BIN="$PAQET_DIR/paqet"
FIREWALL_SCRIPT="/usr/local/sbin/paqet-firewall"
FIREWALL_SERVICE="paqet-firewall.service"

# Low-overhead profile. These values intentionally avoid aggressive fast-resend
# and immediate ACKs on healthy links while keeping large windows for BDP.
KCP_MTUN="${KCP_MTU:-1420}"
KCP_NODELAY="0"
KCP_INTERVAL="10"
KCP_RESEND="0"
KCP_NOCONGESTION="1"
KCP_WDELAY="true"
KCP_ACKNODELAY="false"
KCP_RCVWND="4096"
KCP_SNDWND="4096"
KCP_BLOCK="aes-128"
KCP_SMUXBUF="8388608"
KCP_STREAMBUF="4194304"
KCP_SMUXKALIVE="5"
KCP_SMUXKTIMEOUT="20"

C_RESET='\033[0m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[36m'

ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
die()  { echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; exit 1; }
info() { echo -e "${C_CYAN}[i]${C_RESET} $*"; }

banner() {
  echo
  echo "============================================================"
  echo " PVN Paqet Low-Overhead Installer $VERSION"
  echo " KCP: manual / nodelay=0 / interval=10 / resend=0"
  echo "============================================================"
  echo
}

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

read_default() {
  local prompt="$1" default="$2" out
  read -r -p "$prompt [$default]: " out </dev/tty
  printf '%s' "${out:-$default}"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= $1 && $1 <= 65535))
}

valid_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip" || return 1
  [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || return 1
  for x in "$a" "$b" "$c" "$d"; do
    [[ "$x" =~ ^[0-9]+$ ]] || return 1
    ((10#$x <= 255)) || return 1
  done
}

install_dependencies() {
  command -v curl >/dev/null 2>&1 && command -v ip >/dev/null 2>&1 && \
    command -v iptables >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q libpcap && return 0

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates libpcap-dev iproute2 iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl libpcap-devel iproute iptables
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl libpcap-devel iproute iptables
  else
    die "Unsupported package manager. Install curl, libpcap, iproute2 and iptables manually."
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7*) echo arm32 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

download_paqet() {
  if [[ -x "$PAQET_BIN" ]]; then
    ok "Paqet binary already installed: $PAQET_BIN"
    return 0
  fi

  mkdir -p "$PAQET_DIR"
  local arch tag archive url tmp
  arch="$(detect_arch)"
  tag="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${PAQET_REPO}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$tag" ]] || die "Could not resolve latest Paqet release from $PAQET_REPO"

  archive="paqet-linux-${arch}-${tag}.tar.gz"
  url="https://github.com/${PAQET_REPO}/releases/download/${tag}/${archive}"
  tmp="$(mktemp /tmp/paqet.XXXXXX.tar.gz)"
  trap 'rm -f "${tmp:-}"' RETURN

  info "Downloading $tag ($arch)..."
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$tmp"
  tar -xzf "$tmp" -C "$PAQET_DIR"

  local extracted="$PAQET_DIR/paqet_linux_${arch}"
  [[ -f "$extracted" ]] || die "Expected binary not found after extraction: $extracted"
  mv -f "$extracted" "$PAQET_BIN"
  chmod 0755 "$PAQET_BIN"
  rm -rf "$PAQET_DIR/example" "$PAQET_DIR/README.md" 2>/dev/null || true
  ok "Installed Paqet $tag"
}

default_iface() {
  ip -4 route show default | awk '/default/ {print $5; exit}'
}

iface_ipv4() {
  ip -4 -o addr show dev "$1" scope global | awk '{split($4,a,"/"); print a[1]; exit}'
}

gateway_ipv4() {
  ip -4 route show default | awk '/default/ {print $3; exit}'
}

gateway_mac() {
  local gw mac
  gw="$(gateway_ipv4)"
  [[ -n "$gw" ]] || return 0
  ping -c 1 -W 1 "$gw" >/dev/null 2>&1 || true
  mac="$(ip neigh show "$gw" 2>/dev/null | awk '/lladdr/ {print $5; exit}')"
  printf '%s' "$mac"
}

get_network() {
  NET_IFACE="$(default_iface)"
  NET_IP="$(iface_ipv4 "$NET_IFACE")"
  NET_GW_MAC="$(gateway_mac)"

  [[ -n "$NET_IFACE" ]] || die "Could not detect default interface."
  [[ -n "$NET_IP" ]] || die "Could not detect IPv4 on $NET_IFACE."

  if [[ -z "$NET_GW_MAC" ]]; then
    warn "Gateway MAC was not detected automatically."
    read -r -p "Gateway MAC: " NET_GW_MAC </dev/tty
  fi
  [[ "$NET_GW_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || die "Invalid gateway MAC."

  info "Interface=$NET_IFACE IPv4=$NET_IP GatewayMAC=$NET_GW_MAC"
}

gen_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

write_firewall_helper() {
  cat >"$FIREWALL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
add() {
  local table="$1"; shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

for cfg in /opt/paqet/config.yaml /opt/paqet/config-*.yaml; do
  [[ -f "$cfg" ]] || continue
  role=$(awk -F'"' '/^role:/ {print $2; exit}' "$cfg")
  if [[ "$role" == "server" ]]; then
    port=$(awk -F'[:"]+' '/^[[:space:]]*addr:[[:space:]]*":/ {print $(NF-1); exit}' "$cfg")
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    add raw PREROUTING -p tcp --dport "$port" -j NOTRACK
    add raw OUTPUT -p tcp --sport "$port" -j NOTRACK
    add mangle OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP
  elif [[ "$role" == "client" ]]; then
    addr=$(awk -F'"' '/^[[:space:]]*addr:[[:space:]]*"[0-9].*:[0-9]+"/ {v=$2} /^server:/ {in_server=1; next} in_server && /^[[:space:]]*addr:/ {print $2; exit}' "$cfg")
    [[ -n "$addr" ]] || addr=$(awk -F'"' 'f && /^[[:space:]]*addr:/ {print $2; exit} /^server:/ {f=1}' "$cfg")
    ip=${addr%:*}; port=${addr##*:}
    [[ -n "$ip" && "$port" =~ ^[0-9]+$ ]] || continue
    add raw OUTPUT -p tcp -d "$ip" --dport "$port" -j NOTRACK
    add raw PREROUTING -p tcp -s "$ip" --sport "$port" -j NOTRACK
    add mangle OUTPUT -p tcp -d "$ip" --dport "$port" --tcp-flags RST RST -j DROP
  fi
done
EOF
  chmod 0755 "$FIREWALL_SCRIPT"

  cat >/etc/systemd/system/$FIREWALL_SERVICE <<EOF
[Unit]
Description=Paqet raw-socket firewall preparation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$FIREWALL_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$FIREWALL_SERVICE" >/dev/null 2>&1 || true
}

apply_firewall() {
  write_firewall_helper
  systemctl restart "$FIREWALL_SERVICE"
  ok "Raw-socket firewall rules applied idempotently"
}

kcp_block() {
  cat <<EOF
    mode: "manual"
    nodelay: $KCP_NODELAY
    interval: $KCP_INTERVAL
    resend: $KCP_RESEND
    nocongestion: $KCP_NOCONGESTION
    wdelay: $KCP_WDELAY
    acknodelay: $KCP_ACKNODELAY
    mtu: $KCP_MTUN
    rcvwnd: $KCP_RCVWND
    sndwnd: $KCP_SNDWND
    block: "$KCP_BLOCK"
    key: "$1"
    smuxbuf: $KCP_SMUXBUF
    streambuf: $KCP_STREAMBUF
    smuxkalive: $KCP_SMUXKALIVE
    smuxktimeout: $KCP_SMUXKTIMEOUT
EOF
}

write_service() {
  local name="$1" cfg="$2"
  cat >"/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=Paqet tunnel ($name)
After=network-online.target $FIREWALL_SERVICE
Wants=network-online.target
Requires=$FIREWALL_SERVICE
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$PAQET_BIN run -c $cfg
Restart=always
RestartSec=2
LimitNOFILE=1048576
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$name" >/dev/null
  systemctl restart "$name"
  sleep 1
  systemctl is-active --quiet "$name" || {
    systemctl status "$name" --no-pager -l || true
    die "Service $name failed to start."
  }
  ok "$name is running"
}

setup_server() {
  get_network
  local port key conn cfg
  port="$(read_default "Paqet listen port" "8088")"
  valid_port "$port" || die "Invalid port."
  conn="$(read_default "KCP connections (server field; normally 1)" "1")"
  [[ "$conn" =~ ^[0-9]+$ ]] && ((conn >= 1 && conn <= 256)) || die "Invalid conn."
  key="$(gen_key)"
  key="$(read_default "Secret key" "$key")"
  cfg="$PAQET_DIR/config.yaml"

  mkdir -p "$PAQET_DIR"
  cat >"$cfg" <<EOF
# PVN low-overhead Paqet server config v1
role: "server"
log:
  level: "error"
listen:
  addr: ":$port"
network:
  interface: "$NET_IFACE"
  ipv4:
    addr: "$NET_IP:$port"
    router_mac: "$NET_GW_MAC"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
  pcap:
    sockbuf: 16777216
transport:
  protocol: "kcp"
  conn: $conn
  kcp:
$(kcp_block "$key")
EOF

  apply_firewall
  write_service "paqet" "$cfg"
  echo
  ok "Server ready"
  echo "Server IP: $NET_IP"
  echo "Paqet port: $port"
  echo "Key: $key"
  echo "Profile: low-overhead manual (1420 / wnd4096 / resend0)"
}

setup_client() {
  get_network
  local name rip rport key ports conn cfg svc forward=""
  name="$(read_default "Tunnel name" "foreign")"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid tunnel name."

  read -r -p "Remote Paqet server IPv4: " rip </dev/tty
  valid_ipv4 "$rip" || die "Invalid IPv4."
  rport="$(read_default "Remote Paqet port" "8088")"
  valid_port "$rport" || die "Invalid port."
  read -r -p "Secret key: " key </dev/tty
  [[ -n "$key" ]] || die "Key is required."
  ports="$(read_default "Local forward ports (comma separated)" "5090")"
  conn="$(read_default "KCP connections" "1")"
  [[ "$conn" =~ ^[0-9]+$ ]] && ((conn >= 1 && conn <= 256)) || die "Invalid conn."

  IFS=',' read -ra parr <<<"$ports"
  for p in "${parr[@]}"; do
    p="${p//[[:space:]]/}"
    valid_port "$p" || die "Invalid forward port: $p"
    forward+=$'\n'"  - listen: \"0.0.0.0:$p\""$'\n'"    target: \"127.0.0.1:$p\""$'\n'"    protocol: \"tcp\""
  done

  cfg="$PAQET_DIR/config-${name}.yaml"
  svc="paqet-${name}"
  mkdir -p "$PAQET_DIR"
  cat >"$cfg" <<EOF
# PVN low-overhead Paqet client config v1
role: "client"
log:
  level: "error"
forward:$forward
network:
  interface: "$NET_IFACE"
  ipv4:
    addr: "$NET_IP:0"
    router_mac: "$NET_GW_MAC"
  tcp:
    local_flag: ["PA"]
    remote_flag: ["PA"]
  pcap:
    sockbuf: 8388608
server:
  addr: "$rip:$rport"
transport:
  protocol: "kcp"
  conn: $conn
  kcp:
$(kcp_block "$key")
EOF

  apply_firewall
  write_service "$svc" "$cfg"
  echo
  ok "Client tunnel '$name' ready"
  echo "Remote: $rip:$rport"
  echo "Forward ports: $ports"
  echo "Profile: low-overhead manual (1420 / wnd4096 / resend0)"
}

optimize_existing() {
  local found=0 cfg
  for cfg in "$PAQET_DIR"/config.yaml "$PAQET_DIR"/config-*.yaml; do
    [[ -f "$cfg" ]] || continue
    found=1
    cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"

    python3 - "$cfg" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
start = re.search(r'(?m)^  kcp:\s*$', s)
if not start:
    raise SystemExit(f"no transport.kcp block in {p}")
pos = start.end()
endm = re.search(r'(?m)^\S', s[pos:])
end = pos + endm.start() if endm else len(s)
block = s[start.start():end]
keym = re.search(r'(?m)^\s+key:\s*["\']?([^"\'\n]+)', block)
if not keym:
    raise SystemExit(f"no KCP key in {p}")
key = keym.group(1).strip()
new = f'''  kcp:\n    mode: "manual"\n    nodelay: 0\n    interval: 10\n    resend: 0\n    nocongestion: 1\n    wdelay: true\n    acknodelay: false\n    mtu: 1420\n    rcvwnd: 4096\n    sndwnd: 4096\n    block: "aes-128"\n    key: "{key}"\n    smuxbuf: 8388608\n    streambuf: 4194304\n    smuxkalive: 5\n    smuxktimeout: 20\n'''
open(p, 'w', encoding='utf-8').write(s[:start.start()] + new + s[end:])
PY
    ok "Optimized $cfg"
  done
  ((found == 1)) || die "No Paqet configs found in $PAQET_DIR"
  apply_firewall

  while read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl restart "$unit" || true
  done < <(systemctl list-unit-files 'paqet*.service' --no-legend 2>/dev/null | awk '$1 !~ /auto-reset/ {print $1}')
  ok "Existing configs optimized and Paqet services restarted"
}

status_all() {
  echo "--- services ---"
  systemctl --no-pager --full status 'paqet*.service' 2>/dev/null || true
  echo
  echo "--- firewall ---"
  iptables -t raw -S 2>/dev/null | grep -E 'NOTRACK.*tcp' || true
  iptables -t mangle -S 2>/dev/null | grep -E 'RST.*DROP' || true
  echo
  echo "--- configs ---"
  grep -H -E '^(role:|  conn:|    mode:|    interval:|    resend:|    mtu:|    rcvwnd:|    sndwnd:|    smuxkalive:|    smuxktimeout:)' "$PAQET_DIR"/config*.yaml 2>/dev/null || true
}

main() {
  need_root
  banner
  install_dependencies
  download_paqet

  while true; do
    echo "1) Setup foreign/server (Server B)"
    echo "2) Setup entry/client tunnel (Server A)"
    echo "3) Optimize existing Paqet config(s)"
    echo "4) Status"
    echo "0) Exit"
    read -r -p "Choice: " choice </dev/tty
    case "$choice" in
      1) setup_server; break ;;
      2) setup_client; break ;;
      3) optimize_existing; break ;;
      4) status_all ;;
      0) exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

main "$@"
