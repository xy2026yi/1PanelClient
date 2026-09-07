#!/bin/bash
#
# sign-adhoc.sh — 用市售 Ad-Hoc 描述文件给未签名 ipa 签名（Scarlet 类证书适配）
#
# 前提：证书的 App ID 为固定专属值（如 app.scarlet3615.kumquat5811），只覆盖主 App、
#       不覆盖小组件扩展 —— 本脚本自动：①移除 PlugIns（小组件）②改写主 App bundle id
#       ③entitlements 直接取描述文件自身的 Entitlements（合法上限）④zsign 签名⑤重打包。
#       由此小组件在此分发渠道不可用（数据通道组名亦不匹配）；全功能请用 Xcode 直装。
#
# 用法：
#   ./sign-adhoc.sh <cert.p12> <p12密码> [描述文件.mobileprovision] [输出.ipa]
#   描述文件默认取 ../../logs/描述文件.mobileprovision；输出默认 ~/Desktop/1PanelClient-adhoc.ipa

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_IPA="$PROJECT_DIR/build-ipa.sh"
P12="${1:?用法: ./sign-adhoc.sh <cert.p12> <p12密码> [描述文件] [输出.ipa]}"
P12_PWD="${2:?缺少 p12 密码}"
PROFILE="${3:-$PROJECT_DIR/../logs/描述文件.mobileprovision}"
OUTPUT_IPA="${4:-$HOME/Desktop/1PanelClient-adhoc.ipa}"

info()  { printf "\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()    { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
err()   { printf "\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

command -v zsign >/dev/null || err "未找到 zsign，先安装：brew install zsign"
[ -f "$P12" ] || err "未找到证书 $P12"
[ -f "$PROFILE" ] || err "未找到描述文件 $PROFILE"

# ---------- 1) 从描述文件提取：App ID（决定目标 bundle id）与 entitlements ----------
PROFILE_PLIST="$(mktemp /tmp/profile.XXXXXX.plist)"
ENT_PLIST="$(mktemp /tmp/ent.XXXXXX.plist)"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
# 值经环境变量传入 python（描述文件内容不受信，不拼进源码）
BUNDLE_ID=$(PROFILE_PLIST="$PROFILE_PLIST" python3 -c "
import os, plistlib
d = plistlib.load(open(os.environ['PROFILE_PLIST'],'rb'))
appid = d['Entitlements'].get('application-identifier','')
print(appid.split('.',1)[1] if '.' in appid else '')
")
PROFILE_PLIST="$PROFILE_PLIST" ENT_PLIST="$ENT_PLIST" python3 -c "
import os, plistlib
d = plistlib.load(open(os.environ['PROFILE_PLIST'],'rb'))
plistlib.dump(d['Entitlements'], open(os.environ['ENT_PLIST'],'wb'))
"
[ -n "$BUNDLE_ID" ] || err "描述文件里没有 application-identifier"
info "描述文件 App ID → $BUNDLE_ID"

# ---------- 2) 生成未签名包并解包 ----------
info "生成未签名 ipa..."
"$BUILD_IPA" /tmp/unsigned.ipa >/dev/null
rm -rf /tmp/sign_work && mkdir -p /tmp/sign_work && cd /tmp/sign_work
unzip -q /tmp/unsigned.ipa
APP=Payload/1PanelClient.app
[ -d "$APP" ] || err "解包产物中未找到 .app"

# ---------- 3) 移除小组件扩展（profile 只覆盖主 App bundle id） ----------
if [ -d "$APP/PlugIns" ]; then
    rm -rf "$APP/PlugIns"
    info "已移除小组件扩展（本渠道不含小组件，全功能用 Xcode 直装）"
fi

# ---------- 4) 改写 bundle id + 内嵌 profile + 签名 ----------
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
cp "$PROFILE" "$APP/embedded.mobileprovision"
info "zsign 签名中..."
zsign -c "$P12" -p "$P12_PWD" -m "$PROFILE" -e "$ENT_PLIST" "$APP"
ok "签名完成（bundle id: $BUNDLE_ID）"

# ---------- 5) 打包 ----------
rm -f "$OUTPUT_IPA"
zip -qr "$OUTPUT_IPA" Payload
rm -f "$PROFILE_PLIST" "$ENT_PLIST"

SIZE=$(du -h "$OUTPUT_IPA" | cut -f1)
ok "输出: $OUTPUT_IPA（$SIZE）"
echo ""
echo "安装：xcrun devicectl device install app --device <设备UDID> $OUTPUT_IPA"
echo "     或用爱思助手 / Apple Configurator 2 安装（首次需在 设置 → 通用 → VPN与设备管理 信任）"
