#!/usr/bin/env python3
"""Install the current Debug build and open the two persistent network simulators."""
from test_two_simulators import ROOT, BUNDLE, command, simulator

app = ROOT / ".build/xcode-workspace/Build/Products/Debug-iphonesimulator/CouplePrivateSpace.app"
if not app.exists():
    raise SystemExit("请先构建 Debug App；命令见 README 的双模拟器章节。")
for name in ["我们 · A", "我们 · B"]:
    device = simulator(name, "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
    command("xcrun", "simctl", "install", device, str(app))
    command("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE)
command("open", "-a", "Simulator")
print("已打开 我们 · A / 我们 · B；请保持本地 Worker 运行。")
