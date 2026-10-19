#!/bin/bash
# AppCenter 灰度的自动放量和回滚，只改 manifest，不传包。
#
#   rollout-appcenter.sh <channel> promote          按应用：apps.<App>.rolloutStartedAt 满 PROMOTE_AFTER_HOURS（默认 24）→ 该应用全量
#   rollout-appcenter.sh <channel> rollback <App>   <App> 恢复成 previousApps 里的上一版，并且全量（已经拿到新版的设备退回去）
#   rollout-appcenter.sh <channel> widen <App> <kind> <devices> <percent>
#                                                   <App> 的灰度改成 devices（逗号分隔，可以为空）+ deviceId%100<percent，
#                                                   并从现在开始计时：满 PROMOTE_AFTER_HOURS 由 promote 自动全量
#
# 没有开始时间的灰度（手动设的）不会被自动放量。manifest 没有 perAppRollout 时按老规则（顶层 rolloutStartedAt）。
# 按应用灰度时顶层 rollout 一律去掉（POS-157）：新 CLI 用它决定 ensureNoCache，留着会把 index.html no-cache 卡在 10%。
# promote 遇到还带着顶层 rollout 的按应用 manifest，也会顺手把它去掉。
set -euo pipefail
USAGE="用法: $0 <channel> promote | rollback <App> [kind] | widen <App> <kind> <devices> <percent>"
CHANNEL="${1:?$USAGE}"
ACTION="${2:?$USAGE}"
APP="${3:-}"
KIND="${4:-apps}"   # rollback / widen 时：apps（AppCenter/<App>）或 rootApps（docroot 根 /<App>）
export WIDEN_DEVICES="${5:-}" WIDEN_PERCENT="${6:-}"
[[ "$CHANNEL" =~ ^[a-z0-9-]+$ ]] || { echo "channel 只能是小写字母数字和 -"; exit 1; }
BUCKET="${BUCKET:-aaden-backend}"
REGION="${AWS_REGION:-eu-central-1}"
PUBLIC="https://$BUCKET.s3.$REGION.amazonaws.com/appcenter"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck source=manifest-s3.sh
. "$(dirname "$0")/manifest-s3.sh"

decide(){
rm -f "$WORK/new.json"
python3 - "$WORK/old.json" "$WORK/new.json" "$ACTION" "$APP" "$KIND" <<'PY'
import json, os, sys, datetime
src, dst, action, app, kind = sys.argv[1:6]
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
        if 'rollout' in m:
            print('去掉顶层 rollout %s（按应用灰度不再用它，POS-157）' % json.dumps(m['rollout']))
            changed = True
        for k in ('apps', 'rootApps'):
            for name, e in (m.get(k) or {}).items():
                label = name if k == 'apps' else '/' + name
                if e.get('rollout') is None:
                    continue
                ok, hours = due(e.get('rolloutStartedAt'))
                if hours is None:
                    print('%s 灰度没有开始时间（手动设的），不自动放量' % label)
                elif not ok:
                    print('%s 灰度才 %.1f 小时，先不放量' % (label, hours))
                else:
                    m[k][name] = strip(e); changed = True
                    print('%s 灰度已满 %.1f 小时 → 全量' % (label, hours))
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
    if kind not in ('apps', 'rootApps'):
        sys.exit('kind 只能是 apps 或 rootApps')
    pk = 'previousApps' if kind == 'apps' else 'previousRootApps'
    prev = m.get(pk, {}).get(app)
    if not prev:
        sys.exit('%s 里没有 %s 的上一版，不能回滚' % (pk, app))
    cur = m.get(kind, {}).get(app, {})
    print('%s%s 回滚：%s → %s' % ('' if kind == 'apps' else '/', app, cur.get('treeSha256', '?')[:12], prev['treeSha256'][:12]))
    m[kind][app] = strip(prev)
    m[pk].pop(app)
    if m.get('perAppRollout') is not True:
        m.pop('rollout', None); m.pop('rolloutStartedAt', None)
    changed = True
elif action == 'widen':
    if kind not in ('apps', 'rootApps'):
        sys.exit('kind 只能是 apps 或 rootApps')
    if m.get('perAppRollout') is not True:
        sys.exit('manifest 不是按应用灰度（perAppRollout），widen 只支持按应用')
    e = (m.get(kind) or {}).get(app)
    if not e:
        sys.exit('%s 里没有 %s' % (kind, app))
    try:
        devices = [int(x) for x in os.environ.get('WIDEN_DEVICES', '').split(',') if x.strip()]
        percent = int(os.environ.get('WIDEN_PERCENT') or '0')
    except ValueError:
        sys.exit('devices 要逗号分隔的设备号，percent 要整数')
    if not 0 <= percent <= 100:
        sys.exit('percent 要在 0–100 之间')
    if not devices and percent == 0:
        sys.exit('devices 和 percent 不能都为空（要全量用 promote，或者 percent 填 100）')
    label = app if kind == 'apps' else '/' + app
    print('%s 灰度：%s → devices %s + percent %d，从现在开始计时' % (label, json.dumps(e.get('rollout')), devices, percent))
    m[kind][app] = dict(e, rollout={'devices': devices, 'percent': percent}, rolloutStartedAt=now.isoformat(timespec='seconds'))
    changed = True
else:
    sys.exit('未知操作 %s' % action)

if not changed:
    sys.exit(0)
if m.get('perAppRollout') is True:
    # 顶层 rollout 不再为老 CLI 保留（POS-157）
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
  for KEY in $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); [print("appcenter/"+a["zip"]) for k in ("apps","rootApps") for a in (m.get(k) or {}).values()]' "$WORK/new.json"); do
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
