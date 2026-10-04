#!/bin/bash
#
# AltStore / SideStore 源（altstore.json）生成器
#
# 设计：源 JSON 随每个正式 release 附带，无独立托管状态——
#   - 模板（静态字段）内嵌本脚本，改文案改这里；
#   - 旧版本列表从「上一正式版」的同名资产自链读取（releases API 过滤
#     prerelease/draft，天然跳过历史上的 pre-release）；
#   - gh release upload --clobber 覆盖上传，重跑幂等不产生重复条目。
# 用户加源地址（永久稳定；latest 不含 pre-release，故依赖正式版发布）：
#   https://github.com/xy2026yi/1PanelClient/releases/latest/download/altstore.json
#
# 用法：
#   CI（release.yml 末步）：TAG / IPA_PATH / GH_TOKEN / GITHUB_REPOSITORY 由环境提供
#   本地试跑（不上传）：
#     ALTSTORE_DRY_RUN=1 TAG=v0.2.0 IPA_PATH=/path/to/xx.ipa \
#       GITHUB_REPOSITORY=xy2026yi/1PanelClient bash update-altstore-source.sh
#
set -euo pipefail

die() { echo "::error::altstore: $*" >&2; exit 1; }

# releases API 统一走这里：CI 里有 GH_TOKEN 时用 gh api 认证调用——
# runner 出口 IP 对 api.github.com 匿名调用限流很凶，一旦命中，
# body 拉空只是说明缺失，取上一正式版的调用被打断则会断掉自链；
# 本地无 token 时回落匿名 curl
api_get() {
  local path="$1"
  if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
    gh api "$path"
  else
    curl -sSL "https://api.github.com/$path"
  fi
}

TAG="${TAG:-}"
IPA_PATH="${IPA_PATH:-}"
REPO="${GITHUB_REPOSITORY:-xy2026yi/1PanelClient}"
DRY_RUN="${ALTSTORE_DRY_RUN:-0}"

[[ -n "$TAG" ]] || die "需要 TAG=vX.Y.Z"
[[ -n "$IPA_PATH" ]] || die "需要 IPA_PATH"
[[ -f "$IPA_PATH" ]] || die "IPA 不存在: $IPA_PATH"

# 守卫：版本号必须纯数字；0.0.0 是 workflow_dispatch 试跑的占位版本，绝不入源
VER="${TAG#v}"
[[ "$VER" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "tag $TAG 不是 v+纯数字 版本号"
[[ "$VER" == "0.0.0" ]] && die "拒绝占位版本 0.0.0（试跑产物不得入源）"

# ---------- 从 IPA 提取元数据（单一事实来源） ----------
INFO_JSON="$(unzip -p "$IPA_PATH" 'Payload/*.app/Info.plist' | plutil -convert json -o - -)"
PLIST_VER="$(jq -r '.CFBundleShortVersionString // ""' <<<"$INFO_JSON")"
# 交叉校验：tag 与 IPA 实际版本号不一致，说明 MARKETING_VERSION 覆盖没生效，
# 错版入源会让 AltStore 用户更新到旧版本号，直接失败让人看见
[[ "$PLIST_VER" == "$VER" ]] || die "tag 版本 $VER 与 IPA 内版本 $PLIST_VER 不一致"
BUILD_VERSION="$(jq -r '.CFBundleVersion // "1"' <<<"$INFO_JSON")"
MIN_OS="$(jq -r '.MinimumOSVersion // "16.0"' <<<"$INFO_JSON")"
SIZE="$(stat -f%z "$IPA_PATH")"  # BSD 语法；本脚本只跑 macOS runner 与本机
DATE="$(date -u +%F)"

# 下载直链：与 release.yml 组包步骤共享 IPA_REF（tag 路径下与 tag 同名）
IPA_REF="${IPA_REF:-$TAG}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/1PanelClient-${IPA_REF}.ipa"

# ---------- release body（自动 notes 在 attach 之后才存在，故本脚本后置运行） ----------
BODY="$(api_get "repos/${REPO}/releases/tags/${TAG}" | jq -r '.body // ""' 2>/dev/null || true)"

# ---------- 定位上一正式版，拉取旧 versions（无则空状态） ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PREV_TAG="$(api_get "repos/${REPO}/releases?per_page=20" \
  | jq -r --arg tag "$TAG" \
      '[.[] | select((.prerelease // false) | not) | select((.draft // false) | not)
        | select(.tag_name != $tag) | .tag_name] | .[0] // empty' 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]] \
   && curl -fsSL "https://github.com/${REPO}/releases/download/${PREV_TAG}/altstore.json" \
        -o "$WORK/prev.json"; then
  echo "上一正式版: ${PREV_TAG}，合并其版本列表"
else
  echo "无可用旧源（首个正式版或上一版未附带），从模板起头"
  echo '{"apps":[{"versions":[]}]}' > "$WORK/prev.json"
fi

# ---------- 模板（静态字段） ----------
TEMPLATE="$(cat <<'EOF'
{
  "name": "1PanelClient",
  "subtitle": "1Panel 的 iOS 客户端 · iOS client for 1Panel",
  "description": "1Panel（开源 Linux 服务器运维管理面板）的非官方原生 iOS 客户端，Swift + SwiftUI 构建，通过 1Panel v2 OpenAPI 远程管理服务器：多服务器/多节点、应用商店、网站与 SSL 证书、数据库、Docker 容器与终端、计划任务、防火墙/WAF、监控告警等 19 个管理模块。\n\nAn unofficial native iOS client (Swift + SwiftUI) for 1Panel, the open-source Linux server management panel, talking to the 1Panel v2 OpenAPI.\n\n发布的 IPA 未签名，安装时由你的 Apple ID 重新签名（AltStore / SideStore / Sideloadly）。侧载版不含桌面小组件，其余功能一致。",
  "iconURL": "https://raw.githubusercontent.com/xy2026yi/1PanelClient/main/docs/icon.png",
  "website": "https://github.com/xy2026yi/1PanelClient",
  "tintColor": "#21447C",
  "featuredApps": ["com.xy.panelclient"],
  "apps": [
    {
      "name": "1PanelClient",
      "bundleIdentifier": "com.xy.panelclient",
      "developerName": "xy2026yi",
      "subtitle": "1Panel 的 iOS 客户端 · iOS client for 1Panel",
      "localizedDescription": "1Panel 的非官方原生 iOS 客户端：多服务器管理、应用商店、网站与 SSL 证书、数据库、Docker 容器与终端、计划任务、防火墙/WAF、监控告警。\n\nAn unofficial native iOS client for 1Panel — multi-server management, app store, websites & SSL certs, databases, Docker containers & terminal, cronjobs, firewall/WAF, monitoring & alerts.\n\nIPA 未签名，由你的 Apple ID 在安装时重签（AltStore / SideStore / Sideloadly）；侧载版不含桌面小组件。",
      "iconURL": "https://raw.githubusercontent.com/xy2026yi/1PanelClient/main/docs/icon.png",
      "tintColor": "#21447C",
      "category": "developer",
      "versions": [],
      "appPermissions": {
        "entitlements": [],
        "privacy": {}
      }
    }
  ]
}
EOF
)"

OUT_PATH="${OUT_PATH:-$(dirname "$IPA_PATH")/altstore.json}"

jq -n \
  --argjson tmpl "$TEMPLATE" \
  --slurpfile prev "$WORK/prev.json" \
  --arg version "$VER" \
  --arg build "$BUILD_VERSION" \
  --arg date "$DATE" \
  --arg body "$BODY" \
  --arg url "$DOWNLOAD_URL" \
  --argjson size "$SIZE" \
  --arg minos "$MIN_OS" '
  def newver: {
    version: $version, buildVersion: $build, marketingVersion: $version,
    date: $date, localizedDescription: $body, downloadURL: $url,
    size: $size, minOSVersion: $minos
  };
  $tmpl
  | ($prev[0].apps[0].versions // []) as $old
  | .apps[0].versions = ([newver] + ($old | map(select(.version != $version))))[0:3]
' > "$OUT_PATH"

jq empty "$OUT_PATH" || die "生成的 JSON 不合法"
echo "已生成 ${OUT_PATH}（保留最近 3 版）"

# ---------- 上传（--clobber 覆盖，重跑幂等） ----------
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[dry-run] 跳过上传；内容如下："
  cat "$OUT_PATH"
  exit 0
fi
[[ -n "${GH_TOKEN:-}" ]] || die "上传需要 GH_TOKEN"
gh release upload "$TAG" "$OUT_PATH" --clobber --repo "$REPO"
echo "已上传 altstore.json 到 release $TAG"
