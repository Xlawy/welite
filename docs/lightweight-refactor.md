# 轻量化重构与同步审计（2026-10-25）

本文按实施阶段记录；后续“仅同步在线阅读时长”一节覆盖前文的离线补报设计与测试数量。最终发布结果见 [v1.1.0 验证记录](releases/v1.1.0-validation.md)。

分支：`codex/lightweight-sync-refactor`。基于 `f8d929349569c42e0ebb54600fb1d09980e3fdb8`。

这次改动集中在入口、存储、启动恢复、内容解码以及进度/时长同步这些跨功能的核心链路。保留已有 UI、宿主控件、书架、下载、公众号、批注、书评与更新功能，不为重构重新实现已经独立且有测试的视图模块。没有新增发行依赖或改变账号、阅读记录的磁盘格式。

## 模块边界

| 职责 | 模块与调用关系 | 对应验证 |
| --- | --- | --- |
| 插件组装 | `main → reader_services.attach → ProgressSync / ReadReport`；依赖通过宿主回调传入 | `reader_services_spec`、原生 `welite_sync_flow_spec` |
| 单书持久化 | `ProgressSync / ReadReport → BookStore.get/put → Settings.get_book/set_book`；书架仍可显式枚举整库 | `settings_spec`、原生 `welite_bounded_storage_spec` |
| 文件路径 | `book_paths` 统一存储和下载的目录优先级、迁移后路径与名称规则 | `book_paths_spec`、既有下载/存储测试 |
| 进度状态 | `progress_sync` 保留冲突选择、会话有效性、来源映射和生命周期；关书与休眠共用检查点 | `progress_sync_spec`、原生 `welite_sync_flow_spec` |
| 上报调度 | `read_report` 管理计时任务、子进程、回执收集和父进程落盘 | `read_report_progress_spec`、原生 `welite_time_ledger_spec` |
| 网络尝试 | `report_pipeline` 负责上下文刷新、有限重试和凭证续期；不直接决定账本落盘 | 同上，含超时、认证、未知写入及限流用例 |
| 回执语义 | `report_response` 统一定时上报、主页补报及中断时的 accepted / retryable / unknown 判定 | `report_response_spec`、`reading_time_sync_spec` |
| 子进程凭证 | `worker_settings` 统一账号和凭证指纹；支持嵌套捕获后的方法还原 | `worker_settings_spec`、原生同步用例 |
| 内容解码 | `content → content_codec`，MD5 校验、稀疏字符交换、宿主 Base64；`content_css` 独立处理 CSS 兼容 | `content_codec_spec`、`content_css_sanitize_spec` |
| 启动恢复 | `migrations`、`downloader.recover` 对同一活动配置只做一次成功恢复；弱键随配置释放 | `plugin_composition_spec`、`downloader_lifecycle_spec` |

`tests/module-map.json` 记录全部行为模块及相应测试。`Content` 仍保留实际被调用的接口，删除了无调用者的 `fetch_first_chapter`、`fetch_single_chapter_content`，以及无效的批注透传和未使用的 HTML 辅助函数；下载使用现有 source / finalize 分阶段接口。

## 同步修复与保留的约束

1. **休眠不再依赖进度已经验证。** 最新本地位置和待上传快照在休眠时保存；离线或取消冲突选择的会话不会因此发起未经授权的上传。检查点合并成一次单书写入，翻页仍不写盘。
2. **已到达的时长回执不会因关书而丢弃。** 子进程被回收时，解析已经返回的完整回执；明确接受则记账，明确未发送/拒绝则保留可重试余额，没有可靠回执仍进入待核对状态，绝不自动重放。
3. **旧账号不能回写书籍上下文。** 凭证指纹包含账号，字段使用长度编码避免分隔符歧义；书籍字段未变化也不足以授权旧任务回写。
4. **HTTP 错误或显式业务失败不会被成功字段覆盖。** 保留字符串 `succ="1"` 的兼容；含糊结果不能成为成功或安全重试依据。明确的 HTTP 429 拒绝结束当前重试链，保留余额供后续正常调度。
5. **非法云端坐标不再被夹成章节起点。** 拒绝负数、小数、非有限值和超过既有上报上限的偏移；合法零位置和超过目录字数的 HTML UTF-16 偏移仍被保留。时长补报复用同一远端坐标归一化规则。
6. **关闭书籍的回补只保存真正处理过的书籍。** 保留云端基线比较、较新本地快照保护、账号隔离和不明确写入后的云端回读；不会因此清空其他书籍的待上传状态。
7. **迁移失败不丢旧目录。** 目录缓存保存失败时不删除旧章表，不标记迁移完成；未启动新下载前，启动清理失败仍可重试。一旦开始调度新下载，本进程不再重新清扫该配置，剩余旧产物留给下次启动恢复，避免删除新任务文件。

阅读时间账本继续保持原来的 256 条容量、单书所有权和未知结果人工核对机制；主页每批最多 6 本、每本最多 300 秒。普通上报最多三次发送，未知结果立即停止；网络仍在原有子进程边界运行。以上是本地逻辑和确定性测试的保证，不代表外部服务提供了事务性或幂等承诺。

## 性能证据

测试环境：Linux x86_64，LuaJIT `2.1.1788856981`，已有 KOReader 模拟器 `v0000.00-0-g0dba4dfd6e_2026-10-19_emulator`。均无真实微信账号或外网依赖。

### 阅读器存储路径

旧路径每次识别文档都调用 `Settings:get("books")`，读取所有书籍的 metadata、reading_state 和 articles；单本进度保存又调用整库写入。

新回归在 **1000 本书索引、1000 次连续文档识别**下验证 **0 次 BookStore.load**；随后读取、保存一本书，各调用一次 BookStore.load/save。缓存只保留一个正向路径匹配，并校验索引、目录和缓存根变化。真实 KOReader 测试另用 30 本落盘书籍验证跨 Settings 实例可见性、移动/删除失效和写入失败保护。此处记录的是调用规模，不是 Kindle 延迟。

同一活动配置的第二次插件初始化不再重复迁移整库或清理下载目录；迁移和恢复的独立测试计数均验证这一点。

### 章节解码

相同合成输入，新旧实现逐字节比较；包括 MD5 校验，双方先预热一次，各运行 5 次取平均。计时用 `os.clock`。每次测量前回收垃圾，测量内暂停 GC，记录 Lua 内存分配增量；它不是进程 RSS，也不是设备峰值内存。

| 编码内容大小 | 旧 CPU 时间 | 新 CPU 时间 | 旧分配增量 | 新分配增量 |
| --- | ---: | ---: | ---: | ---: |
| 64 KiB | 25.887 ms | 4.874 ms | 2512.7 KiB | 715.4 KiB |
| 256 KiB | 102.775 ms | 19.319 ms | 10310.8 KiB | 2734.1 KiB |

256 KiB 样本约快 5.3 倍，分配量下降约 73%。原因是 Base64 复用 KOReader 已带的 LuaSocket `mime`，不再展开二进制字符串；协议交换只记录最多 20 个受影响位置，不再为全文每个字节建立 Lua 表项。不会增加安装包中的二进制依赖。

基准脚本与运行记录保存在本地 `.dev/reports/refactor-codec-benchmark.lua` 和 `.dev/reports/refactor-codec-benchmark.txt`；旧文件可从上述基线提交的 `welite/lib/content.lua` 提取至 `/tmp/welite-content-before.lua`。运行脚本使用仓库已有 `.dev/emulator/luajit`，不需要下载依赖。

## 验证与设备边界

最终验证结果：

- `make test`：101 组 Lua spec、18 项 Python 测试、225 项真实 KOReader 集成测试全部通过；集成报告 failures / errors / skips 均为 0。当前版和真实旧版 WeLite v1.0.4 更新器的安装、校验失败拒绝及重试场景通过。
- `python3 scripts/test_mock_weread.py`：4 项离线模拟服务测试通过。该测试绑定本机临时端口，沙箱禁止 socket 创建，已在允许本机监听的执行环境中完成，未连接真实服务。
- Luacheck 1.2.0：307 个文件，0 warnings / 0 errors；Python 语法、Lua 语法、`make check`、`git diff --check` 通过。静态检查工具和 argparse 仅下载到 `/tmp`，不加入仓库或发行包。
- CI 的开发工具安装增加 `lua-socket`，使不带完整 KOReader 的独立解码测试使用真实 Base64 实现；设备运行时继续使用 KOReader 自带模块，无新增运行依赖。
- 发行 ZIP 完整性与内容检查通过，只含插件运行文件、字体图标及说明/许可证，不包含测试、开发依赖、凭证、缓存或日志。
- 原有像素对照覆盖四种主页尺寸、筛选面板和两种下拉面板，全部通过；参考图片、UI 实现和像素断言未修改。

本地完整运行日志为 `.dev/reports/refactor-test.log`，集成明细为 `.dev/reports/refactor-integration.xml`，静态检查为 `.dev/reports/refactor-luacheck.log`。这些文件被 Git 和发行包排除。

Kindle 真机尚未验证：需要检查离线翻页后休眠/唤醒、关书前后上报回执竞态、切换账号、真实微信认证过期与限流，以及大书解码时的系统内存和墨水屏响应。桌面模拟器通过不等于上述真机项目已通过。

## 后续修复：连续换章误报进度冲突

复现条件是按章缓存 EPUB：上一章末尾和下一章开头可以具有相同的全书百分比，但章节 ID 不同。原来每次打开新文件都按独立开书重新比较，导致正常连续阅读也反复弹出选择。整本 EPUB 内的自然翻页没有这条重新打开链路。

修复调用链为 `Library.openFile → ProgressSync.chapter_handoff → ReaderUI.switchDocument → 新实例 ReaderReady → after_open_callback → accept_chapter_handoff → 原有云端拉取/_resolve`。衔接数据通过宿主回调显式传递，不放入全局表或持久化设置，不跨进程保留。只适用于已核验、同账号/配置、同书相邻下一章的明确导航，绑定目标路径和章节，单次使用，60 秒过期；账号切换、休眠和手动同步会撤销待用衔接。

新阅读器仍先核对云端，核验之前不能上报位置。仅在各个已核对来源的章节、偏移、百分比和更新时间保持不变，或匹配本次已确认成功的本机上传时，保留本地新章节并标记待上传。阅读时长报告也携带位置，因此识别本次已核验阅读期间新产生的成功报告回执；旧会话、其他账号、缺失坐标、先前已核对来源缺失和未知写入结果不会作为豁免依据。云端变化不再被自动比较的 2% 显示容差掩盖。普通开书、非相邻跳转和真正冲突保留原有选择策略，UI 布局和选项不变。

衔接只携带最多两个来源的坐标及有限回执，不复制正文、全书索引或队列，也没有增加网络重试。上述 x86_64 KOReader 环境中，用三章已缓存合成 EPUB、已缓存目录/正文、确定性云端响应验证真实宿主切换：连续两次换章共 4 次来源查询（每次 web/gateway 各一次），没有额外请求或换章即时上传。此处是操作规模证据，不是 Kindle 延迟或内存实测。

对应回归：`spec/progress_sync_spec.lua`（连续两次新实例换章、确认上传/时长回执、云端前进/回退/细微偏移、双来源变化、账号/配置/路径/书籍隔离、过期、离线、未知结果、手动同步和整本翻页）、`spec/library_ui_cleanup_spec.lua`（宿主回调传递）、`spec/koreader/welite_chapter_continuation_spec.lua`（真实插件装配、ReaderUI 文件切换、ReaderReady 时序、冲突及休眠落盘）。模块映射已补充。

本轮最终 `make test` 通过：101 组 Lua spec（进度同步 408 项检查）、18 项 Python 测试、227 项真实 KOReader 集成测试（0 failures/errors/skips），以及当前版/真实 v1.0.4 更新器兼容性测试。另外 4 项离线模拟服务测试通过，Luacheck 检查 308 个文件无警告/错误，`make check` 和 `git diff --check` 通过。

本轮验证记录：`.dev/reports/chapter-fix-test.log`、`.dev/reports/chapter-fix-integration.xml`、`.dev/reports/chapter-native.xml`、`.dev/reports/chapter-fix-luacheck.log`。发行包检查使用 `/tmp/welite-chapter-fix-v1.0.6.zip`，不包含测试或开发文件。Kindle 真机和真实微信多设备同步尚未验证。


## 范围调整：仅同步在线阅读时长

按用户要求移除离线时长补报。`reading_time_sync.lua`、`reading_time_review.lua` 及专属测试移除；书架同步不再预留、发送或结算任何阅读时长，历史积压与未知回执不再被当作书架同步失败。真实书架、进度或统计接口失败仍正常提示。

在线计时继续由 `ReadReport → ReadingTimeLedger → 后台 ReportPipeline` 负责，使用新的 `online-reading-time.sqlite3`。旧 `reading-time.sqlite3` 原样保留，不迁移其中混合了离线阅读的余额。宿主 `NetworkDisconnected` 事件结束在线区间，`NetworkConnected` 开始新区间；定时检查补充检测漏发事件的设备。若没有准确断网事件，保守舍弃上次检查后无法确认在线的区间，不把整段离线时间算入上报。休眠、书架停留和离线打开书籍均不计时。

在线记录保留实际秒数、单次 300 秒上限、账号隔离、原文位置校验、落盘失败恢复和回执去重。只重试明确未发送或服务明确拒绝的时间；回执不明的时间不自动重报。关书前不足一个上报周期的已记录在线时间保留到下次在线阅读同书处理，不由首页补报。网络传输或微信认证仍可能失败，因此不能承诺离线、认证失效或回执丢失时云端必然计入。

针对约 5339 秒旧积压、在线/离线/重连、缺失网络事件、休眠、账号切换、未知回执和首页零时长写入增加或调整测试。原有仅针对已删除离线补报/人工重报功能的测试随功能移除，在线计时和位置同步的失败保护继续验证。没有改写已挂载 Kindle 的插件或数据；真机仍运行此前版本。


本轮最终验证：`make test` 通过，包含 99 组 Lua spec、18 项 Python 测试、225 项真实 KOReader 集成测试（0 failures/errors/skips），以及当前版和 v1.0.4 更新器兼容性测试。4 项本地模拟服务测试通过；Luacheck 检查 304 个文件无警告/错误；模块映射、命名空间和 diff 检查通过。发行包 `/tmp/welite-online-time-v1.0.6.zip` 校验通过，共 160 项，已移除离线补报模块，不包含账本、凭证、测试或开发依赖。日志在 `.dev/reports/online-time-test.log`、`online-time-integration.xml`、`online-time-luacheck.log`。
