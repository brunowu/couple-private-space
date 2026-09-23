#!/usr/bin/env python3
"""Run the real app on two independent iOS simulators against the local Worker.

Only public handshake payloads pass through this script; each simulator creates and
retains its own Keychain identity and SQLCipher database. Does not erase devices.
"""
import argparse
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLE = "private.couple.space.development"

def command(*args):
    return subprocess.check_output(list(args), text=True).strip()

def simulator(name, runtime):
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    found = next((d for d in devices.get(runtime, []) if d["name"] == name), None)
    if found is None:
        identifier = command("xcrun", "simctl", "create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", runtime)
    else:
        identifier = found["udid"]
    if found is None or found["state"] != "Booted":
        command("xcrun", "simctl", "boot", identifier)
    command("xcrun", "simctl", "bootstatus", identifier, "-b")
    return identifier

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:8787")
    parser.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-18-6")
    parser.add_argument("--app", default=str(ROOT / ".build/xcode-workspace/Build/Products/Debug-iphonesimulator/CouplePrivateSpace.app"))
    parser.add_argument("--a-name", default="我们 · A")
    parser.add_argument("--b-name", default="我们 · B")
    parser.add_argument("--capture-affection", action="store_true", help="Capture the normal receiver UI for visual inspection")
    options = parser.parse_args()
    a = simulator(options.a_name, options.runtime)
    b = simulator(options.b_name, options.runtime)
    print(f"A={a}\nB={b}", flush=True)
    containers = {}
    for device in [a, b]:
        command("xcrun", "simctl", "install", device, options.app)
        containers[device] = pathlib.Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))

    def step(device, action, payload=""):
        marker = str(uuid.uuid4())
        args = ["xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE,
                "--network-smoke", "--step", action, "--run-id", marker, "--endpoint", options.endpoint]
        if payload:
            args.extend(["--payload", payload])
        command(*args)
        output = containers[device] / "Documents/network-smoke.json"
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if output.exists():
                report = json.loads(output.read_text())
                if report.get("runID") == marker:
                    if report["error"]:
                        raise RuntimeError(f"{action}: {report['error']}")
                    print(f"{'A' if device == a else 'B'} {action}: {report['stage']}; messages={report['messages']}, wishes={report['wishes']}, pending={report['pending']}", flush=True)
                    return report
            time.sleep(0.25)
        raise TimeoutError(f"No app response for {action}")

    def drain(max_rounds=12):
        """Allow queued offline events and their encrypted receipts to cross both ways."""
        for _ in range(max_rounds):
            left = step(a, "sync")
            right = step(b, "sync")
            left = step(a, "sync")
            if left["pending"] == right["pending"] == 0:
                return left, right
        raise AssertionError(f"Outbox did not settle: A={left['pending']} B={right['pending']}")

    sa, sb = step(a, "status"), step(b, "status")
    if sa["stage"] in ["new", "creating"]:
        sa = step(a, "create")
    if sb["stage"] in ["new", "joining"]:
        sb = step(b, "join", sa["output"])
    if sa["stage"] in ["invited", "confirming"]:
        sa = step(a, "respond", sb["output"])
    if sb["stage"] in ["responded", "confirming"]:
        sb = step(b, "final", sa["output"])
    if sa["stage"] == "awaitingPeer":
        sa = step(a, "status")
    assert sa["stage"] == sb["stage"] == "paired"
    assert sa["localID"] != sb["localID"]
    # Existing devices may have queued work from manual testing or an interrupted run.
    # Drain it before taking baselines; never clear either device's database.
    sa, sb = drain()
    before_messages, before_wishes = sb["messages"], sa["wishes"]
    step(a, "message")  # persist without uploading
    assert step(b, "status")["messages"] == before_messages
    step(a, "sync")
    assert step(b, "sync")["messages"] == before_messages + 1
    drain()
    step(b, "wish")  # process is terminated on the next step: exercise restart recovery
    assert step(a, "status")["wishes"] == before_wishes
    step(b, "sync")
    assert step(a, "sync")["wishes"] == before_wishes + 1
    drain()
    step(b, "cycle")
    step(b, "sync")
    assert step(a, "sync")["hasSharedCycleDate"]
    step(b, "sync")
    drain()
    # New versioned journal events use the same independent encrypted HTTP path.
    step(b, "cycle-estimate")
    step(b, "sync")
    projection = step(a, "sync")
    assert projection["hasCycleEstimate"] and not projection["hasSharedCycleDate"]
    assert not projection["hasPrivateCycle"]
    step(b, "cycle-revoke")
    step(b, "sync")
    revoked = step(a, "sync")
    assert revoked["cycleRevoked"] and not revoked["hasCycleEstimate"]
    initial_dates = step(b, "status")["anniversaries"]
    anniversary = step(a, "anniversary")
    step(a, "sync")
    assert step(b, "sync")["anniversaries"] == initial_dates + 1
    edited_dates = step(a, "status")["editedAnniversaries"]
    step(b, "edit-anniversary", anniversary["runID"])
    step(b, "sync")
    assert step(a, "sync")["editedAnniversaries"] == edited_dates + 1
    step(a, "delete-anniversary", anniversary["runID"])
    step(a, "sync")
    assert step(b, "sync")["anniversaries"] == initial_dates
    initial = step(b, "status")
    journal = step(a, "journal")  # offline, then terminated before upload
    step(a, "sync")
    received = step(b, "sync")
    for field in ["checklists", "memories", "capsules"]:
        assert received[field] == initial[field] + 1, f"Missing {field} on peer"
    step(a, "sync")
    completed = step(a, "status")["completedLists"]
    step(b, "complete-list", journal["runID"])
    step(b, "sync")
    assert step(a, "sync")["completedLists"] == completed + 1
    cancelled = step(b, "status")["cancelledCapsules"]
    step(a, "cancel-capsule", journal["runID"])
    step(a, "sync")
    assert step(b, "sync")["cancelledCapsules"] == cancelled + 1
    drain()
    # Normal foreground lifecycle must pull without the test driver invoking sync.
    duets = step(b, "status")["completedDuets"]
    duet = step(a, "duet")
    step(a, "sync")
    step(b, "sync")
    step(b, "join-duet", duet["runID"])
    step(b, "sync")
    assert step(a, "sync")["completedDuets"] == duets + 1
    assert step(b, "sync")["completedDuets"] == duets + 1
    drain()
    step(b, "take-affection")
    original_messages = step(b, "status")["messages"]
    assert step(a, "affection")["affectionCoalesced"]
    step(a, "sync")
    step(b, "sync")
    assert step(b, "take-affection")["affectionCount"] == 1
    assert step(b, "take-affection")["affectionCount"] == 0
    assert step(b, "status")["messages"] == original_messages, "Affection became a chat message"
    before_auto = step(b, "status")["messages"]
    step(a, "message")
    for device in [a, b]:
        command("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE)
    # Leave enough time for both the foreground pull and the encrypted delivery
    # receipt.  Immediately terminating the receiver here can interrupt the receipt.
    time.sleep(20)
    assert step(b, "status")["messages"] == before_auto + 1, "Foreground automatic sync failed"
    assert step(a, "status")["pending"] == 0, "Automatic encrypted receipt failed"
    if options.capture_affection:
        step(a, "affection")
        step(a, "sync")
        command("xcrun", "simctl", "launch", "--terminate-running-process", b, BUNDLE)
        time.sleep(4)
        destination = ROOT / "docs/design/implementation-01/affection.png"
        destination.parent.mkdir(parents=True, exist_ok=True)
        command("xcrun", "simctl", "io", b, "screenshot", str(destination))
        print(f"Foreground affection capture: {destination}", flush=True)
    # The owner UI test writes only synthetic `private-xxxxxx` note tokens. Remove
    # that fixture if it is still the entire note, while restoring the owner's
    # deliberate share switches after the projection/revocation HTTP exercise.
    step(b, "clean-cycle-fixture")
    drain()
    for device in [a, b]:
        command("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE)
    print("PASS: two independent simulators paired over HTTP; chat, wishes, selective cycle sharing/revocation, anniversaries create/edit/delete, checklists, memories, capsules/cancellation, transient affections/coalescing, encrypted receipts, offline persistence, restart recovery and automatic foreground sync verified.", flush=True)

if __name__ == "__main__":
    main()
