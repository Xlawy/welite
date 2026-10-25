# WeLite 开发与测试

[返回项目首页](../README.md)


所有开发遵守 [AGENTS.md](../AGENTS.md)：轻量化、模块职责清晰、行为模块对应测试，发行包排除开发依赖与测试数据。

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

测试入口不会自动下载或编译 KOReader。测试在临时配置中运行，不使用 `.dev/profile` 的登录数据。并存测试从 Git 历史提取固定 WeRead v1.6.0（`1f4861d3d66549c658e87d8aee96f8977863d836`），分别验证两种加载顺序；请使用完整 Git 历史，浅克隆需先补全历史。测试报告和渲染预览写入 `.dev/reports/`，不进入发行包。

- [原版 WeLite UI 精确迁移与像素验证](welite-ui-parity.md)
- [社区版功能评估与首次迁移记录](welite-migration.md)
- [模块与测试映射](../tests/module-map.json)
- [上游贡献指南](../CONTRIBUTING.md)

当前已验证桌面模拟器中的布局与交互，不代表 Kindle 真机性能验收。部分上游网络路径仍在 UI 线程执行；真实设备的耗时、内存、无线连接、休眠与墨水屏刷新仍需验证。

运行时模块位于 `welite/lib`、`welite/ui` 和 `welite/integrations`。版本和仓库身份由 `welite/identity.lua` 声明；`make check` 对所有运行时 Lua 模块检查测试映射，并拒绝旧 `weread.*` / `integrations.*` 导入。

配置迁移仅复制有大小上限的设置文件，不扫描或复制书籍目录。生产配置为 `settings/welite-state.lua`，模拟配置为 `settings/welite-mock-state.lua`，环境选项为 `settings/welite-environment.lua`；原配置保留。更新暂存和进度文件在 `welite/update`，已有下载、数据库、收藏和阅读状态继续使用兼容路径。

- [轻量化核心重构、同步审计与性能证据](lightweight-refactor.md)

发布使用本地完整测试与候选包验证，推送后保留快速 CI；固定 KOReader 集成只手动或定期运行。验证完成后直接上传已验证的包，不等待远端重复构建。具体步骤见 [发布流程](releasing.md)。
