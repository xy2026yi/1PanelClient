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

# 临时产物：成功/失败（set -e 任一步退出）都经 trap 清理；mktemp 唯一目录支持并行两份实例
PROFILE_PLIST="$(mktemp /tmp/profile.XXXXXX.plist)"
ENT_PLIST="$(mktemp /tmp/ent.XXXXXX.plist)"
WORK_DIR="$(mktemp -d /tmp/sign_work.XXXXXX)"
UNSIGNED_IPA="$(mktemp /tmp/unsigned.XXXXXX.ipa)"
trap 'rm -f "$PROFILE_PLIST" "$ENT_PLIST" "$UNSIGNED_IPA"; rm -rf "$WORK_DIR"' EXIT

info()  { printf "\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()    { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
err()   { printf "\033[1;31m✗ %s\033[0m\n" "$1"; exit 1; }

command -v zsign >/dev/null || err "未找到 zsign，先安装：brew install zsign"
command -v python3 >/dev/null || err "未找到 python3（解析描述文件需要）"
[ -x "$BUILD_IPA" ] || err "未找到构建脚本 $BUILD_IPA"
[ -f "$P12" ] || err "未找到证书 $P12"
[ -f "$PROFILE" ] || err "未找到描述文件 $PROFILE"

# ---------- 1) 从描述文件提取：App ID（决定目标 bundle id）与 entitlements ----------
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
# 描述文件内容不受信：App ID 白名单校验后才允许拼进 PlistBuddy 命令
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || err "提取到的 App ID 含异常字符：$BUNDLE_ID"
info "描述文件 App ID → $BUNDLE_ID"

# ---------- 2) 生成未签名包并解包 ----------
info "生成未签名 ipa..."
"$BUILD_IPA" "$UNSIGNED_IPA" >/dev/null
cd "$WORK_DIR"
unzip -q "$UNSIGNED_IPA"
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
# 注：p12 密码只能经 zsign 的 -p 参数传递（其接口不支持 stdin/环境变量），
# 签名期间会短暂出现在进程列表中——属 zsign 接口限制，避免在共享机器上运行
zsign -c "$P12" -p "$P12_PWD" -m "$PROFILE" -e "$ENT_PLIST" "$APP"
ok "签名完成（bundle id: $BUNDLE_ID）"

# ---------- 5) 打包 ----------
rm -f "$OUTPUT_IPA"
zip -qr "$OUTPUT_IPA" Payload

SIZE=$(du -h "$OUTPUT_IPA" | cut -f1)
ok "输出: $OUTPUT_IPA（$SIZE）"
echo ""
echo "安装：xcrun devicectl device install app --device <设备UDID> $OUTPUT_IPA"
echo "     或用爱思助手 / Apple Configurator 2 安装（首次需在 设置 → 通用 → VPN与设备管理 信任）"
