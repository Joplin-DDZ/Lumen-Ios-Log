# Lumen · iPhone 日志工作台

macOS iPhone App 日志查看工具，重点改善 Xcode 控制台的阅读、筛选与会话管理体验。同时提供独立 Python 采集脚本和 Codex 技能，日志保存在本机。

## 主要功能

- 实时采集指定 App 的 stdout/stderr，完整展示多行日志，自动换行。
- 包含 / 排除关键词、正则过滤、全会话搜索、稳定多选复制。
- 自定义列显示、字体和浅色 / 深色外观。
- 会话自动保存、导入导出、右键删除，自动保留最新 100 份。
- 无 GUI 脚本采集，可作为 Codex 技能使用。

## 环境要求

- macOS 14 或更新版本。
- 完整 Xcode 15 或更新版本，Swift 5.10+，可运行 `xcrun devicectl`；新版本 iOS 需要相应版本的 Xcode。
- 通过 USB 连接、已解锁并信任 Mac 的 iPhone；开发 App 需满足开发者模式和签名要求。
- 使用脚本或运行脚本测试时需要 Python 3。

## 启动

克隆并在本机构建：

```bash
git clone https://github.com/Joplin-DDZ/Lumen-Ios-Log.git
cd Lumen-Ios-Log
bash scripts/build-app.sh release
open dist/Lumen.app
```

需要 macOS 14+。本地构建默认使用当前机器架构；`bash scripts/build-app.sh release universal` 可生成同时支持 Apple Silicon 与 Intel 的应用。当前采用临时签名，尚未进行 Developer ID 签名及公证。

## GitHub 自动打包与 Release

[下载 Release](https://github.com/Joplin-DDZ/Lumen-Ios-Log/releases)。下载 `Lumen-v版本-macOS-universal.dmg`，双击打开，将 `Lumen.app` 拖到镜像内的 `Applications`（应用程序）入口，完成后推出镜像。采集仍需本机安装完整 Xcode；当前未公证的包可能被 macOS 拦截，请先确认来源，再按系统「隐私与安全性」提示允许打开。

工作流 `.github/workflows/release.yml` 使用 GitHub macOS runner 测试并生成 Universal DMG 和 SHA-256 校验文件，无需自行配置服务器或 Apple 证书。

- 试打包：代码推送后，在 GitHub → Actions →「macOS 打包与发布」→ Run workflow。完成后在该次运行的 Artifacts 下载；保留 14 天，不自动发布 Release。GitHub 的 Artifacts 下载会额外套一层 ZIP；正式 Release 的 Assets 可直接下载 DMG。
- 正式发布：先提交并推送需要发布的代码，再推送 `v主版本.次版本.修订号` 标签，例如：

  ```bash
  git tag -a v1.3.0 -m "Lumen 1.3.0"
  git push origin v1.3.0
  ```

标签发布时 App 版本取自标签，构建号使用 Actions 运行编号。测试和双架构构建通过后，自动创建 Release 并上传 DMG、校验文件。重复发布同名附件会报错，不会静默替换已经下载的包；修复版本应使用新标签。手动分支构建默认版本为 1.3.0，供测试下载使用。

首次使用需允许仓库运行 GitHub Actions。发布任务使用内置 `GITHUB_TOKEN` 的 `contents: write` 权限，无需额外 PAT；仓库或组织策略若禁止该权限，需要管理员允许。Developer ID 签名与公证暂未接入。

本地制作同样的安装镜像：

```bash
bash scripts/build-app.sh release universal
bash scripts/package-dmg.sh
```

脚本从应用读取版本，检查双架构和签名后生成 DMG 与 `.dmg.sha256`，镜像只包含应用和安装入口。已发布的 v1.3.0 仍为 ZIP；新工作流发布的新标签使用 DMG。

## 脚本版与 Codex 技能

无需 GUI，直接运行 `./scripts/ios-logs.sh devices` 发现设备，`apps --device '<UDID>'` 查询 App，`capture --device '<UDID>' --bundle-id '<Bundle ID>' --restart-app --seconds 30 --output '<新目录>'` 重启目标并保存标准流。脚本只依赖 Python 3 和 Xcode。

`skills/ios-app-logs/` 为可独立安装的技能及采集实现，后续可用 `$ios-app-logs` 采集、定位 App 日志。使用边界、退出码和验证见 [脚本采集与技能](docs/script-capture.md)。

安装技能（目标目录尚不存在时）：

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R skills/ios-app-logs "${CODEX_HOME:-$HOME/.codex}/skills/ios-app-logs"
```

已有同名技能时，先比较内容再更新，避免覆盖自己的修改。

## 连接与采集

将 iPhone 连接电脑、解锁并信任电脑，开发 App 需满足开发者模式、签名及配对要求。点击「开始采集」，选择设备和 App。

工具只有 **App 控制台** 一种采集入口，读取所选 App 的 stdout/stderr：Swift.print、业务打印、KMP 输出以及写入标准流的 NSLog。不会启动设备系统日志流，也不展示旧版设备日志会话；旧会话同样受下述保留规则管理。

需要完整 Xcode 及可用的 `xcrun devicectl`，无需 libimobiledevice 来采集日志。点击「重启 App 并采集」会先结束该 App 的已有进程，再启动并接管标准流；这会结束原 Xcode 调试会话。无法事后接管由 Xcode 启动的既有进程 stdout，工具不会假装已附加成功。

停止采集只强制结束本工具创建的宿主读取器，不向目标 App 转发普通终止信号。断线或 App 退出后保存会话，不在后台自动重启 App。每次新采集重置旧筛选，避免业务日志被之前的系统分类条件隐藏；重新打开工具先显示明确的采集入口，历史需主动选择。

这是 App 标准输出控制台，不宣称覆盖 Xcode 调试器专有输出、所有 Unified Logging/Logger 或断点交互。App 内没有输出到 stdout/stderr 的日志无法由此通道恢复。App 自身 SDK 写入标准流的消息仍保留，与业务打印一起呈现，不用关键词猜测删除。

## 查看与整理

- 包含和排除关键词都支持英文逗号 `,`、中文逗号 `，` 或 `|` 分隔，可混用。包含命中任意一项即显示，排除命中任意一项即隐藏；两者同时填写时，排除优先。包含可启用正则，此时不拆分表达式；排除始终按普通文本匹配。
- 全会话文本搜索，回车/⌘G 下一个结果，⇧⌘G 上一个结果；搜索遵循当前筛选条件，覆盖未加载的页面。
- 日志页面每页最多 2,000 条；滚动离开底部或暂停只停止跟随，采集与保存继续。
- 右侧查看完整消息、JSON 格式化和上下文；支持多选与 ⌘C 复制。工具保留原文，级别解析为启发式结果。
- 日志区域使用离线 HTML 页面，支持浏览器原生字符选择：直接拖选、双击选词、跨列和跨日志连续选择，⌘C 或右键复制文字选区。普通点击只定位详情，不会闪现整行选区。
- 拖选与非空文字选区期间保持显示快照，后台继续采集保存；取消选区后显示最新数据。切换会话、搜索、翻页或回到最新日志时结束旧选区。Shift / ⌘ 点击可显式选择完整记录，使用 ⌘C 或「日志 → 复制选中的日志」复制完整原文。
- 收藏筛选、调整字体；列表直接展示完整消息，自动换行和调整行高，详情面板默认收起。清空视图（⌘K）保留已存日志。
- 搜索栏右侧「显示列」可逐项勾选 #、时间、级别、进程 / 分类、消息；取消勾选即隐藏，设置跨会话与重启保存。隐藏列不改变复制和导出的完整日志。
- 自动保存会话，重开后可读；导出全部或筛选结果为 TXT/JSONL，⌘O 导入 TXT/LOG/JSONL（最大 32 MiB）。
- 右击日志会话可选择「删除会话…」，确认后永久删除该会话的数据库记录与原始文件。正在采集或导入的会话不能删除；删除当前阅读会话会清空对应视图。
- 按创建时间自动保留最新 100 份会话（含导入与旧类型会话），活动会话优先占用保留名额；启动、创建/导入完成及采集结束时清理超额旧会话。需长期保留的日志请先导出到其他目录。
- 侧栏底部切换浅色/深色/跟随系统，自动记住外观选择。

## 本地数据与边界

日志仅写入 `~/Library/Application Support/Lumen/`：`sessions.sqlite` 保存索引及结构化记录，`Sessions/<会话ID>/stdout.log` 和 `stderr.log` 保存原始流；导入文件另存副本。目录权限为 0700。原始日志可能含业务凭据，导出分享前请自行检查。

单次原始流上限 256 MiB，全部存储达到 2 GiB 后阻止新采集。单条展示记录超过约 512 KiB 时截断并提示，完整接收字节仍在原始文件中。搜索最多返回前 100,000 个匹配位置；正则每条记录设约 30 ms 预算，超时视作不匹配，复杂表达式应简化后重试。工具无法恢复 App 未输出、系统隐私隐藏、采集开始前或断线期间的日志，不承诺严格零丢失。

文件清理失败时会保留待清理项，下次启动继续处理；数据库删除释放的页由 SQLite 复用，数据库文件大小不保证立即缩小。独立脚本输出目录不属于桌面会话库，不参与 100 份保留清理。

当前未提供崩溃报告下载、App 历史文件提取、网络抓包或跨设备合并。实际 USB 拔插、Wi-Fi、多设备及更多系统版本尚未完成实机矩阵验证。

## 开发与验证

```bash
swift test
python3 tools/test_ios_logs.py
bash scripts/build-app.sh release
```

无第三方 Swift 包依赖，使用系统 SQLite。可用 `LUMEN_DATA_DIR=/绝对路径 .build/debug/Lumen` 隔离开发数据。

- [App 控制台修正验证](docs/console-only-validation.md)
- [脚本采集与技能](docs/script-capture.md)
- [架构与维护](docs/architecture.md)
- [桌面工具验证](docs/desktop-validation.md)
- [采集通道真机验证](docs/capture-validation.md)
- [采集原型脚本](tools/validate_capture.py)

原始证据位于忽略的 `artifacts/`，不提交本地日志。
