# workflows

InnerKen 共享 CI。组织内的私有仓库可以直接引用这里的 action / workflow（仓库 Actions 访问权限已设为 organization），不需要 token。

## appcenter-publish

把前端构建产物发布到 AppCenter 的 S3 通道，门店设备由 aaden-cli `appcenter-sync` 每天拉取。

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: innerken-gmbh/workflows/appcenter-publish@main
    with:
      app: Admin            # AppCenter 里的目录名
      dist: dist            # 构建产物目录
      role-to-assume: ${{ vars.AWS_OIDC_ROLE_ARN }}
```

- **按应用自动灰度**：有内容变化的应用写 `apps.<App>.rollout`（ik0001 + `deviceId % 100 < 10`）和 `apps.<App>.rolloutStartedAt`，manifest 标 `perAppRollout: true`。
- **自动放量**：`appcenter-promote` 每小时检查一次，哪个应用灰度满 24 小时，就把哪个应用放到全量。
- **先只放几台**：调用时填 `rollout-devices: '9020'`，换了内容的应用灰度就是这个名单（percent 0），不写开始时间，所以不会自动全量。
- **扩大灰度**：在本仓库手动跑 `appcenter-widen`，填应用、kind、名单和百分比。灰度改成「名单 + `deviceId % 100 < percent`」，并从这一刻开始计时，满 24 小时由 `appcenter-promote` 自动全量。已经全量（没有 rollout）的应用不能用 widen 收窄。计时选 `none` 就不写开始时间，不会自动全量（比如要等某几家店约好时间）。
- **名单里加设备**：`appcenter-add-devices` 只把 1–3 台加进某个应用现有的灰度名单，百分比和开始时间都不动，也不碰别的应用；已经全量的应用什么都不做。给群助手小登（aaden-bot）用，只能从 main 运行。
- **清单条目带版本**：发布时把 version.json 里的 `version` / `commit` / `ref` 也写进 `apps.<App>`，不用下载 zip 就知道清单里发的是哪一版。
- **回滚**：在本仓库手动跑 `appcenter-rollback`，选应用。该应用恢复成上一版（`previousApps`）并全量下发。第一次发布的应用没有上一版，不能这样回滚：要么用同一个发布入口再发一个旧版本，要么从清单里删掉这个应用（已经换上新版的设备不会退回去）。**注意**：用 `rollout-devices` 先只放几台、然后又正常发了一版的话，`previousApps.<App>` 就是那版只在这几台验过的版本，这时跑 rollback 会把它全量推出去。
- 设备端不读 previous：不在灰度名单里的设备原地不动，不会去拿上一版。
- **兼容老设备**：按应用灰度要 aaden-cli 支持 `perAppRollout`（innerken-gmbh/aaden-cli#25，1.6.119 起）。10-15 起（POS-157）按应用灰度时顶层 `rollout` 一律不设：新 CLI 用顶层 `rollout` 决定 ensureNoCache，留着会把 index.html no-cache 卡在 10%。代价是不认 `perAppRollout` 的老 CLI（< 1.6.119）收前端时不再灰度。
- **并发安全**：manifest 读写用 S3 的 ETag 条件写入（`--if-match`），两个仓库或分支同时发布时，后写的一方会收到 412，自动重读、重新合并再写，最多重试 5 次（2026-10-11 用 3 个并发任务实测，没有更新丢失）。
- 不做「两次发布间隔 14 天」的检查（FORCE），连续发版可能导致白屏，见 Jira POS-27。

AWS 用 OIDC 角色 `github-appcenter-publish`，只能读写 `s3://aaden-backend/appcenter/*`，信任 innerken-gmbh 的 workflows、aaden-vue-admin、aaden-php-backend，以及 aaden-vue-app（仅 master）。

脚本复制自 aaden-php-backend/scripts（2026-10-11），加了自动灰度和 previousApps。
