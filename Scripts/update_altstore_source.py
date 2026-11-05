#!/usr/bin/env python3
"""Compose an AltStore source for a published CI release.

Zero-dependency. The release job passes the real app version/build read from
the archived Info.plist, the release tag and the IPA byte size; this script
composes that version entry into a copy of the template. CI writes to
``build/AltStoreTest.json`` and attaches it to the release so the repository
template is never modified by automation.

Usage:
    python3 Scripts/update_altstore_source.py --path AltStoreTest.json \
        --output build/AltStoreTest.json \
        --tag 17.2.3 --version 17.2.2 --build 2026100601 \
        --size 2950000 --repo TwhomeGH/ReplyKit
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

TAIPEI = timezone(timedelta(hours=8))
TAG_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){2}$")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", required=True, type=Path,
                        help="Template source; never modified when --output is set")
    parser.add_argument("--output", default=None, type=Path,
                        help="Write the composed source here; defaults to --path")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--size", required=True, type=int)
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--bundle-id", default="nuclear.liveAPP")
    parser.add_argument("--max-versions", default=10, type=int)
    parser.add_argument("--date", default=None,
                        help="ISO8601 override; defaults to now in +08:00")
    parser.add_argument("--min-os", default=None,
                        help="Defaults to the newest existing entry, else 16.0")
    parser.add_argument("--description", default="",
                        help="Defaults to the app's localizedDescription")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def make_entry(*, tag: str, version: str, build: str, size: int,
               repo: str, date: str, min_os: str,
               description: str = "") -> dict:
    return {
        "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/liveApp_{tag}.ipa",
        "size": size,
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": description,
        "minOSVersion": min_os,
    }


def update_source(source: dict, *, bundle_id: str, entry: dict,
                  max_versions: int) -> dict:
    apps = source.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("source has no apps")

    app = next((item for item in apps
                if isinstance(item, dict) and item.get("bundleIdentifier") == bundle_id), None)
    if app is None:
        raise ValueError(f"bundleIdentifier {bundle_id!r} not found")

    versions = app.setdefault("versions", [])
    if not isinstance(versions, list):
        raise ValueError("versions is not a list")
    if not entry.get("localizedDescription"):
        entry["localizedDescription"] = app.get("localizedDescription", "")

    key = (entry["version"], entry["buildVersion"])
    versions[:] = [item for item in versions
                   if (item.get("version"), item.get("buildVersion")) != key]
    versions.insert(0, entry)
    del versions[max_versions:]
    return source


def newest_release_tag(source: dict, bundle_id: str) -> str | None:
    tags: list[str] = []
    for app in source.get("apps", []):
        if app.get("bundleIdentifier") != bundle_id:
            continue
        for item in app.get("versions", []):
            match = re.search(r"/download/([^/]+)/liveApp_", item.get("downloadURL", ""))
            if match and TAG_RE.match(match.group(1)):
                tags.append(match.group(1))
    return max(tags, key=tag_key) if tags else None


def tag_key(tag: str) -> tuple[int, ...]:
    return tuple(int(part) for part in tag.split("."))


def resolve_date(value: str | None) -> str:
    if value:
        return value
    return datetime.now(TAIPEI).replace(microsecond=0).isoformat()


def resolve_min_os(source: dict, bundle_id: str, override: str | None) -> str:
    if override:
        return override
    for app in source.get("apps", []):
        if app.get("bundleIdentifier") != bundle_id:
            continue
        for item in app.get("versions", []):
            if item.get("minOSVersion"):
                return str(item["minOSVersion"])
    return "16.0"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if not TAG_RE.match(args.tag):
        raise SystemExit(f"invalid release tag: {args.tag!r}")
    if args.size <= 0:
        raise SystemExit(f"invalid IPA size: {args.size}")
    if args.max_versions < 1:
        raise SystemExit("--max-versions must be positive")
    if not args.version.strip() or not args.build.strip():
        raise SystemExit("version and build must not be empty")

    path: Path = args.path
    source = json.loads(path.read_text(encoding="utf-8"))

    current = newest_release_tag(source, args.bundle_id)
    if current and tag_key(args.tag) < tag_key(current):
        print(f"ignored older release {args.tag}; source already has {current}")
        return 0

    entry = make_entry(
        tag=args.tag,
        version=args.version,
        build=args.build,
        size=args.size,
        repo=args.repo,
        date=resolve_date(args.date),
        min_os=resolve_min_os(source, args.bundle_id, args.min_os),
        description=args.description,
    )
    update_source(source, bundle_id=args.bundle_id, entry=entry,
                  max_versions=args.max_versions)

    text = json.dumps(source, ensure_ascii=False, indent=2) + "\n"
    if args.dry_run:
        sys.stdout.write(text)
        return 0

    destination: Path = args.output or path
    tmp = destination.with_suffix(destination.suffix + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(destination)
    print(f"wrote {destination}: {entry['version']} ({entry['buildVersion']}) "
          f"from {args.tag}, {args.size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
