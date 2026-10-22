#!/usr/bin/env python3
"""限时采集指定 iPhone 进程的日志，保存原文及可复核的统计结果。"""

import argparse
import codecs
import json
import re
import selectors
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def main():
    """执行单次采集；无日志不视为成功，测试标记只统计、不打印日志正文。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="USB 设备的硬件 UDID")
    parser.add_argument("--process", default="looiRobot", help="目标进程可执行文件名")
    parser.add_argument("--backend", choices=["trace", "legacy", "console"], default="trace")
    parser.add_argument("--bundle-id", help="console 模式启动的 App Bundle ID")
    parser.add_argument("--restart-app", action="store_true", help="console 模式结束已有 App 进程并重新启动")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--max-mib", type=float, default=32)
    parser.add_argument("--marker", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.seconds <= 0 or args.max_mib <= 0:
        parser.error("采集时长和容量必须大于零")
    if args.backend == "console" and (not args.bundle_id or not args.marker):
        parser.error("console 模式必须提供 --bundle-id 和至少一个已知 App 输出 --marker")
    if args.restart_app and args.backend != "console":
        parser.error("--restart-app 仅适用于 console 模式")
    tool = shutil.which("xcrun" if args.backend == "console" else "idevicesyslog")
    if not tool:
        parser.error("未找到采集工具：console 需要 Xcode，trace/legacy 需要 libimobiledevice")
    # 独立目录避免覆盖历史证据，日志原文只保存在本机。
    args.output.mkdir(parents=True, exist_ok=False)
    command = [tool, "-u", args.udid, "--no-colors", "-x", "-p", args.process]
    if args.backend == "console":
        # 标准流只能在启动时接管；已运行的 App 不保证能被接管，重启必须显式选择。
        command = [tool, "devicectl", "device", "process", "launch", "--device", args.udid, "--console"]
        if args.restart_app:
            command.append("--terminate-existing")
        command.append(args.bundle_id)
    elif args.backend == "legacy":
        command.append("--syslog-relay")
    started_at = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    reason = "duration"
    print(f"开始采集：backend={args.backend} process={args.process}", flush=True)
    # stdout/stderr 同时消费，避免错误输出堵住采集子进程。
    with (args.output / "raw.log").open("wb") as raw, (args.output / "stderr.log").open("wb") as errors:
        # 独立进程组防止终端 Ctrl-C 绕过本程序，直接传到 devicectl 并再转发给 App。
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 stdin=subprocess.DEVNULL, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(child.stdout, selectors.EVENT_READ, raw)
        selector.register(child.stderr, selectors.EVENT_READ, errors)
        size = 0
        try:
            while selector.get_map():
                remaining = args.seconds - (time.monotonic() - started)
                if remaining <= 0:
                    break
                for key, _ in selector.select(min(remaining, 0.25)):
                    chunk = key.fileobj.read1(65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    budget = max(0, int(args.max_mib * 1024 * 1024) - size)
                    key.data.write(chunk[:budget])
                    key.data.flush()
                    size += len(chunk[:budget])
                    if len(chunk) >= budget:
                        reason = "size_limit"
                        break
                if reason == "size_limit":
                    break
            else:
                reason = "source_ended"
        except KeyboardInterrupt:
            reason = "interrupted"
        finally:
            # devicectl 会把普通信号转发给 App；console 仅强制停止宿主读取器。
            # idevicesyslog 正常退出时刷新用户态缓冲，不影响目标 App。
            if child.poll() is None:
                if args.backend == "console":
                    child.kill()
                else:
                    child.send_signal(signal.SIGINT)
            try:
                tail, error_tail = child.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                tail, error_tail = child.communicate()
            for target, chunk in [(raw, tail), (errors, error_tail)]:
                budget = max(0, int(args.max_mib * 1024 * 1024) - size)
                target.write(chunk[:budget])
                size += len(chunk[:budget])
                if len(chunk) > budget:
                    reason = "size_limit"
            selector.close()
    data = (args.output / "raw.log").read_bytes()
    text = data.decode("utf-8", errors="replace")
    error_text = (args.output / "stderr.log").read_text(errors="replace")
    # 保留原文；头部匹配只用于统计，不将多行消息的续行误判为新记录。
    header = re.compile(r"^\w{3}\s+\d+\s+\d\d:\d\d:\d\d.*?\[(\d+)\].*?<([^>]+)>:", re.MULTILINE)
    records = header.findall(text)
    levels = {}
    for _, level in records:
        levels[level] = levels.get(level, 0) + 1
    try:
        codecs.decode(data, "utf-8", "strict")
        valid_utf8 = True
    except UnicodeDecodeError:
        valid_utf8 = False
    summary = {
        "started_at_utc": started_at,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "command": command,
        "backend": args.backend,
        "stop_reason": reason,
        "return_code": child.returncode,
        "raw_bytes": len(data),
        "line_count": len(text.splitlines()),
        "record_count": len(records),
        "process_ids": sorted(set(pid for pid, _ in records)),
        "levels": levels,
        "valid_utf8": valid_utf8,
        "marker_occurrences": {marker: text.count(marker) for marker in args.marker},
        "stderr_marker_occurrences": {marker: error_text.count(marker) for marker in args.marker},
        "stderr_bytes": (args.output / "stderr.log").stat().st_size,
        "note": "采集到日志仅代表通道可用；完整性必须对照已知测试标记判断。",
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    has_console_marker = args.backend == "console" and any(marker in text or marker in error_text for marker in args.marker)
    return 0 if records or has_console_marker else 2


if __name__ == "__main__":
    raise SystemExit(main())
