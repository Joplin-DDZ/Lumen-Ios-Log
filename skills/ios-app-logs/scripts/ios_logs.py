#!/usr/bin/env python3
"""通过 Xcode devicectl 读取指定 iOS App 标准流；不依赖 Lumen 界面或第三方 Python 包。"""
import argparse
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone


class CaptureError(Exception):
    """可直接向调用者展示的采集或设备错误。"""


def emit(value):
    """stdout 仅输出结构化结果，诊断写入 stderr。"""
    print(json.dumps(value, ensure_ascii=False, indent=2), flush=True)


def diagnostic(message):
    print(f"[iOS 日志] {message}", file=sys.stderr, flush=True)


def find_xcrun():
    tool = shutil.which("xcrun")
    if not tool:
        raise CaptureError("未找到 xcrun，请安装并选择完整 Xcode。")
    return tool


def device_json(tool, arguments):
    """发现命令只读取官方 JSON 文件，不解析面向人的表格。"""
    with tempfile.TemporaryDirectory(prefix="ios-logs-discovery-") as directory:
        target = Path(directory) / "result.json"
        result = subprocess.run([tool, "devicectl", *arguments, "--timeout", "8", "--quiet",
                                 "--json-output", str(target)], capture_output=True, timeout=12)
        if result.returncode:
            # 错误只截取有限长度；发现阶段不包含 App 日志正文。
            raise CaptureError("设备命令失败：" + result.stderr.decode("utf-8", errors="replace")[-1500:])
        try:
            root = json.loads(target.read_text())
            if not isinstance(root.get("result"), dict):
                raise ValueError("缺少 result")
            return root["result"]
        except (OSError, ValueError) as error:
            raise CaptureError(f"设备 JSON 无法读取：{error}") from error


def list_devices(tool):
    devices = []
    for item in device_json(tool, ["list", "devices"]).get("devices", []):
        hardware = item.get("hardwareProperties", {})
        if hardware.get("platform") != "iOS":
            continue
        properties = item.get("deviceProperties", {})
        devices.append({"device": hardware.get("udid") or item.get("identifier"),
                        "name": properties.get("name", "iPhone"),
                        "ios_version": properties.get("osVersionNumber", ""),
                        "connected": item.get("connectionProperties", {}).get("tunnelState") == "connected"})
    return {"devices": sorted(devices, key=lambda item: not item["connected"])}


def list_apps(tool, device, match):
    apps = []
    for item in device_json(tool, ["device", "info", "apps", "--device", device]).get("apps", []):
        bundle = item.get("bundleIdentifier")
        name = item.get("name", bundle or "")
        if bundle and (not match or match.casefold() in f"{name} {bundle}".casefold()):
            apps.append({"bundle_id": bundle, "name": name, "version": item.get("version", "")})
    return {"device": device, "apps": sorted(apps, key=lambda item: item["name"].casefold())}


def console_command(tool, device, bundle):
    """重启是接管 stdout 的前提，调用入口必须显式确认该选项。"""
    return [tool, "devicectl", "device", "process", "launch", "--device", device,
            "--quiet", "--console", "--terminate-existing", bundle]


def capture(args, tool):
    """双管道持续落盘；限时、限量或中断时仅 SIGKILL 宿主读取器并排空尾部。"""
    output = args.output.expanduser().resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    started_at = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    requested_stop = []
    previous_handlers = {}
    child = None
    selector = selectors.DefaultSelector()
    counts = {"stdout": 0, "stderr": 0}
    budget = int(args.max_mib * 1024 * 1024)
    reason = "source_ended"
    drain_deadline = None
    drain_complete = True
    failure = None

    def request_stop(signum, _frame):
        # 普通信号在父脚本消费，不能转发给 devicectl 或整个进程组。
        requested_stop.append(signum)

    def stop_reader(stop_reason):
        nonlocal reason, drain_deadline
        if drain_deadline is not None:
            return
        reason = stop_reason
        drain_deadline = time.monotonic() + 3
        if child.poll() is None:
            child.kill()
        diagnostic(f"停止宿主读取器：{stop_reason}，目标 App 不接收终止信号")

    diagnostic("即将重启指定 App 并接管标准流；原始日志仅保存在本机")
    try:
        with (output / "stdout.log").open("xb") as stdout, (output / "stderr.log").open("xb") as stderr:
            for name in ("stdout.log", "stderr.log"):
                os.chmod(output / name, 0o600)
            for signum in (signal.SIGINT, signal.SIGTERM):
                previous_handlers[signum] = signal.signal(signum, request_stop)
            # 独立会话隔离终端 Ctrl-C，避免 Xcode 工具将信号转发给 iPhone App。
            child = subprocess.Popen(console_command(tool, args.device, args.bundle_id),
                                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
            for pipe, stream, target in ((child.stdout, "stdout", stdout), (child.stderr, "stderr", stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, (stream, target))
            while selector.get_map() or child.poll() is None:
                now = time.monotonic()
                if requested_stop:
                    stop_reader("interrupted")
                elif now - started >= args.seconds:
                    stop_reader("duration")
                if drain_deadline is not None and now >= drain_deadline:
                    drain_complete = not selector.get_map()
                    break
                for key, _ in selector.select(0.1):
                    try:
                        chunk = os.read(key.fd, 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    stream, target = key.data
                    remaining = max(0, budget - sum(counts.values()))
                    part = chunk[:remaining]
                    target.write(part)
                    target.flush()
                    counts[stream] += len(part)
                    if len(chunk) >= remaining:
                        stop_reader("size_limit")
            child.wait(timeout=3)
    except Exception as error:
        failure = str(error)
        reason = "error"
        diagnostic(f"采集异常：{error}")
    finally:
        if child is not None:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
            for pipe in (child.stdout, child.stderr):
                if pipe:
                    pipe.close()
        selector.close()
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    received = sum(counts.values()) > 0
    # 主动终止的 -9 属于预期；工具自然非零退出必须报错，即便已产生部分输出。
    tool_failed = child is not None and reason == "source_ended" and child.returncode != 0
    exit_code = 1 if failure or tool_failed or not drain_complete else (0 if received else 3)
    summary = {"device": args.device, "bundle_id": args.bundle_id, "output": str(output),
               "started_at_utc": started_at, "elapsed_seconds": round(time.monotonic() - started, 3),
               "stop_reason": reason, "reader_return_code": child.returncode if child else None,
               "stdout_bytes": counts["stdout"], "stderr_bytes": counts["stderr"],
               "received_output": received, "drain_complete": drain_complete,
               "truncated": reason == "size_limit", "exit_code": exit_code,
               "files": {"stdout": str(output / "stdout.log"), "stderr": str(output / "stderr.log")},
               "note": "stderr 也可能含工具错误；收到字节不证明业务标记齐全，也不等价于所有 Xcode 调试输出。"}
    if failure:
        summary["error"] = failure
    target = output / "summary.json"
    target.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    os.chmod(target, 0o600)
    emit(summary)
    diagnostic("采集结束，原始日志与摘要已保存" if exit_code == 0 else "采集未成功，请检查摘要和 stderr.log")
    return exit_code


def positive_number(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("必须是大于零的有限数值")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("devices", help="列出 iPhone 与连接状态，JSON 输出")
    apps = commands.add_parser("apps", help="列出指定设备安装的 App")
    apps.add_argument("--device", required=True)
    apps.add_argument("--match", default="", help="按名称或 Bundle ID 过滤")
    run = commands.add_parser("capture", help="重启指定 App 并限时采集")
    run.add_argument("--device", required=True)
    run.add_argument("--bundle-id", required=True)
    run.add_argument("--restart-app", action="store_true", help="明确允许本次重启目标 App，采集必需")
    run.add_argument("--seconds", type=positive_number, default=30, help="总时长含启动，默认 30 秒")
    run.add_argument("--max-mib", type=positive_number, default=32, help="双流合计容量上限，默认 32 MiB")
    run.add_argument("--output", type=Path, required=True, help="必须是尚不存在的新目录")
    args = parser.parse_args(argv)
    if args.command == "capture" and not args.restart_app:
        parser.error("接管标准流需要重启 App；明确允许后传入 --restart-app")
    if args.command == "capture" and args.max_mib * 1024 * 1024 < 1:
        parser.error("容量至少为 1 字节")
    if args.command == "capture" and (args.seconds > 3600 or args.max_mib > 1024):
        parser.error("单次采集最多 3600 秒、1024 MiB；需要更长时间请分段采集")
    try:
        tool = find_xcrun()
        if args.command == "devices":
            emit(list_devices(tool))
        elif args.command == "apps":
            emit(list_apps(tool, args.device, args.match))
        else:
            return capture(args, tool)
        return 0
    except (CaptureError, OSError, subprocess.SubprocessError) as error:
        diagnostic(str(error))
        emit({"error": str(error), "exit_code": 1})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
