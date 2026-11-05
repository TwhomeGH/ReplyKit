"""從 simctl 與 Xcode scheme 的相容目的地交集中排序可實際啟動的 iPhone。

CI 會逐台嘗試開機；全部失敗時再依輸出的 runtime/device type 建一台新的。
"""
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

PREFERRED_MODELS = ("iPhone 17", "iPhone 16", "iPhone 15", "iPhone 14", "iPhone SE")


@dataclass(frozen=True)
class Candidate:
    version: tuple[int, ...]
    booted: bool
    name: str
    udid: str
    runtime: str

    def legacy(self):
        """回傳既有測試/呼叫端使用的四元組。"""
        return (self.version, self.booted, self.name, self.udid)


def model_rank(name: str) -> int:
    for index, prefix in enumerate(PREFERRED_MODELS):
        if name == prefix or name.startswith(prefix + " "):
            return index
    return len(PREFERRED_MODELS)


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


def eligible_ids(destinations: str) -> set[str]:
    """解析 scheme 相容區段，避免把錯誤訊息 UUID 或 placeholder 當裝置。"""
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
    return eligible


def ordered_candidates(devices, destinations, runtimes, sdk_version=None):
    """回傳排序後的候選裝置；順序即為 CI 嘗試開機的順序。"""
    eligible = eligible_ids(destinations)
    available = available_ios_runtimes(runtimes)

    try:
        target = (tuple(int(part) for part in str(sdk_version).split("."))
                  if sdk_version else None)
    except ValueError:
        target = None

    candidates = []
    for runtime, items in devices.get("devices", {}).items():
        version = available.get(runtime)
        if version is None:
            continue
        for item in items:
            if not item.get("isAvailable"):
                continue
            if not item["name"].startswith("iPhone"):
                continue
            if item["udid"].upper() not in eligible:
                continue
            candidates.append(Candidate(
                version=version,
                booted=item.get("state") == "Booted",
                name=item["name"],
                udid=item["udid"],
                runtime=runtime,
            ))

    def sort_key(candidate: Candidate):
        group = 0 if target and candidate.version == target else (
            1 if candidate.version[0] == 27 else 2)
        return (
            group,
            tuple(-part for part in candidate.version),
            0 if candidate.booted else 1,
            model_rank(candidate.name),
            candidate.name,
            candidate.udid,
        )

    return sorted(candidates, key=sort_key)


def select_device(devices, destinations, runtimes, sdk_version=None):
    """回傳版本、開機狀態、名稱及 UUID；無交集時拋出 ValueError。"""
    candidates = ordered_candidates(devices, destinations, runtimes, sdk_version)
    if not candidates:
        raise ValueError("找不到 scheme 接受且 runtime 已安裝的 iOS iPhone；"
                         "請查看 devices.json、runtimes.json 與 destinations.log。")
    return candidates[0].legacy()


def device_type_candidates(devicetypes):
    """回傳可建立的 iPhone device type identifier，標準機型優先。"""
    items = [item for item in devicetypes.get("devicetypes", [])
             if item.get("name", "").startswith("iPhone") and item.get("identifier")]
    items.sort(key=lambda item: (model_rank(item["name"]), item["name"]))
    return [item["identifier"] for item in items]


def _arg_value(prefix):
    for argument in os.sys.argv[1:]:
        if argument.startswith(prefix):
            return argument.split("=", 1)[1]
    return None


def main():
    """輸出嘗試順序、最佳裝置、runtime 與可建立的 device type。"""
    sdk_version = _arg_value("--sdk=")
    devicetypes_arg = _arg_value("--devicetypes=")

    folder = Path("TestResults")
    devices = json.loads((folder / "devices.json").read_text())
    runtimes = json.loads((folder / "runtimes.json").read_text())
    destinations = (folder / "destinations.log").read_text()

    candidates = ordered_candidates(devices, destinations, runtimes, sdk_version)
    if not candidates:
        raise ValueError("找不到 scheme 接受且 runtime 已安裝的 iOS iPhone；"
                         "請查看 devices.json、runtimes.json 與 destinations.log。")

    best = candidates[0]
    description = f"Using {best.name}, iOS {best.version}, {best.udid}"
    print(description)
    (folder / "selected-simulator.txt").write_text(description + "\n")
    (folder / "simulator-candidates.txt").write_text(
        "".join(f"{candidate.udid}\n" for candidate in candidates))
    (folder / "simulator-runtime.txt").write_text(best.runtime + "\n")

    devicetypes_path = Path(devicetypes_arg) if devicetypes_arg else folder / "devicetypes.json"
    if devicetypes_path.exists():
        types = device_type_candidates(json.loads(devicetypes_path.read_text()))
        (folder / "simulator-device-types.txt").write_text(
            "".join(f"{identifier}\n" for identifier in types))

    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"id={best.udid}\nbooted={str(best.booted).lower()}\n")


if __name__ == "__main__":
    main()
