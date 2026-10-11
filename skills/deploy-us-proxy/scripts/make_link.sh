#!/usr/bin/env bash
# Emit a v2rayN-importable VLESS + Vision + REALITY share link.
# Usage: make_link.sh <server_ip> <port> <uuid> <dest_sni> <public_key> <short_id> <remark>

set -euo pipefail

if [ $# -ne 7 ]; then
  echo "usage: $0 <server_ip> <port> <uuid> <dest_sni> <public_key> <short_id> <remark>" >&2
  exit 1
fi

ip=$1; port=$2; uuid=$3; sni=$4; pbk=$5; sid=$6; remark=$7

# Percent-encode the remark; everything else in the link is already URL-safe
# (UUID is hex, pbk is base64url, sid is hex, sni is a hostname).
urlencode() {
  # LC_ALL=C makes bash index the string by byte, so multi-byte UTF-8 remarks
  # encode as UTF-8 octets rather than as code points.
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

printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
  "$uuid" "$ip" "$port" "$sni" "$pbk" "$sid" "$(urlencode "$remark")"
