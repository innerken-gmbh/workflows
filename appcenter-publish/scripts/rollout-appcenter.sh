#!/bin/bash
# AppCenter 灰度的自动放量和回滚，只改 manifest，不传包。
#
#   rollout-appcenter.sh <channel> promote          按应用：apps.<App>.rolloutStartedAt 满 PROMOTE_AFTER_HOURS（默认 24）→ 该应用全量
#   rollout-appcenter.sh <channel> rollback <App>   <App> 恢复成 previousApps 里的上一版，并且全量（已经拿到新版的设备退回去）
#   rollout-appcenter.sh <channel> widen <App> <kind> <devices> <percent> [start|none]
#                                                   <App> 的灰度改成 devices（逗号分隔，可以为空）+ deviceId%100<percent，
#                                                   start（默认）= 从现在开始计时，满 PROMOTE_AFTER_HOURS 由 promote 自动全量；
#                                                   none = 不计时（去掉开始时间），不会自动全量，要人再 widen / promote
#   rollout-appcenter.sh <channel> add-devices <App> <kind> <devices>
#                                                   只把 devices（最多 3 台）加进 <App> 现有的灰度名单：不改百分比、不改开始时间、
#                                                   不碰别的应用。已经全量的应用什么都不做（本来就都能拿到）
#
# 没有开始时间的灰度（手动设的）不会被自动放量。manifest 没有 perAppRollout 时按老规则（顶层 rolloutStartedAt）。
# 按应用灰度时顶层 rollout 一律去掉（POS-157）：新 CLI 用它决定 ensureNoCache，留着会把 index.html no-cache 卡在 10%。
# promote 遇到还带着顶层 rollout 的按应用 manifest，也会顺手把它去掉。
set -euo pipefail
USAGE="用法: $0 <channel> promote | rollback <App> [kind] | widen <App> <kind> <devices> <percent> [start|none] | add-devices <App> <kind> <devices>"
CHANNEL="${1:?$USAGE}"
ACTION="${2:?$USAGE}"
APP="${3:-}"
KIND="${4:-apps}"   # rollback / widen 时：apps（AppCenter/<App>）或 rootApps（docroot 根 /<App>）
export WIDEN_DEVICES="${5:-}" WIDEN_PERCENT="${6:-}" WIDEN_TIMER="${7:-start}"
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
    if e.get('rollout') is None:
        sys.exit('%s 已经是全量（没有 rollout），widen 不会把它收窄回灰度；要重新灰度就重新发布' % app)
    import re
    raw_devices = os.environ.get('WIDEN_DEVICES', '').strip()
    raw_percent = os.environ.get('WIDEN_PERCENT', '').strip() or '0'
    if raw_devices and not re.fullmatch(r'[0-9]+(,[0-9]+)*', raw_devices):
        sys.exit('devices 只能是逗号分隔的设备号：%s' % raw_devices)
    if not re.fullmatch(r'[0-9]+', raw_percent):
        sys.exit('percent 只能是 0–100 的整数：%s' % raw_percent)
    devices = [int(x) for x in raw_devices.split(',')] if raw_devices else []
    percent = int(raw_percent)
    if not 0 <= percent <= 100:
        sys.exit('percent 要在 0–100 之间')
    if not devices and percent == 0:
        sys.exit('devices 和 percent 不能都为空（要全量用 promote，或者 percent 填 100）')
    timer = os.environ.get('WIDEN_TIMER', 'start')
    if timer not in ('start', 'none'):
        sys.exit('计时只能是 start 或 none：%s' % timer)
    label = app if kind == 'apps' else '/' + app
    entry = dict(e, rollout={'devices': devices, 'percent': percent})
    if timer == 'start':
        entry['rolloutStartedAt'] = now.isoformat(timespec='seconds')
        print('%s 灰度：%s → devices %s + percent %d，从现在开始计时' % (label, json.dumps(e.get('rollout')), devices, percent))
    else:
        entry.pop('rolloutStartedAt', None)
        print('%s 灰度：%s → devices %s + percent %d，不计时（不会自动全量）' % (label, json.dumps(e.get('rollout')), devices, percent))
    m[kind][app] = entry
    changed = True
elif action == 'add-devices':
    import re
    if kind not in ('apps', 'rootApps'):
        sys.exit('kind 只能是 apps 或 rootApps')
    if m.get('perAppRollout') is not True:
        sys.exit('manifest 不是按应用灰度（perAppRollout），add-devices 只支持按应用')
    e = (m.get(kind) or {}).get(app)
    if not e:
        sys.exit('%s 里没有 %s' % (kind, app))
    raw = os.environ.get('WIDEN_DEVICES', '').strip()
    if not re.fullmatch(r'[0-9]+(,[0-9]+){0,2}', raw):
        sys.exit('devices 要 1–3 个逗号分隔的设备号：%s' % raw)
    add = list(dict.fromkeys(int(x) for x in raw.split(',')))  # 去重
    if 0 in add:
        sys.exit('设备号不能是 0')
    label = app if kind == 'apps' else '/' + app
    r = e.get('rollout')
    if r is None:
        print('%s 已经是全量，所有设备本来就能拿到，不用加名单' % label)
    else:
        have = [int(x) for x in r.get('devices', [])]
        new = [d for d in add if d not in have]
        if not new:
            print('%s 的灰度名单里已经有 %s，不用加' % (label, add))
        else:
            # 只加名单：percent 和 rolloutStartedAt 原样保留（不推迟、也不提前自动全量）
            m[kind][app] = dict(e, rollout=dict(r, devices=have + new))
            changed = True
            print('%s 灰度名单加上 %s（percent %s、开始时间不变）' % (label, new, r.get('percent', 0)))
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
