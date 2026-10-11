#!/usr/bin/env bash
# Emit a v2rayN-importable Hysteria2 share link.
#
# Usage:
#   make_hy2_link.sh <server_ip> <port> <auth> <sni> [salamander_password] [remark]
#
# The URI scheme is:
#   hysteria2://<auth>@<host>:<port>/?<params>#<remark>
#
# Parameters emitted:
#   sni            TLS SNI, must match the certificate's domain
#   insecure=0     explicit: do NOT skip certificate validation.
#                  Modern Xray REFUSES to load nodes with insecure=1 when no
#                  certificate pin is supplied, so this must stay 0.
#   obfs / obfs-password   only when salamander obfuscation is enabled
#
# Deliberately NOT emitted:
#   pinSHA256      unnecessary when the certificate is from a public CA
#   mport          port hopping; adds failure modes, enable only if needed

set -euo pipefail

if [ $# -lt 4 ]; then
  echo "usage: $0 <server_ip> <port> <auth> <sni> [salamander_password] [remark]" >&2
  exit 1
fi

ip=$1; port=$2; auth=$3; sni=$4
salamander=${5:-}
remark=${6:-hy2-$sni}

# Percent-encode. LC_ALL=C makes bash index by byte, so multi-byte UTF-8
# remarks encode as UTF-8 octets rather than as code points.
urlencode() {
  local LC_ALL=C
  local s=$1 i c out=''
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9.~_-]) out+=$c ;;
      # `printf '%d' "'$c"` yields a SIGNED byte in LC_ALL=C, so bytes >= 0x80
      # come back negative and `%02X` sign-extends them into garbage such as
      # %FFFFFFFFFFFFFFE7. Mask with 0xFF before formatting.
      *) out+=$(printf '%%%02X' "$(( $(printf '%d' "'$c") & 0xFF ))") ;;
    esac
  done
  printf '%s' "$out"
}

params="sni=$(urlencode "$sni")&insecure=0"
if [ -n "$salamander" ]; then
  params+="&obfs=salamander&obfs-password=$(urlencode "$salamander")"
fi

printf 'hysteria2://%s@%s:%s/?%s#%s\n' \
  "$(urlencode "$auth")" "$ip" "$port" "$params" "$(urlencode "$remark")"
