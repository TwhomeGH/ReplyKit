#!/usr/bin/env python3
"""依變更路徑與 commit trailer 產生 Release 分類名稱。

Release tag 保持純 `x.y.z`；分類只寫入 GitHub Release 的 name/body 與 JSON：
- Core/UI：底層或 UI 影響
- Audio/Video/RTMP/PiP/Extension/Settings：子系統
- Exp：最近 5 個 release 內有 Core 變更
- Hotfix/Major：必須用 commit trailer `Release-Label:` 明確指定
- UIFix：UI 變更且只有 fix 類型 commit
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
TRAILER = re.compile(r"^Release-Label:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
CONVENTIONAL = re.compile(
    r"^(feat|fix|perf|refactor|build|docs|test|chore|style|revert)(?:\([^)]*\))?!?:",
    re.IGNORECASE | re.MULTILINE,
)
ALLOWED_LABELS = {
    "Core", "UI", "Audio", "Video", "RTMP", "PiP", "Extension", "Settings",
    "Exp", "Hotfix", "Major", "UIFix", "Stable",
}


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def normalize(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def matches(path: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def classify_paths(paths: list[str], config: dict) -> dict:
    visible = [
        normalize(path) for path in paths
        if not matches(normalize(path), config.get("ignored", []))
    ]
    tiers = [
        tier for tier, patterns in config.get("tiers", {}).items()
        if any(matches(path, patterns) for path in visible)
    ]
    areas = [
        area for area, patterns in config.get("areas", {}).items()
        if any(matches(path, patterns) for path in visible)
    ]
    return {"tiers": tiers, "areas": areas, "paths": visible}


def labels_from_commits(message_text: str) -> set[str]:
    labels: set[str] = set()
    for value in TRAILER.findall(message_text):
        for item in re.split(r"[,/]", value):
            label = item.strip()
            if label in ALLOWED_LABELS:
                labels.add(label)
    return labels


def conventional_types(message_text: str) -> set[str]:
    return {match.lower() for match in CONVENTIONAL.findall(message_text)}


def exp_window(history: list[bool], window: int) -> tuple[bool, int]:
    """history 由新到舊排列；回傳 (exp, 還需標示的 release 數)。"""
    hits = [index for index, changed in enumerate(history[:window]) if changed]
    if not hits:
        return False, 0
    return True, window - min(hits)


def build_name(tag: str, tiers: list[str], areas: list[str],
               modifiers: list[str], max_areas: int = 3) -> str:
    parts = [tag]
    if tiers:
        parts.append("+".join(tiers))
    if areas:
        parts.append("+".join(areas[:max_areas]))
    parts.extend(modifiers)
    return " · ".join(parts)


def git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
    )
    return result.stdout


def semver_tags(root: Path) -> list[str]:
    tags = [
        tag for tag in git(root, "tag", "--list").splitlines()
        if SEMVER.match(tag)
    ]
    return sorted(tags, key=lambda tag: tuple(int(part) for part in tag.split(".")))


def changed_paths(root: Path, from_ref: str | None, to_ref: str) -> list[str]:
    if from_ref is None:
        output = git(root, "ls-tree", "-r", "--name-only", to_ref)
    else:
        output = git(root, "diff", "--name-only", "--diff-filter=ACDMRT",
                     from_ref, to_ref)
    return [line for line in output.splitlines() if line]


def commit_text(root: Path, from_ref: str | None, to_ref: str) -> str:
    revision = f"{from_ref}..{to_ref}" if from_ref else to_ref
    return git(root, "log", "--format=%B%x00", revision)


def history_core_flags(root: Path, tags: list[str], current_index: int,
                       window: int, config: dict) -> list[bool]:
    flags: list[bool] = []
    for offset in range(window):
        index = current_index - offset
        if index < 0:
            flags.append(False)
            continue
        to_ref = tags[index]
        from_ref = tags[index - 1] if index > 0 else None
        result = classify_paths(changed_paths(root, from_ref, to_ref), config)
        flags.append("Core" in result["tiers"])
    return flags


def classify(root: Path, tag: str, config: dict,
             exp_window_size: int, from_tag: str | None = None) -> dict:
    tags = semver_tags(root)
    if tag in tags:
        current_index = tags.index(tag)
    else:
        current_index = len(tags) - 1
    if from_tag is None:
        from_tag = tags[current_index - 1] if current_index > 0 else None

    current_paths = changed_paths(root, from_tag, tag)
    result = classify_paths(current_paths, config)
    messages = commit_text(root, from_tag, tag)
    trailers = labels_from_commits(messages)
    types = conventional_types(messages)

    history = history_core_flags(root, tags, current_index, exp_window_size, config)
    experimental, exp_remaining = exp_window(history, exp_window_size)
    core_changed = "Core" in result["tiers"]

    modifiers: list[str] = []
    if "Hotfix" in trailers:
        modifiers.append("Hotfix")
    if "Major" in trailers:
        modifiers.append("Major")
    if experimental:
        modifiers.append("Exp")
    if "UIFix" in trailers or (
        "UI" in result["tiers"] and "fix" in types and "feat" not in types
    ):
        modifiers.append("UIFix")
    if (not experimental and "Hotfix" not in modifiers
            and "Major" not in modifiers and "UIFix" not in modifiers):
        modifiers.append("Stable")

    tiers = result["tiers"]
    areas = result["areas"]
    labels = [*tiers, *areas, *modifiers]
    name = build_name(tag, tiers, areas, modifiers, config.get("maxAreas", 3))

    expires_at = None
    if experimental and current_index >= 0:
        expiry_index = current_index + exp_remaining
        if expiry_index < len(tags):
            expires_at = tags[expiry_index]

    reasons = []
    if core_changed:
        reasons.append("Core path changed")
    if "UI" in tiers:
        reasons.append("UI path changed")
    if experimental:
        reasons.append(f"Core change within last {exp_window_size} releases")
    if "Hotfix" in modifiers:
        reasons.append("Release-Label: Hotfix")
    if "Major" in modifiers:
        reasons.append("Release-Label: Major")
    if not reasons:
        reasons.append("No core/UI change")

    expiry_text = "not active"
    if experimental:
        expiry_text = expires_at or f"after {exp_remaining} more release(s)"
    summary_lines = [
        "## Release classification",
        "",
        f"- **Labels:** {' · '.join(labels) if labels else 'none'}",
        f"- **Tier:** {' + '.join(tiers) if tiers else 'none'}",
        f"- **Areas:** {' + '.join(areas) if areas else 'none'}",
        f"- **Core change:** {'yes' if core_changed else 'no'}",
        f"- **Experimental window:** {'active, %d release(s) left' % exp_remaining if experimental else 'inactive'}",
        f"- **Expires at:** {expiry_text}",
        "- **Reasons:** " + "; ".join(reasons),
    ]

    return {
        "tag": tag,
        "name": name,
        "labels": labels,
        "tier": tiers,
        "areas": areas,
        "modifiers": modifiers,
        "coreChanged": core_changed,
        "experimental": experimental,
        "expRemainingReleases": exp_remaining,
        "expiresAt": expires_at,
        "reasons": reasons,
        "summary": "\n".join(summary_lines),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="目標版本 tag（x.y.z）")
    parser.add_argument("--from-tag", help="覆寫比較起點")
    parser.add_argument("--root", default=str(ROOT), help="Git repository 根目錄")
    parser.add_argument("--config", default=str(ROOT / "Scripts" / "release_classification.json"))
    parser.add_argument("--exp-window", type=int, default=None)
    args = parser.parse_args()

    config = load_config(Path(args.config))
    window = args.exp_window or config.get("expWindowReleases", 5)
    try:
        result = classify(Path(args.root), args.tag, config, window, args.from_tag)
    except subprocess.CalledProcessError as error:
        print(error.stderr or error, file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
