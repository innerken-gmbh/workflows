#!/bin/bash
# 发布 AppCenter 前端到 S3，设备每天由 aaden-cli appcenter-sync（AadenDeploy/appCenterSync.sh）拉取。
#
#   s3://<bucket>/appcenter/blobs/<App>-<treeSha12>-<zipSha12>.zip    按 zip 字节寻址，已存在就不重传（同名必同字节）
#   s3://<bucket>/appcenter/<channel>/manifest.json   唯一会变的文件：先传 blob 再覆盖它
#
# 用法:
#   scripts/publish-appcenter-artifact.sh <channel> [App...]       构建并发布（默认 Admin），其余应用条目保留
#   ROLLOUT_ONLY=1 scripts/publish-appcenter-artifact.sh <channel>  只改灰度 / ensureNoCache，不构建
#
# 灰度（不传就沿用 manifest 里现有的；channel 第一次发布时默认只给 deviceId 1 = ik0001）：
#   ROLLOUT_DEVICES=1,23,108   名单内的设备
#   ROLLOUT_PERCENT=10         外加 deviceId % 100 < 10 的设备（约 10%）
#   ROLLOUT=all                去掉灰度门，全量
#   ENSURE_NOCACHE=1|0         设备是否确保 AppCenter 的 index.html 带 no-cache（第一次发布默认 1）
#
# 护栏：同一应用换了内容、而上次发布不满 MIN_DAYS 天（默认 14）→ 拒绝，FORCE=1 跳过。
#   原因：设备 Apache 以前不给 index.html 发 Cache-Control，浏览器按文件年龄 10% 启发式缓存，可能缓存一两周；
#   设备只保留上一代文件，这段时间内连发两版，缓存着更老 index.html 的页面会去请求已删掉的 chunk → 白屏。
#   全网 ensureNoCache 生效满两周后可以把 MIN_DAYS 调成 0。
#
# 自动灰度（AUTO_ROLLOUT=1，CI 发布用）：按应用灰度。换了内容的应用写 apps.<App>.rollout = ik0001 + deviceId%100<10
#   和 apps.<App>.rolloutStartedAt，满 24 小时由 rollout-appcenter.sh promote 自动全量；被替换的旧条目存进 previousApps，
#   回滚时恢复。manifest 标 perAppRollout=true（aaden-cli >= 支持 perAppRollout 的版本按应用判断）；
#   顶层 rollout：按应用灰度时不再设（POS-157）。新 CLI 用顶层 rollout 决定 ensureNoCache，以前「还有应用在灰度就保持
#   ik0001 + 10%」把 index.html no-cache 卡在了 10%；不认 perAppRollout 的老 CLI（< 1.6.119，10-15 只剩 8 台）因此不再灰度。
#   第一次切到按应用时，没有自己 rollout 的应用继承当时的顶层 rollout（没有开始时间 = 不自动放量）。
#   APP_ROLLOUT_DEVICES=9020[,…]：换了内容的应用只放这些设备（percent 0、不写开始时间 = 不自动放量），
#   之后用 rollout-appcenter.sh widen 扩大并开始计 24 小时。
#
# 需要能写 BUCKET 的 AWS 凭据（本地 aws 配置，或 GitHub Actions 的 publish-appcenter-artifact 工作流）。
set -euo pipefail
CHANNEL="${1:?用法: $0 <channel> [App...]}"; shift
[[ "$CHANNEL" =~ ^[a-z0-9-]+$ ]] || { echo "channel 只能是小写字母数字和 -"; exit 1; }
APPS=("$@"); [ ${#APPS[@]} -gt 0 ] || APPS=(Admin)
BUCKET="${BUCKET:-aaden-backend}"
REGION="${AWS_REGION:-eu-central-1}"
PUBLIC="https://$BUCKET.s3.$REGION.amazonaws.com/appcenter"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# shellcheck source=manifest-s3.sh
. "$ROOT/scripts/manifest-s3.sh"

if [ "${ROLLOUT_ONLY:-0}" = "1" ]; then
  mkdir -p "$WORK/out" && echo '{"apps":{}}' > "$WORK/out/manifest.json"
else
  "$ROOT/scripts/build-appcenter-artifact.sh" -o "$WORK/out" "${APPS[@]}"
fi

merge(){
# 合并：新构建的应用覆盖旧条目，其余应用原样保留；灰度 / ensureNoCache 按环境变量改，否则沿用
python3 - "$WORK/old.json" "$WORK/out/manifest.json" "$WORK/final.json" <<'PY'
import json, os, sys, datetime
old = json.load(open(sys.argv[1]))
built = json.load(open(sys.argv[2]))
now = datetime.datetime.now(datetime.timezone.utc)
first = not old
min_days = float(os.environ.get('MIN_DAYS', '14'))
force = os.environ.get('FORCE') == '1'

# APPCENTER_KIND=rootApps：发布到 docroot 根（如老的 /App），条目放 rootApps，上一版放 previousRootApps
kind = os.environ.get('APPCENTER_KIND', 'apps')
if kind not in ('apps', 'rootApps'):
    sys.exit('APPCENTER_KIND 只能是 apps 或 rootApps')
prev_key = 'previousApps' if kind == 'apps' else 'previousRootApps'
apps = dict(old.get(kind, {}))
previous = dict(old.get(prev_key, {}))
changed = []
for name, entry in built.get('apps', {}).items():
    prev = apps.get(name)
    if prev and prev.get('treeSha256') == entry['treeSha256']:
        print('  %s 内容没变（%s），保留原条目' % (name, entry['treeSha256'][:12]))
        continue
    if prev and not force and prev.get('publishedAt'):
        age = (now - datetime.datetime.fromisoformat(prev['publishedAt'])).total_seconds() / 86400
        if age < min_days:
            sys.exit('  拒绝：%s 上次发布才 %.1f 天（< MIN_DAYS=%g），见脚本头注释；确认要发用 FORCE=1' % (name, age, min_days))
    entry['publishedAt'] = now.isoformat(timespec='seconds')
    # 把 version.json 里的版本和提交也写进条目：不用下载 zip 就能知道清单里发的是哪一版（小登按版本对照用）
    vj = os.path.join(os.environ.get('APPCENTER_SRC', ''), name, 'version.json')
    try:
        with open(vj, encoding='utf-8') as f:
            v = json.load(f)
        for k in ('version', 'commit', 'ref'):
            if v.get(k):
                entry[k] = v[k]
    except (OSError, ValueError):
        pass
    if prev:
        previous[name] = prev
    apps[name] = entry
    changed.append(name)
    print('  %s -> %s' % (name, entry['treeSha256'][:12]))

rollout = old.get('rollout', {'devices': [1], 'percent': 0} if first else None)
started = old.get('rolloutStartedAt')
per_app = old.get('perAppRollout') is True or os.environ.get('AUTO_ROLLOUT') == '1'
if per_app:
    if old.get('perAppRollout') is not True and old.get('rollout') is not None:
        # 切换到按应用：原来整体灰度着的应用继承顶层 rollout，不带开始时间（不自动放量）
        for name, entry in apps.items():
            if name not in changed and 'rollout' not in entry:
                apps[name] = dict(entry, rollout=old['rollout'])
    only = os.environ.get('APP_ROLLOUT_DEVICES', '').strip()
    if only:
        import re
        if not re.fullmatch(r'[0-9]+(,[0-9]+)*', only):
            sys.exit('APP_ROLLOUT_DEVICES 只能是逗号分隔的设备号：%s' % only)
        only_devices = [int(x) for x in only.split(',')]
    for name in changed:
        if only:
            # 只放名单里的设备，不写开始时间：不会被 promote 自动放量，要用 widen 扩大
            entry = {k: v for k, v in apps[name].items() if k != 'rolloutStartedAt'}
            apps[name] = dict(entry, rollout={'devices': only_devices, 'percent': 0})
        else:
            apps[name] = dict(apps[name], rollout={'devices': [1], 'percent': 10},
                              rolloutStartedAt=now.isoformat(timespec='seconds'))
    other = old.get('rootApps' if kind == 'apps' else 'apps', {})
    # 顶层 rollout 不再为老 CLI 卡 10%（POS-157，见脚本头）；要手动设还可以用 ROLLOUT_DEVICES / ROLLOUT_PERCENT
    rollout = None
    started = None
if os.environ.get('ROLLOUT') == 'all':
    rollout = None
elif os.environ.get('ROLLOUT_DEVICES') is not None or os.environ.get('ROLLOUT_PERCENT') is not None:
    rollout = dict(rollout or {'devices': [], 'percent': 0})
    if os.environ.get('ROLLOUT_DEVICES') is not None:
        rollout['devices'] = [int(x) for x in os.environ['ROLLOUT_DEVICES'].split(',') if x.strip()]
    if os.environ.get('ROLLOUT_PERCENT') is not None:
        rollout['percent'] = int(os.environ['ROLLOUT_PERCENT'])

ensure = old.get('ensureNoCache', True)
if os.environ.get('ENSURE_NOCACHE') in ('0', '1'):
    ensure = os.environ['ENSURE_NOCACHE'] == '1'

final = dict(old)
for k in ('rollout', 'rolloutStartedAt'):
    final.pop(k, None)
final.update({'generatedAt': now.isoformat(timespec='seconds'),
         **({'perAppRollout': True} if per_app else {}),
         'source': built.get('source', old.get('source')),
         'ensureNoCache': ensure,
         kind: apps})
if rollout is not None:
    final['rollout'] = rollout
    if started:
        final['rolloutStartedAt'] = started
if previous:
    final[prev_key] = previous
json.dump(final, open(sys.argv[3], 'w'), indent=2, ensure_ascii=False)
print('  rollout: %s   ensureNoCache: %s' % (json.dumps(rollout) if rollout is not None else '全量', ensure))
PY
}

# 先传 blob（已存在就跳过：名字里带 zipSha，同名就是同一个包），再覆盖 manifest
for z in "$WORK"/out/blobs/*.zip; do
  [ -e "$z" ] || continue
  KEY="appcenter/blobs/$(basename "$z")"
  if aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
    echo "  已存在 s3://$BUCKET/$KEY"
  else
    aws s3 cp "$z" "s3://$BUCKET/$KEY" --acl public-read \
      --content-type application/zip --cache-control "public, max-age=31536000, immutable" --only-show-errors
    echo "  已上传 s3://$BUCKET/$KEY"
  fi
done
# manifest 引用的 blob 必须都在（防止只改灰度时引用了从没传过的包）
check_blobs(){
  for KEY in $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); [print("appcenter/"+a["zip"]) for k in ("apps","rootApps") for a in (m.get(k) or {}).values()]' "$WORK/final.json"); do
    aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1 || { echo "manifest 引用的 $KEY 不在 S3 上，中止"; return 1; }
  done
}

# 读 → 合并 → 带 ETag 条件写回；被别的发布抢先改过就重来（最多 5 次）
for ATTEMPT in 1 2 3 4 5; do
  manifest_get "$CHANNEL" "$WORK/old.json"
  merge
  check_blobs
  RC=0; manifest_put "$CHANNEL" "$WORK/final.json" "$MANIFEST_ETAG" || RC=$?
  [ "$RC" = 0 ] && break
  [ "$RC" = 2 ] || exit 1
  [ "$ATTEMPT" = 5 ] && { echo "连续 5 次被抢先改写，放弃"; exit 1; }
  sleep $((RANDOM % 5 + 1))
done
echo "已发布 $PUBLIC/$CHANNEL/manifest.json"
cat "$WORK/final.json"
