"""從 simctl 與 Xcode scheme 的相容目的地交集中選取可實際啟動的 iPhone。"""
import json
import os
import re
from pathlib import Path


def available_ios_runtimes(runtimes):
    """回傳 identifier -> version；只保留實際安裝且可用的 iOS runtime。

    devices.json 可能還保留已移除 runtime 的裝置記錄，不能只信 isAvailable。
    """
    result = {}
    for item in runtimes.get("runtimes", []):
        if not item.get("isAvailable"):
            continue
        platform = item.get("platform")
        name = item.get("name", "")
        if platform != "iOS" and not name.startswith("iOS"):
            continue
        identifier = item.get("identifier")
        version = item.get("version")
        if not identifier or not version:
            continue
        # 少數 runner 會留下標記 available 但路徑已消失的 runtime。
        path = item.get("runtimeRoot") or item.get("bundlePath")
        if path and not Path(path).exists():
            continue
        try:
            result[identifier] = tuple(int(part) for part in version.split("."))
        except ValueError:
            continue
    return result


def select_device(devices, destinations, runtimes, sdk_version=None):
    """回傳版本、開機狀態、名稱及 UUID；無交集時拋出 ValueError。

    僅解析相容區段，避免將錯誤訊息中的 UUID 或 generic placeholder 當成裝置。
    優先與建置 SDK 同版本的 runtime，其次 iOS 27，最後才是其他可用 iOS。
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

    available = available_ios_runtimes(runtimes)
    candidates = []
    for runtime, items in devices.get("devices", {}).items():
        version = available.get(runtime)
        if version is None:
            continue
        for item in items:
            if (item.get("isAvailable") and item["name"].startswith("iPhone")
                    and item["udid"].upper() in eligible):
                candidates.append((version, item.get("state") == "Booted", item["name"], item["udid"]))
    if not candidates:
        raise ValueError("找不到 scheme 接受且 runtime 已安裝的 iOS iPhone；"
                         "請查看 devices.json、runtimes.json 與 destinations.log。")

    if sdk_version:
        try:
            target = tuple(int(part) for part in str(sdk_version).split("."))
        except ValueError:
            target = None
        if target:
            exact = [candidate for candidate in candidates if candidate[0] == target]
            if exact:
                return max(exact)

    ios27 = [candidate for candidate in candidates if candidate[0][0] == 27]
    return max(ios27 or candidates)


def main():
    """讀取 CI 診斷檔，輸出後續步驟使用的 UUID，並保存選取結果。"""
    sdk_version = None
    for argument in os.sys.argv[1:]:
        if argument.startswith("--sdk="):
            sdk_version = argument.split("=", 1)[1]

    folder = Path("TestResults")
    version, booted, name, udid = select_device(
        json.loads((folder / "devices.json").read_text()),
        (folder / "destinations.log").read_text(),
        json.loads((folder / "runtimes.json").read_text()),
        sdk_version=sdk_version)
    description = f"Using {name}, iOS {version}, {udid}"
    print(description)
    (folder / "selected-simulator.txt").write_text(description + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"id={udid}\nbooted={str(booted).lower()}\n")


if __name__ == "__main__":
    main()
