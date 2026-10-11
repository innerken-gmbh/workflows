#!/bin/bash
# 产出 appcenter-sync 通道用的前端产物（设备端：aaden-cli AadenDeploy/appCenterSync.sh）。
#
#   <out>/blobs/<App>-<treeSha前12位>.zip   内容寻址，上传后不再改
#   <out>/manifest.json                     {"apps":{"<App>":{"treeSha256","zip","zipSha256","size"}}}
#
# 发布 = 先传 blobs/，再覆盖 <channel>/manifest.json。设备只认 manifest 里的 treeSha256：
# 跟本机 .appcenter-manifest 一致且文件校验通过就什么都不做，所以同一个包不会重复下发。
# 灰度 / 回滚都只是换 manifest，blob 不用重传。
#
# code.zip 那条通道只管 PHP/；AppCenter 以前只能跟着 465MB 的 latest.zip 走，这里把它拆出来。
#
# 用法: scripts/build-appcenter-artifact.sh [-o 输出目录] App [App...]
#   APPCENTER_SRC 可指向别的目录（例如直接用前端仓库刚 build 出来的 dist 的上一级），默认仓库里的 AppCenter/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="./dist-appcenter"
if [ "${1:-}" = "-o" ]; then OUT="$2"; shift 2; fi
[ $# -ge 1 ] || { echo "用法: $0 [-o 输出目录] App [App...]"; exit 1; }
SRC="${APPCENTER_SRC:-$ROOT/AppCenter}"
PY="$ROOT/scripts/appcenter_artifact.py"

rm -rf "$OUT" && mkdir -p "$OUT/blobs" "$OUT/stage"
OUT="$(cd "$OUT" && pwd)"
ENTRIES=""
for APP in "$@"; do
  [ -f "$SRC/$APP/index.html" ] || { echo "$SRC/$APP/index.html 不存在"; exit 1; }
  echo "== $APP"
  rsync -a --exclude '.git' --exclude '.DS_Store' "$SRC/$APP/" "$OUT/stage/$APP/"
  python3 "$PY" prune "$OUT/stage/$APP"
  TREE=$(python3 "$PY" manifest "$OUT/stage/$APP")
  ZIP="blobs/$APP-${TREE:0:12}.zip"
  # -X 不带 uid/gid 等扩展属性；设备上解压后统一 chown www-data
  (cd "$OUT/stage/$APP" && zip -qrX "$OUT/$ZIP" .)
  ZSHA=$(shasum -a 256 "$OUT/$ZIP" | cut -d' ' -f1)
  SIZE=$(wc -c < "$OUT/$ZIP" | tr -d ' ')
  echo "   treeSha256=$TREE  $ZIP  $(du -h "$OUT/$ZIP" | cut -f1)"
  ENTRIES="$ENTRIES${ENTRIES:+,}\"$APP\":{\"treeSha256\":\"$TREE\",\"zip\":\"$ZIP\",\"zipSha256\":\"$ZSHA\",\"size\":$SIZE}"
done
rm -rf "$OUT/stage"

COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
printf '{"generatedAt":"%s","source":"aaden-php-backend@%s","apps":{%s}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$COMMIT" "$ENTRIES" \
  | python3 -m json.tool > "$OUT/manifest.json"
echo "manifest -> $OUT/manifest.json"
