#!/bin/bash
# AppCenter 灰度的自动放量和回滚，只改 manifest，不传包。
#
#   rollout-appcenter.sh <channel> promote          灰度开始（rolloutStartedAt）满 PROMOTE_AFTER_HOURS（默认 24）→ 去掉灰度门，全量
#   rollout-appcenter.sh <channel> rollback <App>   <App> 恢复成 previousApps 里的上一版，并且全量（已经拿到新版的设备退回去）
#
# 没有 rolloutStartedAt 的灰度（手动设的）不会被自动放量。
set -euo pipefail
CHANNEL="${1:?用法: $0 <channel> promote|rollback <App>}"
ACTION="${2:?用法: $0 <channel> promote|rollback <App>}"
APP="${3:-}"
[[ "$CHANNEL" =~ ^[a-z0-9-]+$ ]] || { echo "channel 只能是小写字母数字和 -"; exit 1; }
BUCKET="${BUCKET:-aaden-backend}"
REGION="${AWS_REGION:-eu-central-1}"
PUBLIC="https://$BUCKET.s3.$REGION.amazonaws.com/appcenter"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

curl -fsSL --max-time 30 "$PUBLIC/$CHANNEL/manifest.json?nocache=$(date +%s)" -o "$WORK/old.json"

python3 - "$WORK/old.json" "$WORK/new.json" "$ACTION" "$APP" <<'PY'
import json, os, sys, datetime
src, dst, action, app = sys.argv[1:5]
m = json.load(open(src))
now = datetime.datetime.now(datetime.timezone.utc)

if action == 'promote':
    started = m.get('rolloutStartedAt')
    if 'rollout' not in m:
        print('已经是全量，不用放量'); sys.exit(0)
    if not started:
        print('灰度没有 rolloutStartedAt（手动设的），不自动放量'); sys.exit(0)
    hours = (now - datetime.datetime.fromisoformat(started)).total_seconds() / 3600
    need = float(os.environ.get('PROMOTE_AFTER_HOURS', '24'))
    if hours < need:
        print('灰度才 %.1f 小时（< %g），先不放量' % (hours, need)); sys.exit(0)
    m.pop('rollout'); m.pop('rolloutStartedAt')
    print('灰度已满 %.1f 小时 → 全量' % hours)
elif action == 'rollback':
    prev = m.get('previousApps', {}).get(app)
    if not prev:
        sys.exit('previousApps 里没有 %s 的上一版，不能回滚' % app)
    cur = m.get('apps', {}).get(app, {})
    print('%s 回滚：%s → %s' % (app, cur.get('treeSha256', '?')[:12], prev['treeSha256'][:12]))
    m['apps'][app] = prev
    m['previousApps'].pop(app)
    m.pop('rollout', None); m.pop('rolloutStartedAt', None)
else:
    sys.exit('未知操作 %s' % action)

m['generatedAt'] = now.isoformat(timespec='seconds')
json.dump(m, open(dst, 'w'), indent=2, ensure_ascii=False)
PY

[ -f "$WORK/new.json" ] || exit 0
# 引用的 blob 必须都在
for KEY in $(python3 -c 'import json,sys; [print("appcenter/"+a["zip"]) for a in json.load(open(sys.argv[1]))["apps"].values()]' "$WORK/new.json"); do
  aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1 || { echo "manifest 引用的 $KEY 不在 S3 上，中止"; exit 1; }
done
aws s3 cp "$WORK/new.json" "s3://$BUCKET/appcenter/$CHANNEL/manifest.json" --acl public-read \
  --content-type application/json --cache-control "no-cache" --only-show-errors
echo "已更新 $PUBLIC/$CHANNEL/manifest.json"
cat "$WORK/new.json"
