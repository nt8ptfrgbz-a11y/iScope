"""Resolve an install destination without selecting stale pairings or simulators."""
import json
import os
from pathlib import Path
import shlex
import tempfile

from common import run


def connected_ios_devices(document):
    if not isinstance(document, dict):
        raise ValueError("Xcode 设备列表不是有效的 JSON 对象")
    if document.get("info", {}).get("outcome", "success") != "success":
        raise ValueError("Xcode 设备查询失败，请运行 ./hooktool devices 查看详情")
    records = document.get("result", {}).get("devices")
    if not isinstance(records, list):
        raise ValueError("Xcode 设备列表缺少 result.devices，请检查 Xcode 版本")
    devices = {}
    for record in records:
        if not isinstance(record, dict):
            continue
        properties = record.get("properties") or {}
        # Xcode 27 replaces the legacy dictionaries with categorized properties.
        hardware = {**(record.get("hardwareProperties") or {}), **(properties.get("hardware") or {})}
        connection = {**(record.get("connectionProperties") or {}), **(properties.get("connection") or {})}
        state = {**(record.get("deviceProperties") or {}), **(properties.get("state") or {})}
        platform = str(hardware.get("platform", "")).lower()
        if platform not in ("ios", "ipados"):
            continue
        if (hardware.get("reality", "physical") != "physical"
                or record.get("visibilityClass") == "simulators"
                or state.get("visibilityClass") == "simulators"
                or "Simulator" in str(state.get("provider", ""))
                or connection.get("transportType") == "sameMachine"):
            continue
        if connection.get("state", connection.get("tunnelState")) != "connected":
            continue
        if connection.get("pairingState", "paired") != "paired":
            continue
        if state.get("bootState", "booted") != "booted":
            continue
        identifier = record.get("identifier") or hardware.get("udid")
        if not isinstance(identifier, str) or not identifier.strip():
            continue
        devices[identifier] = {"identifier": identifier, "name": state.get("name") or identifier,
                               "udid": hardware.get("udid") or identifier}
    return sorted(devices.values(), key=lambda device: (device["name"], device["identifier"]))


def choose_connected_device(document):
    devices = connected_ios_devices(document)
    if not devices:
        raise ValueError("没有检测到已连接的 iPhone/iPad 真机。请连接并解锁设备、信任这台 Mac；"
                         "已配对的无线设备也可用 --device 指定名称或 UDID。可运行 ./hooktool devices 查看。")
    if len(devices) > 1:
        choices = "\n".join(f"- {device['name']}：--device {shlex.quote(device['udid'])}" for device in devices)
        raise ValueError("检测到多台已连接真机，请用 --device 指定一台，或设置 IOS_HOOK_DEVICE：\n" + choices)
    return devices[0]


def resolve_install_device(device=None):
    """Explicit argument > environment default > exactly one connected device."""
    requested = device if device is not None else os.environ.get("IOS_HOOK_DEVICE")
    if requested is not None and requested.strip():
        return requested.strip()
    print("查找已连接的 iPhone/iPad…", flush=True)
    with tempfile.TemporaryDirectory(prefix="ios-hook-devices-") as directory:
        path = Path(directory) / "devices.json"
        run("xcrun", "devicectl", "list", "devices", "--timeout", "15", "--quiet", "--json-output", path)
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise ValueError("无法读取 Xcode 设备列表，请运行 ./hooktool devices 查看详情") from error
    selected = choose_connected_device(document)
    print(f"自动选择设备：{selected['name']}（{selected['udid']}）", flush=True)
    return selected["identifier"]
