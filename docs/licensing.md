# 来源、署名与许可证

[返回项目首页](../README.md)


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

本项目作为上游的修改版本，整体继续按 **[GNU Affero General Public License v3.0](../LICENSE)** 分发，SPDX 标识为 **`AGPL-3.0-only`**。许可证正文未修改；[NOTICE](../NOTICE) 记录来源、修改日期与第三方材料。

修改和再分发时，请保留版权、许可和无担保声明，显著标明修改及日期，并按许可证适用条款提供对应版本的完整源码。发行包应与 [本仓库](https://github.com/Xlawy/welite) 对应发布标签的源码一致；发布前需确保实际修改已包含在该标签及可获取的源码中，不能仅提供上游源码或与发行包不匹配的仓库链接。

若修改版本支持用户通过网络远程交互，还须依 AGPL 第 13 条向这些用户显著提供免费获取对应源码的机会。具体条件以 [许可证全文](../LICENSE) 和 [GNU 官方说明](https://www.gnu.org/licenses/gpl-faq.en.html) 为准。本项目不另加「禁止商业用途」等限制 AGPL 授权的条款。

### 第三方材料与无担保声明

`fonts/NotoEmoji-Regular.ttf` 的版权属于 **Google LLC（2013）**，按 **[SIL Open Font License 1.1](../fonts/LICENSE)** 分发；该字体不改用 AGPL，字体许可证随发行包保留。

本软件按许可证约定提供，不附带适销性、特定用途适用性等担保。WeLite 是非官方项目，与微信读书、腾讯或 KOReader 不存在官方隶属、授权背书关系；相关名称与商标归各自权利人所有。软件许可证不授予书籍内容或第三方服务的使用权。
