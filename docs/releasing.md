# Releasing / 发布

发行采用本地完整验证、直接上传候选包的方式。推送 `main` 只触发快速 CI；不自动发布，也不为每次推送重新构建 KOReader。固定版本 KOReader 集成保留手动运行和每周检查，用于发现宿主兼容性问题。

## 发布前验收

1. 更新 `welite/identity.lua` 的 `X.Y.Z` 版本，在 `CHANGELOG.md` 中添加对应的非空版本说明。
2. 在已编译的本地 KOReader 环境运行 `make test`，保存测试结果、运行时版本和源码提交。再执行 `make check`、静态检查及本地模拟服务测试。
3. 用 `scripts/package_release.sh` 打包，在隔离配置中验证实际候选 ZIP 的加载、入口、关键功能和旧版更新器兼容性。不能只测试工作区代码后上传未经验证的另一个包。
4. 按 [窗口与设备验收清单](macos-release-testing.md) 记录适用的界面和 Kindle 验证。缺少平台、窗口或真机条件时记录 BLOCKED 和未覆盖范围，由发布负责人明确接受例外；不能把本地自动化通过写成真机通过。
5. 确认包内没有凭证、账本、缓存、日志、测试或开发依赖。提交并推送 `main`，确认快速 CI 在该提交上通过，再发布已经验证的 ZIP。

本地完整集成通过后，不要求等待 GitHub 重复运行完整集成。修改宿主兼容性或测试运行时版本时，另行执行固定版本集成。功能或测试输入改变后重跑受影响检查；只有工作流或不入包文档变化时，核对候选包内容与最终提交一致，不必重编宿主。

## 本地打包与发布

以下命令需要已登录的 GitHub CLI。`release_sha` 必须是最终已验证且已推送到 `main` 的提交；验证期间有源码变化时，重新构建和验证候选包。标签必须是新版本，不覆盖已有标签或附件。

```bash
# 先完成代码提交；只发布已提交、已验证的内容。
git diff --exit-code
git diff --cached --exit-code
release_version="$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' welite/identity.lua)"
release_tag="v$release_version"
release_archive="dist/welite.koplugin-$release_tag.zip"
release_sha="$(git rev-parse HEAD)"

bash scripts/package_release.sh "$release_archive"
# 在隔离 KOReader 配置中完成上述候选包验证，再继续。
(
    cd dist
    shasum -a 256 "welite.koplugin-$release_tag.zip" > "welite.koplugin-$release_tag.zip.sha256"
)
bash scripts/extract_release_notes.sh "$release_version" dist/release-notes.md

# 完成提交并推送后，确认远端 main 与 release_sha 一致。
test "$(git ls-remote origin refs/heads/main | cut -f1)" = "$release_sha"
test "$(gh run list --repo Xlawy/welite --workflow ci.yml --commit "$release_sha" \
    --branch main --limit 1 --json conclusion --jq '.[0].conclusion // ""')" = success
# 若快速 CI 尚未结束，等到通过后再运行下面的创建命令。
gh release create "$release_tag" "$release_archive" "$release_archive.sha256" \
    --repo Xlawy/welite --target "$release_sha" --title "Version $release_version" \
    --notes-file dist/release-notes.md --generate-notes
```

发布后确认标签指向目标提交，下载 ZIP 和 `.sha256` 验证摘要，并核对附件内容与本地已验证的包一致。测试日志和验收记录应标明提交、宿主版本、包摘要、结果和未覆盖范围；上传记录前去除账号、凭证及个人内容。

## 包内容

发行包只有一个顶层 `welite.koplugin/` 目录，包含 `_meta.lua`、`main.lua`、`welite/`、`fonts/`、`icons/`、README 和许可证。打包时从 `welite/identity.lua` 生成旧版更新器可识别的字面量版本元数据。开发目录不入包。

## GitHub 手动打包

**Actions → Release → Run workflow** 仍可用于远端生成临时包。`package_label` 留空时使用提交 ID 前八位，也可填写短标签。工作流校验版本、包内容和 CHANGELOG，生成 ZIP 与 SHA-256，分别保存为 14 天有效的 artifacts；不创建 tag 或 GitHub Release，也不持有写仓库权限。

**Actions → KOReader integration → Run workflow** 可手动运行固定宿主版本集成；每周计划任务也保留。它不再作为发布触发器。
