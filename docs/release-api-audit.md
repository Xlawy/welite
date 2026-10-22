# WeLite v1.0.1 发版接口检查

检查日期：2026-10-22。对象为本工作树，包含尚未提交的修复。本轮本地回归已通过；用户在本会话确认 Kindle 与手机双向进度、阅读时长同步正常。此报告随 v1.0.1 提交，Release 的真实资产发现属于发布后的核验。

## 范围与证据等级

本插件不提供独立 HTTP 服务。“暴露的 API”包括微信读书网络调用、GitHub 更新接口、KOReader 入口及设置回调。保留上游协议实现；WeLite UI 调用这些实现，不另造阅读协议。

本轮证据来自静态调用链审查、确定性单元测试、真实 KOReader + 本地 HTTP 模拟服务、独立更新安装环境。模拟服务不能证明微信当前线上响应与账号授权有效；没有执行会改写真实账号进度或时长的自动发布验收。

## 接口清单

| 接口与入口 | 责任模块 | 验证与关键边界 |
| --- | --- | --- |
| getLoginUid、getLoginInfo、userInfo、apikeyGet | qr_login、settings、auth_state | qr_login_spec、welite_auth_lifecycle_spec：登录请求隔离旧账号 Cookie；保存完成才进入主页；失败和过期回调不导航 |
| /web/login/renewal | client | client_spec、client_web_progress_spec：只有明确成功才持久化 Cookie；失效只续期一次 |
| /api/agent/gateway → /shelf/sync | client、library、shelf_snapshot | gateway_contract、shelf_snapshot、welite_sync、HTTP smoke：空书架与业务失败区别；账号切换隔离；全书架刷新 |
| /book/info | client、book_detail | gateway_contract、welite_book_detail、welite_book_info：资料、缓存和详情操作 |
| /book/getprogress、/web/book/getProgress | client、progress_sync、closed_progress_sync、position_mapper | client_web_progress、progress_sync、closed_progress_sync、progress_scope：冲突保护、离线书本地修改、限定同步范围，打开其他书再拉取 |
| /web/book/read | client、read_report、reading_time_ledger、reading_time_sync | read_report_*、reading_time_*、welite_time_ledger：UTF-16 位置、时长账本、未知写入不重复重放、账号与书籍锁、关书持久化 |
| /readdata/detail | client、welite/statistics | gateway_contract、welite_statistics、HTTP smoke：统计刷新、过期任务和请求上限 |
| /store/search | book_search_controller、xpointer_overlay | book_search、welite_search、xpointer_overlay、HTTP search：分页、取消、空值和失败 |
| /review/list、/web/review/single | client、book_reviews_controller、thought_popup | book_reviews、client_spec、welite_reviews、thought_popup_*、HTTP reviews：分页、评论失败、关闭取消 |
| /book/underlines、/book/readreviews | client、annotation_sync_controller、external_annotations | client_annotation_batch、annotation_*、external_annotations_*、HTTP annotations：分批、断点、限流/取消、账号隔离；任一批失败不能伪装完整成功 |
| /web/reader/...、/web/book/chapterInfos | content、downloader、chapter_catalog_controller | content_*、download_*、downloader_*、welite_chapter_catalog、HTTP smoke/prefetch：目录、断点、文件完整性、完成后才标已下载 |
| /web/book/chapter/e_0…e_3、t_0、t_1；章节资源/TAR/封面 | content、client、cover_cache | download_disk_assets、downloader_resume、cover_*、HTTP smoke/prefetch：下载大小、清理临时文件、重试边界、缓存 |
| /web/mp/articles、/web/mp/content、公众号公开文章及图片 | client、mp_controller、content | client_mp_pagination、mp_article_images、welite_mp、HTTP mp：游标分页、失败同页重试、资源下载 |
| HTTP request/request_follow/get_text/get_binary/get_public_text/download_to_file/post_json | client | client_spec：超时恢复、HTTP/JSON 错误、重定向上限、跨域清除认证头、Cookie 域约束、流式下载；mock_environment 确认模拟模式不回落真实站点 |
| GitHub releases/latest、发行 ZIP 与 SHA-256 | updater、updater_ui | updater_spec、updater_ui_spec、真实 KOReader updater smoke：校验拒绝、重试、持久化、子进程安装、长说明滚动和固定按钮 |
| PluginLoader、onShowWeReadBookshelf、阅读/关闭/退出生命周期 | main、library、reader_lifecycle、welite/home | plugin_load、plugin_composition、welite_startup、welite_home、library_ui_cleanup、真实 PluginLoader 集成 |
| 9 个 Dispatcher 动作及设置回调 | ui/menu、welite/settingsui、reader_controls | ui_integrations、welite_settingsui、welite_reader_controls、welite_sync_flow：书架/本地书架/搜索/统计/快捷菜单/同步/时长状态/批注开关/继续匹配。旧 weread 动作名称保留兼容 |

## 本轮发现并修复

1. 网关 HTTP 200 的业务错误曾被返回为正常数据，可能把失效认证误当空书架。现在明确失败，新增网关契约测试。
2. 想法多批读取曾在部分批失败时返回成功和不完整结果。现在返回失败并停止后续批次，增加失败及完整重试测试。
3. 长章节和脚注的精确位置映射修复：单章上限 1 MiB / 262144 字符；整段脚注规范化保留原文 UTF-16 坐标，拒绝歧义，周期性让出执行。11 万字符合成文本在桌面测试约 0.017 秒、内存增量约 4.5 MiB；不是 Kindle 性能数据。
4. 旧 weread 下载缓存不能重新把书标为已下载；详情下载框改为模态并合并刷新。
5. HTTP 错误日志不再输出原始响应正文，URL 查询串及片段不写日志，保留接口、HTTP 状态和大小诊断。已更新断言验证不泄漏。
6. 静态检查清理未使用变量、遮蔽变量及测试全局污染；冻结的上游 UI 对照文件按具体告警豁免，未修改对照文件内容。
7. 补齐 Web 进度、公众号列表、评论与章节目录的业务错误检查；目录失败保留已有章节。
8. 根 CHANGELOG 改为独立 WeLite 版本 发布说明，原上游历史完整保存在 upstream-changelog.md，避免同名版本抽取成上游旧说明。

## 当前可复核证据

- Lua：`/tmp/welite-release-final-unit.log`，92 个 spec 通过。
- Luacheck 1.2.0：`/tmp/welite-release-lint.log`，283 文件，0 warnings / 0 errors。
- HTTP 模拟服务自身：`/tmp/welite-release-mock-tests.log`，4 tests 通过。
- 实际打包插件的六组 HTTP 联调：`/tmp/welite-release-api-brk8h5z8/results.json`，smoke、annotations、reviews、search、prefetch、mp 全部返回 0；各子目录保存请求和运行证据。
- 独立真实更新安装：`/tmp/welite-release-updater-final.log`，PASS（包含预期的坏校验和拒绝场景）。
- 前轮完整回归：`/tmp/welite-release-final-test.log`，92 个 Lua spec、9 个 Python tests、190 个真实 KOReader tests 全部通过；`.dev/reports/integration.xml` 记录 0 failures / 0 errors。最后的日志脱敏改动另行通过 92 个 Lua spec。

## 最终验收与发布核验

- v1.0.1：`/tmp/welite-v1.0.1-test.log`，92 个 Lua spec、9 个 Python tests 通过。191 个 KOReader 用例中唯一初次失败为新测试误把 PluginLoader 的可调用包装对象当普通函数；按宿主 HandlerSandbox 协议修正后，`/tmp/welite-v1.0.1-plugin.log` 和 `.dev/reports/release-plugin.xml` 的 3 个 PluginLoader 测试全部通过，其他 190 个用例在完整运行中已通过。
- 静态检查 283 个 Lua 文件零告警；CI 敏感信息扫描、Python 编译和发行说明抽取通过。
- 最终包：`dist/welite.koplugin-v1.0.1.zip`，154 个条目；根目录为 `welite.koplugin/`，保留 LICENSE/NOTICE/fonts/LICENSE，不含测试、开发依赖或缓存目录。发行包的 SHA-256 随实际上传字节生成并作为独立资产发布；ZIP 时间戳可能使重打包后的校验和变化，上传前逐文件核对已提交源码与许可证。
- 真机验收：用户于本会话明确回复“已测试，进度和时长均正常”，覆盖 Kindle 关书上传、手机续读、手机修改后 Kindle 拉取，以及阅读时间增长。此为用户验收结果，不是桌面测试推断。
- GitHub 匿名 API 受限流影响；发布后需核验 v1.0.1 的 Release 页面、ZIP 和 SHA-256 资产。检查阶段没有触发真实账号进度或时长写入。
- main 推送将触发 CI/KOReader 工作流；成功且版本标签不存在时自动创建 Release。用户已明确授权推送并发布 v1.0.1。
