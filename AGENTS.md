# Lumen 日志工作台

独立 SwiftPM 原生 macOS 项目，自己的 Git 仓库。不得修改相邻 iOS/shared 项目来迁就本工具。

## 文档地图

- `README.md`：构建、使用、依赖、容量和已知边界。
- `docs/script-capture.md`：独立脚本入口、技能源与安装副本、输出契约和验证。
- `docs/README.md`：文档索引。
- `docs/architecture.md`：模块边界、采集生命周期及持久化。
- `docs/desktop-validation.md`：初版桌面工具验证结果。
- `docs/console-only-validation.md`：仅采集 App 控制台的修正及验收。
- `docs/capture-validation.md`：采集通道真机验证与技术选择。

## 开发约束

关键 API、并发边界、字段和业务逻辑使用中文注释；关键节点与错误使用中文诊断日志，不打印凭据或日志正文。模型、枚举、服务分别独立文件。

采集与停止只管理自身创建的进程。唯一入口读取 App stdout/stderr，按钮必须明确说明重启目标 App；普通信号会由 devicectl 转发给目标 App，停止宿主读取器使用不可转发的 SIGKILL。不得新增或恢复设备系统日志采集入口，不读取旧版 captureMode 偏好。旧设备会话仅兼容解码，不在工作区展示。

日志解析失败时保留原文；UTF-8 必须跨管道字节分段解码。多行更新同一 ID，存储使用 upsert。UI 不执行阻塞采集、设备命令或数据库扫描。不得提交 `artifacts/`、`dist/`、原始日志或本机数据库。

大幅代码、公共 API 或配置修改后执行 `swift test` 与 `bash scripts/build-app.sh release`；文档和小样式变更只做局部核对。交互变化需核对实际原生窗口，不能以编译通过代替界面验证。
