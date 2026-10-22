# 采集验证：2026-10-21

## 结论

USB 真机采集可行。针对现有 LOOI 的 Xcode 控制台替代场景，首选 `devicectl --console`
启动模式采集 stdout/stderr；用 `os_trace_relay` 补充运行中 App 的设备日志。
不能仅使用 idevicesyslog 就宣称能读取全部 Xcode 输出。

## 实测环境

- Apple Silicon Mac，macOS 26.5.2，Xcode 26.5（17F42）。
- USB 连接的 iPhone 13，iOS 26.6.2。
- 已安装 LOOI 2.9.2（1），Bundle ID `com.TangibleFuture.looiRobot`。
- Homebrew `idevicesyslog 1.4.0`。
- 起始进程 PID 15800，由 Xcode 调试运行；console 启动后 PID 15847。

## 已完成测试

### 设备日志通道

通过 Xcode LLDB 执行纯日志表达式，不修改 App 源码：

```text
expression -l Swift -- Swift.print("LOOI_CAPTURE_PRINT_20261021 中文测试\n第二行 {\"ok\":true}")
expression -l objc++ -- extern void NSLog(id, ...); NSLog(@"LOOI_CAPTURE_NSL_20261021 中文测试\n第二行 {\"ok\":true}")
```

两条采集器在同一个 120 秒窗口内并行运行；Swift.print 已通过 Xcode 控制台确认实际输出。

| 检查项 | os_trace_relay | syslog_relay |
| --- | --- | --- |
| NSLog 唯一标记 | 1 次 | 1 次 |
| Swift.print 唯一标记 | 0 次 | 0 次 |
| 中文内容 | 保留原字符 | 变为 `\\M-` 等转义文本 |
| 多行 JSON | 保留换行和 JSON | 有续行，但中文转义 |
| 采集记录数（按日志头统计） | 256 | 56 |
| 原始 stdout 字节数 | 59,363 | 11,901 |
| 级别 | Notice / Debug / Info | Notice |

不同通道记录数差异不代表已测得丢包率；来源、级别和过滤行为不同。
UTF-8 解码成功也不代表中文正常，legacy 输出是合法 ASCII 转义文本。
设备日志能够与 Xcode 调试并行工作。探针结束后恢复了 App 执行。

证据：`artifacts/verified-trace/` 和 `artifacts/verified-legacy/`。
更早的 `artifacts/probe-*` 为探路会话，部分表达式导入/输入失败，不作为 NSLog 标记成功证据。
未单独执行 Logger/os_log、LIPrint、recordLog 唯一标记，不能将对应标记的 0 次解释为丢失。

### 现有 App 标准输出

使用本机 Xcode 的官方命令，主动结束旧进程并启动已安装 App：

```text
xcrun devicectl device process launch --device <UDID> --terminate-existing --console com.TangibleFuture.looiRobot
```

35 秒采集窗口读取到：

- stdout 113,743 字节、1,124 行；stderr 2,686 字节，均可严格 UTF-8 解码。
- `KMP[` 出现 117 次，`[Main] info` 91 次，`[BG] info` 25 次。
- `[AUDIO-HUB]` 13 次，`BODY START` 38 次，`BODY END` 35 次。
- 中文、业务日志、KMP 多行网络输出均存在，未改日志入口、未重新编译或安装 App。
- 采集结束时 SIGKILL 只停止本次宿主 devicectl；随后 pidlist 确认 App 仍在运行。

BODY 标记数量不一致，可能包含窗口边缘、不完整请求或截断；本次未逐请求核对，不声称零丢失。
退出码 -9 是主动结束宿主读取器，不能据此判断 App 崩溃。
证据：`artifacts/console-launch/`。本次重启结束了原 Xcode 调试会话，未自动重新附加调试器。

## LOOI 日志入口核对

`looirobotios/Tools/LIGlobal.swift:78` 的 LIPrint 在非 release 环境最终调用 Swift.print。
`looirobotios/Tools/Log/LILogTool.swift:62` 的 logMessage 调用 LIPrint 并写入文件缓存，
`recordLog`（498 行）通过此入口执行。由源码可以解释设备日志通道为什么无法代替这些标准输出。
Release 环境的 LIPrint 本身不输出；采集工具不能恢复从未产生的 stdout。
App 内已有日志文件不等于系统日志，后续若支持历史文件需独立实现文件读取。

## 技术决策

1. 提供「设备日志」和「启动并采集」两种清楚区分的模式。
2. 现有 LOOI 首选启动并采集，保留原 App 日志实现；同时读取 stdout 和 stderr。
3. 用户选择启动模式时，明确是否需要重启 App；不能无提示地终止已有调试进程。
4. 默认设备日志后端采用 trace；legacy 作为诊断对照，不作为中文日志默认通道。
5. 正式分发时，设备日志模式评估打包 libimobiledevice；启动模式需要 Xcode 工具链。
6. 日志包含多行，不能用“每行一条”模型；保留原文，解析失败时降级展示。

## 原型脚本复验

`tools/validate_capture.py` 已提供 trace、legacy、console 模式，记录原始 stdout/stderr、容量上限和标记计数。
首次 console 取证使用独立 Python 调用；统一脚本的 console 路径在其后单独复验：
15 秒内 stdout 113,353 字节、1,178 行，stderr 2,555 字节，匹配 `KMP[` 117 次、
`[Main] info` 82 次。脚本退出码 0，宿主采集进程退出码 -9 为预期的主动停止。
停止后确认 App PID 15888 仍在运行。证据位于 `artifacts/console-script-check/`。
console 的 `record_count=0` 仅表示没有设备日志格式的行头，不能用作该模式是否成功的判断。

## 尚未验证

- 实际 USB 拔插、锁屏重连、Wi-Fi、多设备和其他 iOS/macOS 版本。
- 按进程名过滤是否跨 App PID 变化持续工作；不能仅凭参数名宣称支持自动跟随重启。
- console 模式重新连接已运行进程的标准输出；本机 help 明确标准流连接以 App 尚未运行为前提。
- 30 分钟压力测试、持续高流量、严格日志完整性、不同系统下的退出策略。
- Logger 各级别、隐私字段、第三方 SDK 输出、崩溃日志与历史文件读取的独立测试矩阵。

本次 Mobile Dev 辅助设备发现因本机 devicectl 不支持 `--omit-deprecated-fields-in-json` 失败，
未使用或修改该插件后端。项目原型直接验证本机目标 CLI，不依赖该辅助功能。

## 验证范围

本次没有修改 iOS 或 shared 项目源码，也没有运行其构建。新建了独立采集原型和本地证据，
对脚本进行了真实设备运行验证；完整 GUI 与正式分发均不在本阶段。
