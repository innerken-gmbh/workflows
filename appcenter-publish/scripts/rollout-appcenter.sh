#!/bin/bash
# AppCenter 灰度的自动放量和回滚，只改 manifest，不传包。
#
#   rollout-appcenter.sh <channel> promote          按应用：apps.<App>.rolloutStartedAt 满 PROMOTE_AFTER_HOURS（默认 24）→ 该应用全量
#   rollout-appcenter.sh <channel> rollback <App>   <App> 恢复成 previousApps 里的上一版，并且全量（已经拿到新版的设备退回去）
#
# 没有开始时间的灰度（手动设的）不会被自动放量。manifest 没有 perAppRollout 时按老规则（顶层 rolloutStartedAt）。
# 顶层 rollout 留给老 CLI：还有应用在灰度就保持 ik0001 + 10%，都放完了就去掉。
set -euo pipefail
CHANNEL="${1:?用法: $0 <channel> promote|rollback <App>}"
ACTION="${2:?用法: $0 <channel> promote|rollback <App>}"
APP="${3:-}"
[[ "$CHANNEL" =~ ^[a-z0-9-]+$ ]] || { echo "channel 只能是小写字母数字和 -"; exit 1; }
BUCKET="${BUCKET:-aaden-backend}"
REGION="${AWS_REGION:-eu-central-1}"
PUBLIC="https://$BUCKET.s3.$REGION.amazonaws.com/appcenter"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck source=manifest-s3.sh
. "$(dirname "$0")/manifest-s3.sh"

decide(){
rm -f "$WORK/new.json"
python3 - "$WORK/old.json" "$WORK/new.json" "$ACTION" "$APP" <<'PY'
import json, os, sys, datetime
src, dst, action, app = sys.argv[1:5]
m = json.load(open(src))
now = datetime.datetime.now(datetime.timezone.utc)

def due(started):
    if not started:
        return False, None
    hours = (now - datetime.datetime.fromisoformat(started)).total_seconds() / 3600
    return hours >= float(os.environ.get('PROMOTE_AFTER_HOURS', '24')), hours

def strip(e):
    return {k: v for k, v in e.items() if k not in ('rollout', 'rolloutStartedAt')}

changed = False
if action == 'promote':
    if m.get('perAppRollout') is True:
        for name, e in m.get('apps', {}).items():
            if e.get('rollout') is None:
                continue
            ok, hours = due(e.get('rolloutStartedAt'))
            if hours is None:
                print('%s 灰度没有开始时间（手动设的），不自动放量' % name)
            elif not ok:
                print('%s 灰度才 %.1f 小时，先不放量' % (name, hours))
            else:
                m['apps'][name] = strip(e); changed = True
                print('%s 灰度已满 %.1f 小时 → 全量' % (name, hours))
    else:
        ok, hours = due(m.get('rolloutStartedAt'))
        if 'rollout' not in m:
            print('已经是全量，不用放量')
        elif hours is None:
            print('灰度没有 rolloutStartedAt（手动设的），不自动放量')
        elif not ok:
            print('灰度才 %.1f 小时，先不放量' % hours)
        else:
            m.pop('rollout'); m.pop('rolloutStartedAt'); changed = True
            print('灰度已满 %.1f 小时 → 全量' % hours)
elif action == 'rollback':
    prev = m.get('previousApps', {}).get(app)
    if not prev:
        sys.exit('previousApps 里没有 %s 的上一版，不能回滚' % app)
    cur = m.get('apps', {}).get(app, {})
    print('%s 回滚：%s → %s' % (app, cur.get('treeSha256', '?')[:12], prev['treeSha256'][:12]))
    m['apps'][app] = strip(prev)
    m['previousApps'].pop(app)
    if m.get('perAppRollout') is not True:
        m.pop('rollout', None); m.pop('rolloutStartedAt', None)
    changed = True
else:
    sys.exit('未知操作 %s' % action)

if not changed:
    sys.exit(0)
if m.get('perAppRollout') is True:
    # 顶层 rollout 留给不认 perAppRollout 的老 CLI：还有应用在灰度就保持 ik0001 + 10%
    if any(e.get('rollout') is not None for e in m.get('apps', {}).values()):
        m['rollout'] = {'devices': [1], 'percent': 10}
    else:
        m.pop('rollout', None)
    m.pop('rolloutStartedAt', None)
m['generatedAt'] = now.isoformat(timespec='seconds')
json.dump(m, open(dst, 'w'), indent=2, ensure_ascii=False)
PY

}

# 读 → 决定 → 带 ETag 条件写回；被别的发布抢先改过就重来（最多 5 次）
for ATTEMPT in 1 2 3 4 5; do
  manifest_get "$CHANNEL" "$WORK/old.json"
  decide
  [ -f "$WORK/new.json" ] || exit 0
  # 引用的 blob 必须都在
  for KEY in $(python3 -c 'import json,sys; [print("appcenter/"+a["zip"]) for a in json.load(open(sys.argv[1]))["apps"].values()]' "$WORK/new.json"); do
    aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1 || { echo "manifest 引用的 $KEY 不在 S3 上，中止"; exit 1; }
  done
  RC=0; manifest_put "$CHANNEL" "$WORK/new.json" "$MANIFEST_ETAG" || RC=$?
  [ "$RC" = 0 ] && break
  [ "$RC" = 2 ] || exit 1
  [ "$ATTEMPT" = 5 ] && { echo "连续 5 次被抢先改写，放弃"; exit 1; }
  sleep $((RANDOM % 5 + 1))
done
echo "已更新 $PUBLIC/$CHANNEL/manifest.json"
cat "$WORK/new.json"
