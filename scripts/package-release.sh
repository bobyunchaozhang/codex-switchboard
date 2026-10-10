#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ $# -eq 0 ]]; then
    set -- arm64 x86_64
fi
for target_arch in "$@"; do
    ./scripts/build-app.sh "$target_arch"
    app_dir="$project_dir/dist/$target_arch/Codex Switchboard.app"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
    package_name="Codex-Switchboard-$version-$target_arch.dmg"
    staging_dir="$(mktemp -d "$project_dir/dist/dmg-stage.XXXXXX")"
    trap 'rm -rf "$staging_dir"' EXIT
    ditto "$app_dir" "$staging_dir/Codex Switchboard.app"
    ln -s /Applications "$staging_dir/Applications"
    hdiutil create -quiet -ov -format UDZO -volname "Codex Switchboard $version" \
        -srcfolder "$staging_dir" "$project_dir/dist/$package_name"
    hdiutil verify -quiet "$project_dir/dist/$package_name"
    rm -rf "$staging_dir"
    trap - EXIT
    (cd dist && shasum -a 256 "$package_name" > "$package_name.sha256")
    printf 'Packaged: %s\n' "$project_dir/dist/$package_name"
done
