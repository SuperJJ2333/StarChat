#!/usr/bin/env bash
# 服务器下行拉取 GitHub Release → 部署到 /opt/starchat/frontend/downloads。
#
# 背景：本地→服务器上行上传受本地出口带宽限制（且直连可能被重置）；
# 服务器数据中心下行带宽远大于本地上行。公开仓库的 Release 资产可
# 匿名下载，服务器拉取无需任何凭据。
#
# 用法（由 scripts/release_ci.ps1 触发；密钥经 SSH 免密登录）：
#   bash server_pull_release.sh <version> [选项]
# 选项：
#   --notes-file F       更新文案文件（--publish 必需）
#   --publish-script P   publish_app_update.py 路径（--publish 必需）
#   --publish            部署后调用业务 API 发布更新弹窗（人工决策）
#   --build N            versionCode 基数（pubspec +N；--publish 必需）
#   --no-keep-previous   不保留上一版回滚包（默认保留）
#
# 红线：
# - 先 sha256sum -c 校验 SHA256SUMS，再落盘部署（绝不部署未校验字节）；
# - 别名只用 ln -sfn（0.3.32 cp 穿透符号链接事故的硬规矩）；
# - publish 不默认执行（--publish 显式开启）。
set -euo pipefail

REPO="SuperJJ2333/StarChat"
DOWNLOADS="/opt/starchat/frontend/downloads"
PUBLIC_BASE="https://www.liuhetong888.com/downloads"

VERSION="${1:?usage: server_pull_release.sh <version> [--publish --notes-file F --publish-script P --build N]}"
shift || true

PUBLISH=0 NOTES_FILE="" PUBLISH_SCRIPT="" RELEASE_BUILD="" KEEP_PREVIOUS=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --notes-file) NOTES_FILE="${2:?--notes-file 需要参数}"; shift ;;
    --publish-script) PUBLISH_SCRIPT="${2:?--publish-script 需要参数}"; shift ;;
    --build) RELEASE_BUILD="${2:?--build 需要参数}"; shift ;;
    --no-keep-previous) KEEP_PREVIOUS=0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

BASE="https://github.com/${REPO}/releases/download/v${VERSION}"
TMP="$(mktemp -d /tmp/starchat-release.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "== 下行拉取 v${VERSION}（GitHub Release → 服务器）=="
for abi in arm64 arm32 x86_64; do
  curl -fL --retry 5 --retry-delay 15 --connect-timeout 30 \
    -o "$TMP/ChatFlow-${VERSION}-${abi}.apk" \
    "${BASE}/ChatFlow-${VERSION}-${abi}.apk"
done
curl -fL --retry 5 --retry-delay 15 --connect-timeout 30 \
  -o "$TMP/SHA256SUMS" "${BASE}/SHA256SUMS"

echo "== SHA256SUMS 校验（部署前强制）=="
(cd "$TMP" && sha256sum -c SHA256SUMS)

echo "== 部署到 ${DOWNLOADS} =="
for abi in arm64 arm32 x86_64; do
  install -m 0644 "$TMP/ChatFlow-${VERSION}-${abi}.apk" "$DOWNLOADS/"
done

if [ "$KEEP_PREVIOUS" -eq 1 ]; then
  # 保留最新一版旧包作回滚，清理更旧版本（与 release.ps1 策略一致）
  ls "$DOWNLOADS" | grep -oP 'ChatFlow-\K[0-9.]+' | sort -uV | head -n -1 \
    | while read -r old; do
        [ "$old" = "$VERSION" ] && continue
        rm -f "$DOWNLOADS/ChatFlow-${old}-"*.apk
        echo "cleaned: ${old}"
      done
fi

for abi in arm64 arm32 x86_64; do
  ln -sfn "ChatFlow-${VERSION}-${abi}.apk" "$DOWNLOADS/latest-${abi}.apk"
done
ls -l "$DOWNLOADS/latest-"*.apk | awk '{print $9, "->", $11}'
echo "PULL_DEPLOY_OK v${VERSION}"

if [ "$PUBLISH" -eq 1 ]; then
  : "${NOTES_FILE:?--publish 需要 --notes-file}"
  : "${PUBLISH_SCRIPT:?--publish 需要 --publish-script}"
  : "${RELEASE_BUILD:?--publish 需要 --build（pubspec +N）}"
  echo "== 发布更新弹窗（幂等键防重复）=="
  # 文案先进容器（python 以容器内路径读取），再执行发布脚本
  docker cp "$NOTES_FILE" "starchat-business-api-1:/tmp/notes-${VERSION}.txt" >/dev/null
  docker exec -i \
    -e RELEASE_VERSION="$VERSION" \
    -e RELEASE_BUILD="$RELEASE_BUILD" \
    -e APK_URL="${PUBLIC_BASE}/ChatFlow-${VERSION}-arm64.apk" \
    -e NOTES_FILE="/tmp/notes-${VERSION}.txt" \
    starchat-business-api-1 python - < "$PUBLISH_SCRIPT"
fi
