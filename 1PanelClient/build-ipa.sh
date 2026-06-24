#!/bin/bash
#
# build-ipa.sh — 导出未签名 ipa（LiveContainer / 侧载专用）
#
# 用法：
#   ./build-ipa.sh              # 默认导出到 ~/Desktop/1PanelClient.ipa
#   ./build-ipa.sh ~/path.ipa   # 自定义输出路径
#
# 原理：archive 时禁用签名（CODE_SIGNING_ALLOWED=NO），从 .xcarchive 提取
#       .app 手动打包成标准 ipa 结构。绕开所有证书 / Profile / UDID 限制。
#

set -euo pipefail

# ---------- 配置 ----------
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="1PanelClient"
SCHEME="1PanelClient"
ARCHIVE_PATH="$PROJECT_DIR/build/$SCHEME.xcarchive"
OUTPUT_IPA="${1:-$HOME/Desktop/$PROJECT_NAME.ipa}"

# 颜色输出
info()  { printf "\033[1;34m▸ %s\033[0m\n" "$1"; }
ok()    { printf "\033[1;32m✓ %s\033[0m\n" "$1"; }
err()   { printf "\033[1;31m✗ %s\033[0m\n" "$1"; }

# ---------- 前置检查 ----------
if [ ! -f "$PROJECT_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj" ]; then
  err "未找到 $PROJECT_NAME.xcodeproj，请在项目根目录运行"
  exit 1
fi

# ---------- 1. 清理旧产物 ----------
info "清理旧的 build 产物..."
rm -rf "$PROJECT_DIR/build"
rm -rf /tmp/lc_payload
ok "已清理"

# ---------- 2. Archive（禁用签名）----------
info "开始 Archive（CODE_SIGNING_ALLOWED=NO）..."
xcodebuild archive \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

if [ ! -d "$ARCHIVE_PATH/Products/Applications/$SCHEME.app" ]; then
  err "Archive 产物中未找到 $SCHEME.app"
  exit 1
fi
ok "Archive 完成"

# ---------- 3. 打包 ipa ----------
info "打包 ipa..."
STAGING="/tmp/lc_payload"
mkdir -p "$STAGING/Payload"
cp -R "$ARCHIVE_PATH/Products/Applications/$SCHEME.app" "$STAGING/Payload/"

mkdir -p "$(dirname "$OUTPUT_IPA")"
( cd "$STAGING" && rm -f "$OUTPUT_IPA" && zip -rq "$OUTPUT_IPA" Payload )
ok "ipa 已生成: $OUTPUT_IPA"

# ---------- 4. 结果 ----------
SIZE=$(du -h "$OUTPUT_IPA" | cut -f1)
echo ""
echo "  ┌──────────────────────────────────────"
echo "  │ 输出: $OUTPUT_IPA"
echo "  │ 大小: $SIZE"
echo "  │ 签名: 未签名（LiveContainer 可直接加载）"
echo "  └──────────────────────────────────────"
echo ""
ok "完成。将 ipa 传到 iPhone 后用 LiveContainer 导入即可。"
