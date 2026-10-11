#!/usr/bin/env bash
# End-to-end check of a deployed REALITY node: handshake, egress, throughput.
# Starts a throwaway local client, runs the tests, then cleans up.
#
# Usage: verify_reality.sh --workdir ./xray-build [--socks-port 10808] [--size 10000000]

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSETS="$SCRIPT_DIR/../assets"

WORKDIR="./xray-build"
SOCKS_PORT=10808
SIZE=10000000

while [ $# -gt 0 ]; do
  case $1 in
    --workdir)    WORKDIR=$2; shift 2 ;;
    --socks-port) SOCKS_PORT=$2; shift 2 ;;
    --size)       SIZE=$2; shift 2 ;;
    -h|--help)    sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

WORKDIR=$(cd "$WORKDIR" && pwd)
[ -f "$WORKDIR/params.env" ] || { echo "error: missing $WORKDIR/params.env" >&2; exit 1; }
[ -x "$WORKDIR/xray" ] || { echo "error: missing $WORKDIR/xray" >&2; exit 1; }

# shellcheck disable=SC1091
. "$WORKDIR/params.env"

if ss -tln 2>/dev/null | grep -q "127.0.0.1:${SOCKS_PORT}\b"; then
  echo "error: port ${SOCKS_PORT} already in use; pass --socks-port" >&2
  exit 1
fi

CLIENT_CFG="$WORKDIR/client-test.json"
sed -e "s|__SOCKS_PORT__|$SOCKS_PORT|g" \
    -e "s|__SERVER_IP__|$SERVER_IP|g" \
    -e "s|__PORT__|$PORT|g" \
    -e "s|__UUID__|$UUID|g" \
    -e "s|__DEST__|$DEST|g" \
    -e "s|__PUBLIC_KEY__|$PUBLIC_KEY|g" \
    -e "s|__SHORT_ID__|$SHORT_ID|g" \
    "$ASSETS/client-test.template.json" > "$CLIENT_CFG"
chmod 600 "$CLIENT_CFG"

LOG="$WORKDIR/client-test.log"
XRAY_LOCATION_ASSET="$WORKDIR" "$WORKDIR/xray" run -c "$CLIENT_CFG" >"$LOG" 2>&1 &
CPID=$!
cleanup() { kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 40); do
  ss -tln 2>/dev/null | grep -q "127.0.0.1:${SOCKS_PORT}\b" && break
  sleep 0.25
done
if ! ss -tln 2>/dev/null | grep -q "127.0.0.1:${SOCKS_PORT}\b"; then
  echo "error: test client failed to start" >&2
  cat "$LOG" >&2
  exit 1
fi

PROXY=(--socks5-hostname "127.0.0.1:${SOCKS_PORT}")
SPEED_URL="https://speed.cloudflare.com/__down?bytes=${SIZE}"

echo "=== egress ==="
printf 'direct  : %s\n' "$(curl -fsS --max-time 15 https://api.ipify.org || echo FAILED)"
PROXIED_IP=$(curl -fsS --max-time 20 "${PROXY[@]}" https://api.ipify.org || echo FAILED)
printf 'proxied : %s\n' "$PROXIED_IP"

if [ "$PROXIED_IP" = FAILED ]; then
  echo
  echo "REALITY handshake or forwarding failed. Client log:" >&2
  cat "$LOG" >&2
  exit 1
fi

echo
echo "=== throughput ($((SIZE / 1000000)) MB) ==="
FMT='connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s speed=%{speed_download} B/s\n'
printf 'proxied : '
curl -s -o /dev/null --max-time 60 "${PROXY[@]}" -w "$FMT" "$SPEED_URL" || echo FAILED
printf 'direct  : '
curl -s -o /dev/null --max-time 60 -w "$FMT" "$SPEED_URL" || echo FAILED

echo
echo "=== client log ==="
cat "$LOG"

cat <<EOF

Read this correctly:
  * Run from the server itself, the proxied egress IP necessarily equals the
    server IP. That does NOT by itself prove forwarding works -- the real
    evidence is a successful handshake, throughput close to direct, and
    'accepted' entries in the server log.
  * Proxy overhead above ~5% usually means no AES-NI on this CPU
    (check: grep -o aes /proc/cpuinfo | head -1).
  * This test never leaves the host, so it does NOT verify public reachability
    of port ${PORT}. Check the VPS security group separately.
EOF
