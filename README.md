# WeLite

面向 KOReader 的微信读书插件，以清晰的黑白界面呈现书架、阅读统计和快捷控制，优先适配 Kindle 等墨水屏设备。

WeLite 基于 **[finlater/weread.koplugin](https://github.com/finlater/weread.koplugin)** 开发，沿用上游的登录、下载、同步、公众号、书评和划线想法等功能，在此基础上接入 WeLite 的界面与交互。感谢 **finlater 及上游贡献者** 提供的功能实现。

> **修改版本声明 · 2026-10-21**：本仓库由 Xlawy 维护，是上游项目的独立修改版本，不是上游官方发行版。本次修改包括 WeLite 书架、筛选与下拉界面、数据适配、对应测试及 fork 更新源。项目继续采用 **AGPL-3.0-only**；原作者版权与许可证声明保留，详见本文末尾和 [NOTICE](NOTICE)。

[WeLite 源码](https://github.com/Xlawy/weread-based-welite) · [版本发布](https://github.com/Xlawy/weread-based-welite/releases) · [问题反馈](https://github.com/Xlawy/weread-based-welite/issues)

## 功能

- **WeLite 书架**：分页封面、阅读进度、全书 / 部分下载标记、书名与作者；支持本地搜索、排序和下载状态筛选。
- **本地阅读**：本地分类包含全书和已下载章节，也保留从云端书架移除的下载记录；点击已下载书籍阅读，长按打开书籍操作。
- **阅读统计**：主页展示本月、本周和今日数据，支持进入社区版统计详情；缺失数据显示「—」。
- **下拉快捷控制**：WIFI、夜间模式、全屏刷新、KOReader 设置、WeLite 设置和背光调节；阅读时显示章节、页数及目录导航。
- **社区功能**：保留扫码登录、公众号、书籍详情、书评、划线想法、多选章节 / 全书下载、章节预下载、阅读进度与时长上报，以及 SimpleUI / ZenUI 集成。

书架使用 KOReader 原生控件，当前页最多显示六张封面。设备能力不足时，对应控制会禁用或显示未知状态。

## 安装与更新

建议使用 **KOReader 2026.03 或更高版本**。

1. 从 [WeLite Releases](https://github.com/Xlawy/weread-based-welite/releases) 获取本 fork 的安装包；如尚无可用发行版，可在源码目录执行 `make package`。
2. 退出 KOReader，备份已有插件目录与个人配置。
3. 解压 `weread.koplugin-vX.Y.Z.zip`，将其中的 `weread.koplugin` 放入 `koreader/plugins/`。
4. 重启 KOReader，从 **工具 → 微信读书 → 书架** 打开 WeLite。

```text
koreader/plugins/weread.koplugin/
```

当前保留 `weread.koplugin` 目录名及「微信读书」宿主菜单名称，以兼容上游的数据与集成入口。该目录会替换已安装的同名社区插件；原作者 Releases 中的安装包不包含 WeLite 界面。

在线更新源指向本 fork。只有本仓库发布符合更新器要求的安装包及校验文件后，在线更新才可用。

## 登录

1. 在手机微信读书 App 中进入 **我 → 设置 → 微信读书 Skill**，获取个人 API Key。
2. 在设备上打开 **工具 → 微信读书 → 微信扫码登录**，或点击 WeLite 顶栏的「未登录」。
3. 使用微信扫码确认；如手机显示四位验证码，在设备上输入。

账号认证与缓存管理沿用社区版实现。请勿在问题反馈、截图或日志中公开 Cookie、API Key、个人批注及受版权保护的书籍内容。

## 界面与操作

| 入口 | 操作 |
| --- | --- |
| 书架 / 本地 | 切换云端书架与已下载内容 |
| 同步 | 显式刷新书架 |
| 筛选 / 排序 | 输入书名或作者，选择排序与下载状态；「应用」生效，「取消」不改变列表 |
| 点击书籍 | 已下载书籍直接阅读；未下载书籍进入社区版书籍详情 |
| 长按书籍 | 打开社区版书籍操作，保留下载、详情等入口 |
| 左上角 WeLite | 下载书籍、重载本页封面、切换账号、退出登录及社区功能 |
| 顶部下拉 / Menu 键 | 打开主页快捷控制；阅读器也支持顶部点击、下滑与拖动释放 |
| 下拉 → WeLite 设置 | 调整时间显示与启动时自动打开的偏好 |

公众号、微信分组、列表视图及全部社区功能位于 **WeLite → 社区功能…**。原生 KOReader 的「工具 → 微信读书」菜单也继续可用。

主页统计使用会话缓存，首次无数据时显示「—」；通过 **WeLite → 社区功能… → 刷新阅读统计** 获取汇总。今日数据按 UTC+8 自然日计算。书架刷新、统计刷新和阅读同步是不同操作，翻页不会隐式触发全量同步。

SimpleUI / ZenUI 继续使用其「微信读书」插件入口。WeLite 没有另建一套账号、下载或阅读记录存储。

## 开发与测试

所有开发遵守 [AGENTS.md](AGENTS.md)：轻量化、模块职责清晰、行为模块对应测试，发行包排除开发依赖与测试数据。

```sh
make check    # 模块测试映射与 Lua 命名空间检查
make test     # Lua 测试、Python 工具测试及真实 KOReader 集成测试
make package  # 生成 dist/weread.koplugin-vX.Y.Z.zip
```

`make test` 需要已经构建好的 KOReader 运行目录。本机可自动发现相邻 `welite/.dev/koreader/` 下的唯一模拟器构建；其他环境显式指定：

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
| [本 WeLite fork](https://github.com/Xlawy/weread-based-welite) | Xlawy and contributors | 界面迁移、社区数据适配、测试与维护 |

本 fork 的迁移基线为上游提交 [`ae3930fa91e59ac72152fa709029e39fe6bcd1d6`](https://github.com/finlater/weread.koplugin/tree/ae3930fa91e59ac72152fa709029e39fe6bcd1d6)（1.6.0）。上游已有工作不归为本 fork 原创；原作者的版权、许可证和第三方声明继续保留。

```text
Upstream: Copyright (C) 2026 finlater and contributors
WeLite modifications: Copyright (C) 2026 Xlawy and contributors
SPDX-License-Identifier: AGPL-3.0-only
```

### 代码许可与源码获取

本项目作为上游的修改版本，整体继续按 **[GNU Affero General Public License v3.0](LICENSE)** 分发，SPDX 标识为 **`AGPL-3.0-only`**。许可证正文未修改；[NOTICE](NOTICE) 记录来源、修改日期与第三方材料。

修改和再分发时，请保留版权、许可和无担保声明，显著标明修改及日期，并按许可证适用条款提供对应版本的完整源码。发行包应与 [本仓库](https://github.com/Xlawy/weread-based-welite) 对应发布标签的源码一致；发布前需确保实际修改已包含在该标签及可获取的源码中，不能仅提供上游源码或与发行包不匹配的仓库链接。

若修改版本支持用户通过网络远程交互，还须依 AGPL 第 13 条向这些用户显著提供免费获取对应源码的机会。具体条件以 [许可证全文](LICENSE) 和 [GNU 官方说明](https://www.gnu.org/licenses/gpl-faq.en.html) 为准。本项目不另加「禁止商业用途」等限制 AGPL 授权的条款。

### 第三方材料与无担保声明

`fonts/NotoEmoji-Regular.ttf` 的版权属于 **Google LLC（2013）**，按 **[SIL Open Font License 1.1](fonts/LICENSE)** 分发；该字体不改用 AGPL，字体许可证随发行包保留。

本软件按许可证约定提供，不附带适销性、特定用途适用性等担保。WeLite 是非官方项目，与微信读书、腾讯或 KOReader 不存在官方隶属、授权背书关系；相关名称与商标归各自权利人所有。软件许可证不授予书籍内容或第三方服务的使用权。
