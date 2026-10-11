#!/usr/bin/env bash
# Generate an Xray VLESS + XTLS-Vision + REALITY server config and share link.
# Runs unprivileged; installation is a separate step (install_service.sh).
#
# Usage:
#   setup_reality.sh --dest addons.mozilla.org [options]
#
# Options:
#   --dest DOMAIN      REALITY borrowed site (required; pick with probe_dest.sh)
#   --workdir DIR      build directory (default ./xray-build)
#   --port N           listen port (default 443)
#   --uuid UUID        client UUID (default random)
#   --server-ip IP     public IPv4 (default auto-detected)
#   --email NAME       first client label (default owner)
#   --remark TEXT      node name shown in the client (default xray-reality)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSETS="$SCRIPT_DIR/../assets"

DEST=""
WORKDIR="./xray-build"
PORT=443
UUID=""
SERVER_IP=""
EMAIL="owner"
REMARK="xray-reality"

while [ $# -gt 0 ]; do
  case $1 in
    --dest)      DEST=$2; shift 2 ;;
    --workdir)   WORKDIR=$2; shift 2 ;;
    --port)      PORT=$2; shift 2 ;;
    --uuid)      UUID=$2; shift 2 ;;
    --server-ip) SERVER_IP=$2; shift 2 ;;
    --email)     EMAIL=$2; shift 2 ;;
    --remark)    REMARK=$2; shift 2 ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -n "$DEST" ] || { echo "error: --dest is required (run probe_dest.sh first)" >&2; exit 1; }

mkdir -p "$WORKDIR"
WORKDIR=$(cd "$WORKDIR" && pwd)

# --- fetch the Xray binary ----------------------------------------------------
if [ ! -x "$WORKDIR/xray" ]; then
  case $(uname -m) in
    x86_64)          ZIP=Xray-linux-64.zip ;;
    aarch64|arm64)   ZIP=Xray-linux-arm64-v8a.zip ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  echo "==> downloading $ZIP"
  curl -fsSL --max-time 180 -o "$WORKDIR/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/$ZIP"
  unzip -oq "$WORKDIR/xray.zip" xray geoip.dat geosite.dat -d "$WORKDIR"
  chmod +x "$WORKDIR/xray"
fi
XRAY="$WORKDIR/xray"
"$XRAY" version | head -1

# --- resolve parameters -------------------------------------------------------
[ -n "$SERVER_IP" ] || SERVER_IP=$(curl -fsS -4 --max-time 15 https://api.ipify.org)
[ -n "$SERVER_IP" ] || { echo "error: could not detect public IPv4; pass --server-ip" >&2; exit 1; }

[ -n "$UUID" ] || UUID=$("$XRAY" uuid)

KEYS=$("$XRAY" x25519)
# Xray >= 25 prints "PrivateKey:" / "Password (PublicKey):";
# older builds print "Private key:" / "Public key:".
PRIVATE_KEY=$(grep -iE '^private' <<<"$KEYS" | head -1 | sed 's/^[^:]*: *//')
PUBLIC_KEY=$(grep -iE '^(password|public)' <<<"$KEYS" | head -1 | sed 's/^[^:]*: *//')
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || {
  echo "error: could not parse 'xray x25519' output:" >&2; echo "$KEYS" >&2; exit 1; }

SHORT_ID=$(openssl rand -hex 8)

# --- render and validate the server config ------------------------------------
sed -e "s|__PORT__|$PORT|g" \
    -e "s|__UUID__|$UUID|g" \
    -e "s|__EMAIL__|$EMAIL|g" \
    -e "s|__DEST__|$DEST|g" \
    -e "s|__PRIVATE_KEY__|$PRIVATE_KEY|g" \
    -e "s|__SHORT_ID__|$SHORT_ID|g" \
    "$ASSETS/server-config.template.json" > "$WORKDIR/config.json"
chmod 600 "$WORKDIR/config.json"

echo "==> validating config"
TEST_OUT=$("$XRAY" run -test -c "$WORKDIR/config.json" 2>&1) || {
  echo "$TEST_OUT" >&2; exit 1; }
echo "$TEST_OUT" | grep -vE '^\s*$'

if grep -qi 'warning' <<<"$TEST_OUT"; then
  echo
  echo "!! Xray emitted a warning above. Do not proceed with it unresolved:" >&2
  echo "!!   target-related  -> pick a different --dest (see probe_dest.sh)" >&2
  echo "!!   non-443 port    -> use the default --port 443" >&2
fi

# --- persist parameters and share link ----------------------------------------
umask 077
cat > "$WORKDIR/params.env" <<EOF
SERVER_IP=$SERVER_IP
PORT=$PORT
UUID=$UUID
DEST=$DEST
PUBLIC_KEY=$PUBLIC_KEY
PRIVATE_KEY=$PRIVATE_KEY
SHORT_ID=$SHORT_ID
REMARK=$REMARK
EOF

bash "$SCRIPT_DIR/make_link.sh" \
  "$SERVER_IP" "$PORT" "$UUID" "$DEST" "$PUBLIC_KEY" "$SHORT_ID" "$REMARK" \
  > "$WORKDIR/share-link.txt"

cat <<EOF

==> build complete: $WORKDIR
    config.json     server config (mode 600)
    params.env      all parameters, including the private key (mode 600)
    share-link.txt  client import link

    server   $SERVER_IP:$PORT
    dest/sni $DEST
    uuid     $UUID
    pbk      $PUBLIC_KEY
    sid      $SHORT_ID

Next: sudo bash $SCRIPT_DIR/install_service.sh --workdir $WORKDIR
EOF
