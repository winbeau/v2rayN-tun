#!/bin/bash
#
# 一次性准备：给 quit-guard 用的本地代码签名证书
#
# 为什么需要它:
#   quit-guard 靠 CGEventTap 拦截 Cmd+Q, 这需要【辅助功能】权限。
#   而 macOS 的 TCC 授权是这样校验的:
#     · adhoc 签名  -> designated requirement 是 cdhash H"..."  <- 每次重编译都变!
#     · 证书签名    -> designated requirement 是 certificate root = H"..."  <- 稳定
#
#   adhoc 签名下, 每次重新编译都等于换了一个程序, 用户必须重新到
#   「系统设置 → 隐私与安全性 → 辅助功能」里添加一次。本项目实测被这个坑了
#   好几轮, 累计出一堆对不上的 TCC 记录, 最后演变成"授权框反复弹出、点了还有"。
#
#   用固定证书签名后, 重编译不再影响授权。
#
# 用法:  ./scripts/setup-signing-cert.sh
#
# 幂等: 证书已存在时会跳过创建, 只补做信任与导入检查。
#
set -u

SIGN_ID="v2rayN-tun Local Signing"
WORK="${TMPDIR:-/tmp}/qg-signing-cert"
P12_PASS="qg-local-2026"

echo "=== 本地代码签名证书准备 ==="
echo "  证书名: $SIGN_ID"
echo

# ---------- 0. 已存在就跳过 ----------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "✓ 证书已存在且有效, 无需重建"
    security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_ID" | sed 's/^/    /'
    exit 0
fi

# 已导入但未信任的情况: 只要补信任即可
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "  证书已在钥匙串但未受信任, 补做信任设置"
    CERT_FOUND=$(security find-certificate -c "$SIGN_ID" -p 2>/dev/null)
    if [ -n "$CERT_FOUND" ]; then
        mkdir -p "$WORK"
        echo "$CERT_FOUND" > "$WORK/cert.pem"
        security add-trusted-cert -r trustRoot -p codeSign \
            -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" 2>&1 | sed 's/^/    /'
        if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
            echo "✓ 信任完成"
            exit 0
        fi
    fi
fi

# ---------- 1. 生成自签名证书 ----------
echo "--- 1. 生成自签名代码签名证书 ---"
mkdir -p "$WORK" && cd "$WORK" || exit 1
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem \
    -subj "/CN=$SIGN_ID/O=v2rayN-tun/OU=Local/C=CN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
[ -f cert.pem ] || { echo "✗ 证书生成失败"; exit 1; }
echo "  ✓ 已生成"
openssl x509 -in cert.pem -noout -subject -enddate 2>/dev/null | sed 's/^/    /'

# ---------- 2. 打包 p12 ----------
echo
echo "--- 2. 打包为 p12 ---"
# ⚠️ -legacy 必须加。OpenSSL 3/4 的新默认算法 macOS 的 security 不认,
#    会报 "MAC verification failed during PKCS12 import (wrong password?)" ——
#    而密码其实是对的, 极容易误判成密码问题。
rm -f id.p12
openssl pkcs12 -export -legacy -out id.p12 -inkey key.pem -in cert.pem \
    -passout pass:"$P12_PASS" -name "$SIGN_ID" 2>/dev/null \
  || openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem \
    -passout pass:"$P12_PASS" -name "$SIGN_ID" 2>/dev/null
[ -f id.p12 ] || { echo "✗ p12 打包失败"; exit 1; }
echo "  ✓ id.p12 ($(stat -f%z id.p12 2>/dev/null || echo '?') 字节)"

# ---------- 3. 导入登录钥匙串 ----------
echo
echo "--- 3. 导入登录钥匙串 ---"
# ⚠️ 空密码 macOS 不接受, 必须用非空密码。
#    -T 把 codesign 加进访问白名单, 否则签名时会弹钥匙串授权框。
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security 2>&1 | sed 's/^/    /'

# ---------- 4. 设为受信任 ----------
echo
echo "--- 4. 设置信任 ---"
# ⚠️ 必须用【用户级】域(不加 -d)。
#    用系统域(`-d -k /Library/Keychains/System.keychain`)会报:
#      SecTrustSettingsSetTrustSettings: The authorization was denied since
#      no user interaction was possible.
#    即使用 sudo/osascript 提权也过不去, 因为 trustd 要求交互式授权。
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" cert.pem 2>&1 | sed 's/^/    /'

# ---------- 5. 验证 ----------
echo
echo "--- 5. 验证 ---"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "✓ 证书可用:"
    security find-identity -v -p codesigning 2>/dev/null | grep "$SIGN_ID" | sed 's/^/    /'
    echo
    echo "  之后运行 install.sh 会自动用它签名, designated requirement 将是:"
    echo "    identifier \"com.local.v2rayn.quitguard\" and certificate root = H\"...\""
    echo "  —— 绑证书而非 cdhash, 重新编译不会让辅助功能授权失效。"
else
    echo "✗ 证书仍不可用, 请检查上方输出"
    exit 1
fi
