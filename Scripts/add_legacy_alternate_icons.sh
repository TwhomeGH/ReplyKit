#!/bin/bash
# Adds file-based alternate icon declarations for signers such as KSign that do
# not understand asset-catalog-only CFBundleIconName entries. The asset catalog
# declaration is kept; these files and CFBundleIconFiles are a compatibility
# layer for the unsigned archive before the IPA is produced.
# Do not copy PersonalIcon.png (1024 marketing icon): it is not listed in any
# CFBundleIconFiles array, and Assets.car already carries the catalog rendition.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <liveAPP.app>" >&2
  exit 2
fi

APP="$1"
PLIST="$APP/Info.plist"
SOURCE_DIR="liveAPP/Assets.xcassets/PersonalIcon.appiconset"

if [[ ! -d "$APP" ]]; then
  echo "app bundle not found: $APP" >&2
  exit 1
fi
if [[ ! -f "$PLIST" ]]; then
  echo "Info.plist not found: $PLIST" >&2
  exit 1
fi

for file in \
  PersonalIcon-76.png \
  PersonalIcon-120.png \
  PersonalIcon-152.png \
  PersonalIcon-167.png \
  PersonalIcon-180.png
do
  if [[ ! -f "$SOURCE_DIR/$file" ]]; then
    echo "missing source icon: $SOURCE_DIR/$file" >&2
    exit 1
  fi
  cp "$SOURCE_DIR/$file" "$APP/$file"
done

add_icon_files() {
  local key="$1"
  shift
  local index=0

  /usr/libexec/PlistBuddy -c "Delete :${key}:CFBundleIconFiles" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :${key}:CFBundleIconFiles array" "$PLIST"
  for file in "$@"; do
    /usr/libexec/PlistBuddy -c "Add :${key}:CFBundleIconFiles:${index} string ${file}" "$PLIST"
    index=$((index + 1))
  done
}

add_icon_files \
  "CFBundleIcons:CFBundleAlternateIcons:PersonalIcon" \
  PersonalIcon-120.png \
  PersonalIcon-180.png

add_icon_files \
  "CFBundleIcons~ipad:CFBundleAlternateIcons:PersonalIcon" \
  PersonalIcon-76.png \
  PersonalIcon-152.png \
  PersonalIcon-167.png

echo "legacy alternate icon files added:"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundleAlternateIcons:PersonalIcon:CFBundleIconFiles" "$PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons~ipad:CFBundleAlternateIcons:PersonalIcon:CFBundleIconFiles" "$PLIST"
