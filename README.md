# WeLite

面向 KOReader 的微信读书插件，以清晰的黑白界面呈现书架、阅读统计和快捷控制，优先适配 Kindle 等墨水屏设备。

WeLite 基于 **[finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)** 开发，沿用上游的登录、下载、同步、公众号、书评和划线想法等功能，在此基础上接入 WeLite 的界面与交互。感谢 **finlater 及上游贡献者** 提供的功能实现。

> **修改版本声明 · 2026-10-21**：本仓库由 Xlawy 维护，是上游项目的独立修改版本，不是上游官方发行版。本次修改包括 WeLite 书架、筛选与下拉界面、数据适配、对应测试及 fork 更新源。项目继续采用 **AGPL-3.0-only**；原作者版权与许可证声明保留，详见本文末尾和 [NOTICE](NOTICE)。

**当前版本：v1.0**（发行版本号 `1.0.0`，独立于上游版本）。

[WeLite 源码](https://github.com/Xlawy/welite) · [版本发布](https://github.com/Xlawy/welite/releases) · [问题反馈](https://github.com/Xlawy/welite/issues)

## 功能

- **WeLite 书架**：分页封面、阅读进度、全书 / 部分下载标记、书名与作者；支持本地搜索、排序和下载状态筛选。
- **本地阅读**：本地分类包含全书和已下载章节，也保留从云端书架移除的下载记录；点击已下载书籍阅读，长按打开书籍操作。
- **阅读统计**：主页展示本月、本周和今日数据，支持进入社区版统计详情；缺失数据显示「—」。
- **下拉快捷控制**：WIFI、夜间模式、全屏刷新、KOReader 设置、WeLite 设置和背光调节；阅读时显示章节、页数及目录导航。
- **社区功能**：保留扫码登录、公众号、书籍详情、书评、划线想法、多选章节 / 全书下载、章节预下载、阅读进度与时长上报，以及 SimpleUI / ZenUI 集成。

书架使用 KOReader 原生控件，当前页最多显示六张封面。设备能力不足时，对应控制会禁用或显示未知状态。

## 安装与更新

建议使用 **KOReader 2026.03 或更高版本**。

1. 从 [WeLite Releases](https://github.com/Xlawy/welite/releases) 获取本 fork 的安装包；如尚无可用发行版，可在源码目录执行 `make package`。
2. 退出 KOReader，备份已有插件目录与个人配置。
3. 解压 `welite.koplugin-vX.Y.Z.zip`，将其中的 `welite.koplugin` 放入 `koreader/plugins/`。从旧版本升级时，请在退出 KOReader 后移走旧的 `weread.koplugin` 插件目录，再安装新目录，避免同时加载两份插件。登录与偏好设置保留；默认下载目录改为 KOReader 数据目录下的 `welite/cache`。旧 `weread/cache` 的下载索引停用，不迁移或复用旧缓存，旧书需要重新下载，旧文件不会自动删除。包内 Noto Emoji 字体仍用于想法弹窗和书评的 Emoji 后备显示，其 OFL 许可证一同保留。
4. 重启 KOReader，从 **工具 → WeLite → 书架** 打开 WeLite。

```text
koreader/plugins/welite.koplugin/
```

插件安装目录为 `welite.koplugin`；内部模块命名及数据存储仍兼容现有实现。原作者 Releases 中的安装包不包含 WeLite 界面。

在线更新源指向本 fork。只有本仓库发布符合更新器要求的安装包及校验文件后，在线更新才可用。

## 登录

1. 在手机微信读书 App 中进入 **我 → 设置 → 微信读书 Skill**，获取个人 API Key。
2. 在设备上打开 **工具 → WeLite → 微信扫码登录**，或点击 WeLite 顶栏的「未登录」。
3. 使用微信扫码确认；如手机显示四位验证码，在设备上输入。

账号认证与缓存管理沿用社区版实现。可在 **WeLite 设置 → 下载与存储 → 缓存目录** 查看和修改下载位置；不指向旧 `weread/cache` 的自定义目录仍保留。请勿在问题反馈、截图或日志中公开 Cookie、API Key、个人批注及受版权保护的书籍内容。

公众号文章按公众号与文章 ID 隔离缓存，避免同名文章覆盖。升级前仅按标题保存的 HTML/EPUB 文件仍会保留；由于无法可靠确认其文章归属，需在公众号列表重新下载，之后可离线打开。 文章列表刷新后可用“更早文章 / 较新文章”浏览历史批次，每次仅加载一批；返回游标保留最近 20 批，首页缓存仍可离线使用。

## 界面与操作

| 入口 | 操作 |
| --- | --- |
| 书架 / 本地 | 切换云端书架与已下载内容 |
| 同步 | 沿用上游接口补报已记录的待上报阅读时长，并刷新书架、本地已下载及最近阅读书籍的云端进度，以及首页阅读时间 |
| 筛选 / 排序 | 输入书名或作者，选择排序与下载状态；「应用」生效，「取消」不改变列表 |
| 点击书籍 | 已下载书籍直接阅读；未下载书籍进入社区版书籍详情 |
| 长按书籍 | 打开社区版书籍操作，保留下载、详情等入口 |
| 左上角 WeLite | 下载书籍、重载本页封面、切换账号、退出登录及社区功能 |
| 顶部下拉 / Menu 键 | 打开主页快捷控制；阅读器也支持顶部点击、下滑与拖动释放 |
| 下拉 → WeLite 设置 | 分为基础设置、同步与阅读时间、下载与存储、阅读与批注、账号管理、关于与高级六类；分类内按需分页，重复入口合并 |

公众号、微信分组及社区功能位于 **WeLite → 社区功能…**。原生 KOReader 的「工具 → WeLite」菜单也继续可用。

主页先展示会话缓存，缺失时显示「—」并在后台获取本月、本周统计；一小时内不自动重复请求，失败后可通过 **WeLite → 社区功能… → 刷新阅读统计** 重试。进度查询限于本地下载记录与最近阅读的 10 本书（按云端阅读时间及本地阅读记录排序、去重，排除公众号）；其他书保留已有进度或显示「—」，打开时由默认开启的进度拉取处理。符合条件的书籍进度在后台按当前页加载，每批最多六本，缓存最多 128 条；失败保留未知状态，可点击同步后重试。今日数据按 UTC+8 自然日计算。手动同步全量刷新书架列表，但只查询上述范围的阅读进度，同时刷新阅读时间；已关书的待上报时长会先补报，再获取统计，每次最多处理六本书、每本最多 300 秒。全部刷新成功且没有剩余待补报记录时显示「数据已刷新」；部分失败或仍有积压时提示未完成。翻页不会隐式触发全量同步。主页补报期间开书仍会正常计时；同一本书的补报、定时上报和进度上传互斥，网络忙时保留待上报记录。

阅读进度读写复用上游 WeRead Client 与 ReadReport 协议，WeLite 适配 KOReader 的章节源文本位置、后台任务及同步状态。自动拉取与关闭上传默认开启（保留已保存的手动关闭选择），可在 **下拉栏 → WeLite 设置 → 同步与阅读时间** 中设置；阅读中打开顶部控制台，点击「同步进度」调用上游手动同步入口。关书会保存本次改变的准确位置（关闭自动上传时也保留）。主页同步先处理最多六本已关书的待上传进度：云端仍是本次阅读基准或本机已确认的上报位置时，通过上游 ReadReport 上传；云端已经是目标位置时只确认完成；两端都改变或缺少可靠基准时保留待选择状态。随后补报阅读时长并刷新书架、云端进度与统计。整个过程不自动开书、不弹进度选择；真正需要选择的书籍，等用户打开后再比较。标记跨重启保留，确认后清除。上游弹窗选择云端进度会跳转，选择本地进度会上传；「数据已刷新」仅表示云端数据刷新完成。补报时先读取云端位置，避免携带已关书的旧本地位置；发送后回执不明的时长单独保留，不自动重发，可在阅读上报状态中查看。通过 **阅读上报 → 待核对阅读时间** 按书查看这些记录，核对微信读书后选择“已计入”或“重新补报”；重新补报需要再次确认，并在下次同步执行。重启后也会识别异常退出遗留的批次，正在运行的任务不会被误处理。云端读写之间其他设备恰好更新位置的竞争，以及跨日积压时长在服务端的日期归属，尚未验证。

SimpleUI / ZenUI 继续使用其「WeLite」插件入口。WeLite 没有另建一套账号、下载或阅读记录存储。

## 开发与测试

所有开发遵守 [AGENTS.md](AGENTS.md)：轻量化、模块职责清晰、行为模块对应测试，发行包排除开发依赖与测试数据。

```sh
make migrate-emulator # 首次从相邻旧 WeLite 导入已编译模拟器
make run      # 启动桌面模拟器，使用当前插件和独立配置
make check    # 模块测试映射与 Lua 命名空间检查
make test     # Lua 测试、Python 工具测试及真实 KOReader 集成测试
make package  # 生成 dist/welite.koplugin-vX.Y.Z.zip
```

`make run` 和 `make test` 默认使用当前仓库的 `.dev/emulator`。首次执行 `make migrate-emulator` 将旧 WeLite 的已编译运行环境复制到这里，展开构建软链接，排除旧插件、旧测试和用户配置；迁移后不再依赖旧项目。已有目标不会被覆盖，也不会复制账号凭证。可通过 `make migrate-emulator ARGS="--source /绝对路径/koreader"` 指定来源。

模拟器默认使用简体中文；已在 KOReader 中保存的语言选择优先，也可用 `LANGUAGE=en_US make run` 指定启动语言。窗口默认 600×800、167 DPI，可执行 `make run ARGS="--width 1072 --height 1448 --dpi 300"` 调整。配置保存在 `.dev/profile`，首次启动按提示选择是否自动打开 WeLite，或从「工具 → WeLite → 书架」进入。退出模拟器后再运行测试，避免同时占用插件链接。

其他环境也可显式指定已编译运行目录：

```sh
KOREADER_RUNTIME=/绝对路径/koreader make test
```

测试入口不会自动下载或编译 KOReader。测试报告和渲染预览写入 `.dev/reports/`，不进入发行包。

- [原版 WeLite UI 精确迁移与像素验证](docs/welite-ui-parity.md)
- [社区版功能评估与首次迁移记录](docs/welite-migration.md)
- [模块与测试映射](tests/module-map.json)
- [上游贡献指南](CONTRIBUTING.md)

当前已验证桌面模拟器中的布局与交互，不代表 Kindle 真机性能验收。部分上游网络路径仍在 UI 线程执行；真实设备的耗时、内存、无线连接、休眠与墨水屏刷新仍需验证。

## 来源、署名与许可证

### 上游与修改来源

| 项目 | 作者 / 维护者 | 在 WeLite 中的作用 |
| --- | --- | --- |
| [WeRead KOReader Plugin](https://github.com/finlater/weread.koplugin) | finlater and contributors | 登录、协议、下载、同步、公众号、书评、划线想法及集成等功能底座 |
| [原 WeLite 项目](https://github.com/Xlawy/welite) | Xlawy and contributors | 书架、筛选、下拉控制及相关界面设计与实现 |
| [本 WeLite fork](https://github.com/Xlawy/welite) | Xlawy and contributors | 界面迁移、社区数据适配、测试与维护 |

本 fork 的迁移基线为上游提交 [`ae3930fa91e59ac72152fa709029e39fe6bcd1d6`](https://github.com/finlater/weread.koplugin/tree/ae3930fa91e59ac72152fa709029e39fe6bcd1d6)（1.6.0）。上游已有工作不归为本 fork 原创；原作者的版权、许可证和第三方声明继续保留。

```text
Upstream: Copyright (C) 2026 finlater and contributors
WeLite modifications: Copyright (C) 2026 Xlawy and contributors
SPDX-License-Identifier: AGPL-3.0-only
```

### 代码许可与源码获取

本项目作为上游的修改版本，整体继续按 **[GNU Affero General Public License v3.0](LICENSE)** 分发，SPDX 标识为 **`AGPL-3.0-only`**。许可证正文未修改；[NOTICE](NOTICE) 记录来源、修改日期与第三方材料。

修改和再分发时，请保留版权、许可和无担保声明，显著标明修改及日期，并按许可证适用条款提供对应版本的完整源码。发行包应与 [本仓库](https://github.com/Xlawy/welite) 对应发布标签的源码一致；发布前需确保实际修改已包含在该标签及可获取的源码中，不能仅提供上游源码或与发行包不匹配的仓库链接。

若修改版本支持用户通过网络远程交互，还须依 AGPL 第 13 条向这些用户显著提供免费获取对应源码的机会。具体条件以 [许可证全文](LICENSE) 和 [GNU 官方说明](https://www.gnu.org/licenses/gpl-faq.en.html) 为准。本项目不另加「禁止商业用途」等限制 AGPL 授权的条款。

### 第三方材料与无担保声明

`fonts/NotoEmoji-Regular.ttf` 的版权属于 **Google LLC（2013）**，按 **[SIL Open Font License 1.1](fonts/LICENSE)** 分发；该字体不改用 AGPL，字体许可证随发行包保留。

本软件按许可证约定提供，不附带适销性、特定用途适用性等担保。WeLite 是非官方项目，与微信读书、腾讯或 KOReader 不存在官方隶属、授权背书关系；相关名称与商标归各自权利人所有。软件许可证不授予书籍内容或第三方服务的使用权。
