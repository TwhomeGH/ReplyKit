"""從 simctl 與 Xcode scheme 的相容目的地交集中選取 iOS 27 iPhone。"""
import json
import os
import re
from pathlib import Path


def select_device(devices, destinations):
    """回傳版本、開機狀態、名稱及 UUID；無交集時拋出 ValueError。

    僅解析相容區段，避免將錯誤訊息中的 UUID 或 generic placeholder 當成裝置。
    """
    eligible = set()
    active = False
    for line in destinations.splitlines():
        if "Available destinations for" in line or "Destinations compatible with" in line:
            active = True
        elif "Ineligible destinations" in line or "Destinations incompatible with" in line:
            active = False
        if not active or "error:" in line:
            continue
        if not re.search(r"platform:\s*iOS Simulator\s*,", line):
            continue
        match = re.search(r"\bid:\s*([0-9A-Fa-f-]{36})(?:\s*,|\s*})", line)
        if match:
            eligible.add(match.group(1).upper())
    candidates = []
    for runtime, items in devices.get("devices", {}).items():
        match = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        if version[0] != 27:
            continue
        for item in items:
            if (item.get("isAvailable") and item["name"].startswith("iPhone")
                    and item["udid"].upper() in eligible):
                candidates.append((version, item.get("state") == "Booted", item["name"], item["udid"]))
    if not candidates:
        raise ValueError("找不到 simctl 與 liveAPP scheme 都接受的 iOS 27 iPhone；請查看 devices.json 與 destinations.log。")
    return max(candidates)


def main():
    """讀取 CI 診斷檔，輸出後續步驟使用的 UUID，並保存選取結果。"""
    folder = Path("TestResults")
    version, booted, name, udid = select_device(
        json.loads((folder / "devices.json").read_text()),
        (folder / "destinations.log").read_text())
    description = f"Using {name}, iOS {version}, {udid}"
    print(description)
    (folder / "selected-simulator.txt").write_text(description + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"id={udid}\nbooted={str(booted).lower()}\n")


if __name__ == "__main__":
    main()
