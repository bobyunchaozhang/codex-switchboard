#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
target_arch="${1:-$(uname -m)}"
case "$target_arch" in
    arm64|x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$target_arch" >&2; exit 1 ;;
esac
swift build -c release --arch "$target_arch" --product CodexSwitchboard --jobs 4
binary_dir="$(swift build -c release --arch "$target_arch" --show-bin-path)"
if [[ $# -eq 0 ]]; then
    app_dir="$project_dir/dist/Codex Switchboard.app"
else
    app_dir="$project_dir/dist/$target_arch/Codex Switchboard.app"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/CodexSwitchboard" "$app_dir/Contents/MacOS/CodexSwitchboard"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Codex Switchboard</string>
<key>CFBundleDisplayName</key><string>Codex Switchboard</string>
<key>CFBundleIdentifier</key><string>local.codex-switchboard.app</string>
<key>CFBundleExecutable</key><string>CodexSwitchboard</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.4</string>
<key>CFBundleVersion</key><string>12</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
[[ "$(lipo -archs "$app_dir/Contents/MacOS/CodexSwitchboard")" == "$target_arch" ]]
printf 'Built: %s\n' "$app_dir"
