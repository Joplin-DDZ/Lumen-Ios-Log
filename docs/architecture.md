# 架构与维护

## 模块

- `Models/`：日志、会话、设备、采集配置、状态和筛选值类型。
- `Models/LogColumn.swift`：列的稳定标识与菜单标题；显示偏好以 `hiddenLogColumns` 保存于 UserDefaults，HTML 页隐藏相应列但不删除原始数据，正文重新显示时恢复全文排版；列宽拖动在页面内保留。
- `Services/DeviceService.swift`：actor，读取 devicectl 官方 JSON；缺少 Xcode 时尝试 libimobiledevice 发现设备。
- `Services/CommandRunner.swift`：后台短命令、并行消费 stdout/stderr、超时清理。
- `Services/CaptureService.swift`：串行队列管理本工具的读取器、原始文件、双管道解析与批量事件。
- `Services/UTF8LineDecoder.swift`：跨分块 UTF-8 解码及超长行保护。
- `Services/LogParser.swift`：设备头、LOOI 业务头和 KMP 头识别，多行续写不换 ID。
- `Services/SessionStore.swift`：SQLite actor；会话元数据、记录 upsert、分页、筛选搜索、流式导出。
- `Services/LogImporter.swift`：后台读取有限大小的 TXT/LOG/JSONL。
- `AppModel.swift`：MainActor 交互状态、采集生命周期、设备发现轮询、查询版本与导航。
- `Views/`：SwiftUI 面板与主题，日志区域由 `LogTableView` 嵌入离线 WKWebView。
- `Views/LogWebDocument.swift`：连续 HTML 表格，浏览器原生文字选区支持跨列、跨记录复制；普通点击只定位详情，修饰键显式选择完整记录。使用 CSS 完整换行、紧凑列宽、列宽调整、搜索高亮及滚动锚点。
- `Views/LogTableView.swift`：桥接模型与页面。结构化参数传递日志，DOM 仅用 textContent / 文本节点显示正文；非持久 WebKit 数据存储、CSP 禁止网络资源，导航仅允许 about:blank。主框架事件只传选择状态及必要的记录快照，不打印日志正文。
- `LumenApp.swift` / `AppDelegate.swift`：菜单命令、退出清理和窗口重开。
- `skills/ios-app-logs/scripts/ios_logs.py`：不依赖 GUI 的独立 Python 采集器，与桌面版使用相同 devicectl 控制台参数，原始双流落盘并输出 JSON 摘要。仓库入口为 `scripts/ios-logs.sh`，用户技能安装后可独立运行；输出契约见 [脚本采集与技能](script-capture.md)。

## 数据流

App stdout/stderr → 原始字节落盘 → 每个管道独立解码和解析 → 约 150 ms 批量事件 → 数据库 upsert → 120 ms 合并刷新 → 当前 2,000 条页面。

UI 查询携带修订号，陈旧结果不会覆盖新条件。输入后立即回车时保存待执行方向，等相应会话、搜索词和筛选快照完成后再导航。全文搜索独立于当前页面。

HTML 页面在鼠标拖选或非空文字选区期间不替换 DOM，只保留最新待显示快照，后台采集与保存继续。取消选区后应用最新快照；主动切换会话、筛选、分页、搜索目标或恢复跟随时结束旧选区。字符复制使用 WebKit 原生行为，完整记录复制使用显示时的原文快照；普通单击不绘制整行选中背景。

暂停滚动只影响导航；浏览历史不停止活动采集。清空视图设置 ID 下界，数据库不删除记录。导出在数据库 actor 内固定最大 ID，分批写临时文件，再替换目标文件。

会话删除在存储 actor 内用同一事务删除元数据、记录并写入 `pending_session_deletions`，提交后删除 `Sessions/<ID>`，成功后移除待清理项。文件错误或进程退出留下的待清理项在下次启动重试；数据库事务失败会回滚，不删除原始文件。删除路径校验限制在会话目录，拒绝目录穿越和 Sessions 父目录符号链接。

刷新会话时按创建时间保留最新 100 份，时间相同时按 ID 确定顺序。导入和旧设备会话共同计数；活动采集、创建/导入中的 ID 及「采集中」元数据优先保留，占用名额。若受保护会话超过上限，暂时保留全部受保护项，结束后再收敛。删除当前阅读会话会取消陈旧查询、清空记录和复制状态；其他会话与采集不受影响。右键删除需界面确认，自动保留清理不逐条确认。规则适用桌面数据库，不扫描独立脚本输出目录。

## 生命周期与故障

启动保存会话和配置，再创建读取器。停止时排空双管道、刷新尾部记录，最后保存会话状态。应用退出先请求停止并等待结束；异常退出后再次启动将残留「采集中」元数据恢复为「已保存」。

唯一采集命令由 `ConsoleCommand` 构造：`devicectl device process launch --quiet --console --terminate-existing`，只连接所选 App 的标准流，quiet 抑制工具状态。界面重启按钮明确提示会结束原调试会话。不存在设备日志入口和按旧偏好回退的路径。停止仅 SIGKILL 宿主读取器，等 stdout/stderr 两条管道 EOF 与进程退出均到达后刷新尾部再归档，不使用固定延时猜测排空。

`CaptureMode.device` 仅保留历史数据解码兼容。会话列表通过 `LogSession.isConsoleVisible` 隐藏旧设备会话，用户主动导入的文件仍可读。重新启动不自动打开历史；新采集清空筛选。console 不能事后附加既有 stdout，不会在后台自动重启目标。

原始流容量、全部存储预检和展示记录长度分别有限制，具体值以 README 和实现为准。磁盘写入失败停止读取并展示错误；采集不上传数据。

## 分发

SwiftPM 构建单个可执行文件，脚本生成图标、Info.plist 并临时签名。当前使用机器上的 Xcode，不内置这些工具。Developer ID、公证、自动更新和多架构产物为后续发行工作。
