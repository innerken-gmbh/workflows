# 读写 s3://$BUCKET/appcenter/<channel>/manifest.json，用 ETag 做条件写入（乐观锁）。
# 由 publish-appcenter-artifact.sh / rollout-appcenter.sh source。
#
# 两个仓库（或分支）同时发布时，各自读到同一份旧 manifest、各自合并再写回，后写的会覆盖先写的。
# 现在写回带 --if-match <读到时的 ETag>：中间被别人改过，S3 回 412，调用方重新读、重新合并再写。

# manifest_get <channel> <输出文件>：设置 MANIFEST_ETAG；manifest 还不存在时写 {}、ETag 为空
manifest_get(){
  local out err
  if out=$(aws s3api get-object --bucket "$BUCKET" --key "appcenter/$1/manifest.json" "$2" --output json 2>&1); then
    MANIFEST_ETAG=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ETag"])')
  elif printf '%s' "$out" | grep -q 'NoSuchKey'; then
    echo '{}' > "$2"; MANIFEST_ETAG=""
  else
    echo "读 manifest 失败：$out" >&2; return 1
  fi
}

# manifest_put <channel> <文件> <etag>：0 = 写入成功；2 = 被别人抢先改过（412），要重读重试；其他 = 失败
manifest_put(){
  local cond out
  if [ -n "$3" ]; then cond=(--if-match "$3"); else cond=(--if-none-match '*'); fi
  if out=$(aws s3api put-object --bucket "$BUCKET" --key "appcenter/$1/manifest.json" --body "$2" \
      --acl public-read --content-type application/json --cache-control "no-cache" "${cond[@]}" --output json 2>&1); then
    return 0
  fi
  if printf '%s' "$out" | grep -qE 'PreconditionFailed|ConditionalRequestConflict|\(412\)|\(409\)'; then
    echo "  manifest 在读写之间被别的发布改过，重新读取再合并" >&2; return 2
  fi
  echo "写 manifest 失败：$out" >&2; return 1
}
