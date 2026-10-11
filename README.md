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

- **自动灰度**：有内容变化时，灰度重置为 ik0001 + `deviceId % 100 < 10`，记下 `rolloutStartedAt`。
- **自动放量**：`appcenter-promote` 每小时检查一次，灰度满 24 小时就全量。
- **回滚**：在本仓库手动跑 `appcenter-rollback`，选应用。该应用恢复成上一版（`previousApps`）并全量下发。
- 不做「两次发布间隔 14 天」的检查（FORCE），连续发版可能导致白屏，见 Jira POS-27。
- 灰度是整个 channel 共用的：任何一个应用一发布，正在灰度的其他应用也会重新从 10% 开始。

AWS 用 OIDC 角色 `github-appcenter-publish`，只能读写 `s3://aaden-backend/appcenter/*`，信任 innerken-gmbh 的 workflows、aaden-vue-admin、aaden-php-backend。

脚本复制自 aaden-php-backend/scripts（2026-10-11），加了自动灰度和 previousApps。
