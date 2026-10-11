#!/usr/bin/env bash
# Probe REALITY dest candidates for TLS 1.3 + X25519 + h2 support and latency.
# Usage: probe_dest.sh [domain ...]
# With no arguments a built-in candidate list is used.

set -uo pipefail

DEFAULT_CANDIDATES=(
  addons.mozilla.org
  www.microsoft.com
  dl.google.com
  www.samsung.com
  www.lovelive-anime.jp
  www.bing.com
  www.yahoo.com
  www.cloudflare.com
)

# Domains Xray warns about: borrowing them has been observed to attract
# targeted blocking of the server IP.
RISKY_RE='(^|\.)(apple\.com|icloud\.com|itunes\.com|mzstatic\.com|akadns\.net)$'

CANDIDATES=("$@")
if [ ${#CANDIDATES[@]} -eq 0 ]; then
  CANDIDATES=("${DEFAULT_CANDIDATES[@]}")
fi

for tool in openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

rows=""
for d in "${CANDIDATES[@]}"; do
  handshake=$(echo | timeout 10 openssl s_client -connect "$d:443" \
    -servername "$d" -tls1_3 -alpn h2 2>/dev/null)

  if [ -z "$handshake" ]; then
    rows+="$d 999.999 no no no unreachable\n"
    continue
  fi

  tls13=no
  grep -q "TLSv1.3" <<<"$handshake" && tls13=yes

  x25519=no
  grep -qi "Server Temp Key: *X25519" <<<"$handshake" && x25519=yes

  h2=no
  grep -qi "^ALPN protocol: h2$" <<<"$handshake" && h2=yes

  lat=$(curl -s -o /dev/null --max-time 10 -w '%{time_total}' "https://$d/" 2>/dev/null)
  [ -z "$lat" ] && lat=999.999

  flag=ok
  if [[ "$d" =~ $RISKY_RE ]]; then
    flag=RISKY
  elif [ "$tls13" = no ] || [ "$x25519" = no ] || [ "$h2" = no ]; then
    flag=unusable
  fi

  rows+="$d $lat $tls13 $x25519 $h2 $flag\n"
done

{
  printf 'DOMAIN LATENCY TLS1.3 X25519 H2 VERDICT\n'
  printf "%b" "$rows" | sort -k2 -g
} | column -t

cat <<'NOTE'

Pick the lowest-latency row whose VERDICT is ok.
RISKY   = borrowing this dest may get the server IP blocked; do not use.
unusable = missing TLS 1.3, X25519 key exchange, or HTTP/2 ALPN.

Confirm the final choice with `xray run -test -c config.json`; its warnings
are authoritative and override this table.
NOTE
