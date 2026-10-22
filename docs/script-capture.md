# 脚本采集与技能

## 命令入口

桌面版继续独立运行；脚本版不需要启动 GUI 或编译 Swift。需要 macOS、Python 3、已选择的完整 Xcode、已信任且可用于开发的 iPhone。

```bash
./scripts/ios-logs.sh devices
./scripts/ios-logs.sh apps --device '<设备 UDID>' --match 'LOOI'
./scripts/ios-logs.sh capture --device '<设备 UDID>' \
  --bundle-id '<查询返回的 Bundle ID>' --restart-app \
  --seconds 30 --max-mib 32 --output '/绝对路径/新的采集目录'
```

前两条只读且返回 JSON。最后一条会重启目标 App、结束旧 Xcode 调试会话，并连接其 stdout/stderr。`--restart-app` 为必填显式选项，不能补接已经运行进程的历史输出，不提供系统日志回退。总时长含 App 启动，默认 30 秒；默认双流合计最多 32 MiB，最多可设置 3600 秒和 1024 MiB。

新输出目录权限 0700，`stdout.log`、`stderr.log`、`summary.json` 权限 0600。不覆盖既有目录。两个日志文件保存字节原文，不截首行，不拆分/裁剪多行消息；容量限制可能截断最后一个 UTF-8 字符，摘要会报告 `truncated=true`。stdout 最终输出 JSON 摘要，中文运行诊断输出到 stderr，业务正文不主动回显到终端。

采集过程中可中断父脚本。独立进程会话隔离终端 Ctrl-C；脚本捕获 SIGINT/SIGTERM，仅 SIGKILL 自己启动的 devicectl，随后并行排空双流，最长等待 3 秒。不要向 devicectl 发送普通信号，也不要 SIGKILL 父脚本；前者可能结束目标 App，后者无法归档摘要。脚本不后台自动重启或重连 App。

退出码：0 表示收到输出且无采集异常，1 表示工具/IO/排空异常，2 表示参数错误，3 表示零输出。stderr 可能包含工具错误，字节数不等于目标业务验证成功。需用摘要的工具退出码、停止原因、排空状态及预期业务标记共同判断。

## 技能

可维护源位于 `skills/ios-app-logs/`，自包含 `SKILL.md`、展示元数据及唯一采集实现 `scripts/ios_logs.py`。仓库的 `scripts/ios-logs.sh` 只转发到此实现。安装到用户 `~/.codex/skills/ios-app-logs/` 后，可在其他工作区独立使用；修改源后需同步安装副本。若设置了 `CODEX_HOME`，使用该目录下的 `skills/`。

后续可直接说「用 ios-app-logs 抓取指定 iPhone 上 LOOI 的日志 30 秒」，或显式调用 `$ios-app-logs`。技能先发现设备和 App，取得本次重启授权后采集，再局部搜索输出文件定位问题。

## 验证

```bash
python3 tools/test_ios_logs.py
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py" skills/ios-app-logs
```

7 项脚本测试通过，覆盖双流与逐字节中文、无换行尾部、超时停止、中断、容量限制、自然退出、启动失败、零输出、参数边界、显式重启参数和已有目录保护。技能源和用户安装副本均通过技能校验，安装副本的设备发现命令运行成功。真实设备只读验证发现 1 台已连接 iPhone，并查询到 LOOI 的 Bundle ID；本轮未重启真实 App，命令行实机采集完整性尚未单独验收，通道沿用桌面版已验证的命令。本次未改动桌面版 Swift 代码，未重复构建 GUI。
