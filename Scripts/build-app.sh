#!/bin/zsh

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
# Public builds never inspect or select a contributor's private signing
# identity automatically. A developer can opt in explicitly when local TCC
# permissions must survive replacement of an already signed app.
sign_identity="${TOUCHBARCHAT_SIGN_IDENTITY:--}"

cd "$project_root"

swift build --disable-sandbox -c "$configuration"
binary_directory="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"

app_directory="${TOUCHBARCHAT_APP_OUTPUT:-$project_root/Build/TouchBarChat.app}"
contents_directory="$app_directory/Contents"
macos_directory="$contents_directory/MacOS"
resources_directory="$contents_directory/Resources"

mkdir -p "$macos_directory" "$resources_directory"
cp "$binary_directory/TouchBarChat" "$macos_directory/TouchBarChat"
cp "$project_root/Resources/Info.plist" "$contents_directory/Info.plist"
# SwiftPM embeds Localizable.strings in its generated resource bundle. Keep that
# bundle for explicit lookups and copy .lproj folders to the app bundle so native
# SwiftUI/AppKit text and macOS privacy prompts use the same translations.
resource_bundle="$binary_directory/TouchBarChat_TouchBarChat.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "Missing SwiftPM localization bundle: $resource_bundle"
    exit 1
fi
ditto "$resource_bundle" "$resources_directory/TouchBarChat_TouchBarChat.bundle"
for localization in "$project_root"/Sources/TouchBarChat/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    ditto "$localization" "$resources_directory/${localization:t}"
done
for localization in "$project_root"/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    ditto "$localization" "$resources_directory/${localization:t}"
done
chmod +x "$macos_directory/TouchBarChat"

if [[ "$sign_identity" == "-" ]]; then
    print -u2 "Warning: no single Apple Development identity found; using ad-hoc signing. Rebuilding may invalidate macOS privacy permissions."
fi
codesign --force --timestamp=none --sign "$sign_identity" "$app_directory"

echo "$app_directory"
