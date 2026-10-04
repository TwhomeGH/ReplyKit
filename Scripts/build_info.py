#!/usr/bin/env python3
"""建置時產生離線來源資訊；不查網路，不修改套件原始碼。"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import uuid

LOCK_PATH = Path("liveAPP.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
IDENTITIES = {"haishinkitfixswfit", "haishinkit.swift"}


def git(path, *args):
    try:
        result = subprocess.run(["git", "-C", str(path), *args], capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=15,
                                env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def snapshot(path):
    # 目錄不能回退到上層 repository，否則可能把 App revision 當套件 revision。
    top = git(path, "rev-parse", "--show-toplevel")
    if top is None or Path(top).resolve() != path.resolve():
        return None, None, None, None
    revision = git(path, "rev-parse", "HEAD")
    status = git(path, "status", "--porcelain", "--untracked-files=normal")
    if status is None:
        return revision, None, None, None
    lines = status.splitlines()
    untracked = sum(1 for line in lines if line.startswith("??"))
    modified = len(lines) - untracked
    return revision, bool(lines), untracked, modified


def collect(root, env):
    revision, dirty, untracked, modified = snapshot(root)
    info = {
        "schemaVersion": 1, "buildID": str(uuid.uuid4()),
        "appRevision": revision, "appDirty": dirty,
        "appUntrackedCount": untracked, "appModifiedCount": modified,
        "builtAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "source": "GitHub Actions" if env.get("GITHUB_ACTIONS") == "true" else "本機",
        "configuration": env.get("CONFIGURATION"), "platform": env.get("PLATFORM_NAME"),
        "xcode": env.get("XCODE_VERSION_ACTUAL"), "sdk": env.get("SDK_VERSION"),
        "ciRun": env.get("GITHUB_RUN_ID"), "ciAttempt": env.get("GITHUB_RUN_ATTEMPT"),
        "haishinRevision": None, "haishinVersion": None,
        "haishinCheckoutRevision": None, "haishinCheckoutDirty": None,
        "haishinCheckoutUntrackedCount": None, "haishinCheckoutModifiedCount": None,
        "haishinVerification": "missing",
    }
    try:
        lock = json.loads((root / LOCK_PATH).read_text(encoding="utf-8"))
        pins = lock.get("pins", lock.get("object", {}).get("pins", []))
        matches = [p for p in pins if p.get("identity", p.get("package", "")).lower() in IDENTITIES]
        if len(matches) != 1:
            return info
        pin = matches[0]
        info["haishinRevision"] = pin["state"].get("revision")
        info["haishinVersion"] = pin["state"].get("version")
        if not isinstance(info["haishinRevision"], str) or not info["haishinRevision"]:
            info["haishinRevision"] = None
            return info
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return info
    info["haishinVerification"] = "unverified"
    directories = []
    if env.get("BUILD_INFO_PACKAGES_DIR"):
        directories.append(Path(env["BUILD_INFO_PACKAGES_DIR"]))
    elif env.get("BUILD_DIR"):
        # 一般 build 與 archive 的 BUILD_DIR 深度不同，逐層檢查固定子路徑。
        directories.extend(parent / "SourcePackages" for parent in Path(env["BUILD_DIR"]).parents)
    for directory in directories:
        checkouts = directory / "checkouts"
        if not checkouts.is_dir():
            continue
        for checkout in checkouts.iterdir():
            if checkout.name.lower() not in IDENTITIES or not checkout.is_dir():
                continue
            actual, checkout_dirty, checkout_untracked, checkout_modified = snapshot(checkout)
            info["haishinCheckoutRevision"] = actual
            info["haishinCheckoutDirty"] = checkout_dirty
            info["haishinCheckoutUntrackedCount"] = checkout_untracked
            info["haishinCheckoutModifiedCount"] = checkout_modified
            if actual and info["haishinRevision"]:
                info["haishinVerification"] = "matched" if actual == info["haishinRevision"] else "mismatch"
            return info
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    info = collect(args.root.resolve(), os.environ)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.output)
    print("BuildInfo: app=" + str(info["appRevision"]) + " haishin=" + str(info["haishinRevision"]) + " verification=" + info["haishinVerification"])


if __name__ == "__main__":
    main()
