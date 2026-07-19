#!/bin/bash

set -euo pipefail

release_version="${1:-}"
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/package_dmg.sh <major.minor.patch>" >&2
  exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
release_work_directory="$(mktemp -d "${TMPDIR:-/tmp}/agents-deck-release.XXXXXX")"
mount_directory="$release_work_directory/mount"
distribution_directory="$repository_root/dist"
disk_image_name="Agents-Deck-${release_version}.dmg"
checksum_name="Agents-Deck-${release_version}.sha256"
disk_image_path="$distribution_directory/$disk_image_name"
checksum_path="$distribution_directory/$checksum_name"
mounted=0

audit_application() {
  local application="$1"
  local executable="$application/Contents/MacOS/Agents Deck"
  local entitlements
  local codesign_metadata
  local bundle_entry
  local dependency

  test -d "$application"
  test -x "$executable"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$application"
  codesign_metadata="$(/usr/bin/codesign -dv --verbose=4 "$application" 2>&1)"
  if ! /usr/bin/grep -Eq 'flags=.*runtime' <<<"$codesign_metadata"; then
    echo "Hardened runtime is missing from the release app" >&2
    exit 67
  fi

  entitlements="$(/usr/bin/codesign -d --entitlements :- "$application" 2>/dev/null || true)"
  if /usr/bin/grep -q '<key>' <<<"$entitlements"; then
    echo "Release app contains unexpected code-signing entitlements" >&2
    exit 67
  fi

  while IFS= read -r bundle_entry; do
    case "$(/usr/bin/basename "$bundle_entry")" in
      Info.plist|PkgInfo|MacOS|Resources|_CodeSignature) ;;
      *)
        echo "Unexpected top-level app bundle entry: $bundle_entry" >&2
        exit 68
        ;;
    esac
  done < <(/usr/bin/find "$application/Contents" -mindepth 1 -maxdepth 1 -print)

  for forbidden_directory in Frameworks PlugIns XPCServices Helpers SharedSupport; do
    if [[ -e "$application/Contents/$forbidden_directory" ]]; then
      echo "Unexpected executable content: Contents/$forbidden_directory" >&2
      exit 68
    fi
  done

  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      *)
        echo "Non-system dynamic library linked by release app: $dependency" >&2
        exit 68
        ;;
    esac
  done < <(/usr/bin/otool -arch arm64 -L "$executable" | /usr/bin/awk '/^[[:space:]]+\// {print $1}')

  if /usr/bin/grep -R -a -E -i -l \
    '/Users/[^/[:space:]]+|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[opsu]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-(proj-)?[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}' \
    "$application" >/dev/null; then
    echo "Release app contains a forbidden private identity, path, or credential marker" >&2
    exit 68
  fi

  # Checked separately from the patterns above: this pattern also matches Apple's
  # standard @1x/@2x/@3x retina asset filenames (e.g. app-icon-128@2x.png) baked
  # into the compiled Assets.car, which are not credentials. Filter those out
  # before treating any remaining match as a real leaked email address.
  local email_match
  while IFS= read -r email_match; do
    case "$email_match" in
      *@[1-3]x.png|*@[1-3]x.pdf|*@[1-3]x.jpg|*@[1-3]x.jpeg|*@[1-3]x.heic) ;;
      *)
        echo "Release app contains a forbidden email address marker: $email_match" >&2
        exit 68
        ;;
    esac
  done < <(/usr/bin/grep -R -a -E -i -o \
    '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' \
    "$application" 2>/dev/null | sort -u)
}

cleanup() {
  if [[ "$mounted" == "1" ]]; then
    /usr/bin/hdiutil detach "$mount_directory" -quiet || true
  fi
  /bin/rm -rf "$release_work_directory"
}
trap cleanup EXIT

/bin/mkdir -p "$distribution_directory"
/bin/rm -f "$disk_image_path" "$checksum_path"

/usr/bin/xcodebuild \
  -project "$repository_root/AgentsDeck.xcodeproj" \
  -scheme AgentsDeck \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$release_work_directory/DerivedData" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  DEVELOPMENT_TEAM= \
  OTHER_SWIFT_FLAGS="-file-prefix-map $repository_root=." \
  build

application_path="$release_work_directory/DerivedData/Build/Products/Release/Agents Deck.app"
executable_path="$application_path/Contents/MacOS/Agents Deck"
info_plist="$application_path/Contents/Info.plist"

test -d "$application_path"
test -x "$executable_path"

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
if [[ "$built_version" != "$release_version" ]]; then
  echo "Built version $built_version does not match requested release $release_version" >&2
  exit 65
fi

built_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$built_bundle_identifier" != "com.vulonviing.agentsdeck" ]]; then
  echo "Unexpected bundle identifier: $built_bundle_identifier" >&2
  exit 65
fi

architectures="$(/usr/bin/lipo -archs "$executable_path")"
for required_architecture in arm64 x86_64; do
  if [[ " $architectures " != *" $required_architecture "* ]]; then
    echo "Missing required architecture: $required_architecture" >&2
    exit 66
  fi
done

audit_application "$application_path"

staging_directory="$release_work_directory/staging"
/bin/mkdir -p "$staging_directory"
/usr/bin/ditto "$application_path" "$staging_directory/Agents Deck.app"
/bin/ln -s /Applications "$staging_directory/Applications"

/usr/bin/hdiutil create \
  -volname "Agents Deck" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$disk_image_path"
/usr/bin/hdiutil verify "$disk_image_path"

/bin/mkdir -p "$mount_directory"
/usr/bin/hdiutil attach "$disk_image_path" -mountpoint "$mount_directory" -nobrowse -readonly -quiet
mounted=1
test -d "$mount_directory/Agents Deck.app"
test -L "$mount_directory/Applications"
audit_application "$mount_directory/Agents Deck.app"
/usr/bin/lipo -archs "$mount_directory/Agents Deck.app/Contents/MacOS/Agents Deck" | /usr/bin/grep -q arm64
/usr/bin/lipo -archs "$mount_directory/Agents Deck.app/Contents/MacOS/Agents Deck" | /usr/bin/grep -q x86_64
/usr/bin/hdiutil detach "$mount_directory" -quiet
mounted=0

checksum="$(/usr/bin/shasum -a 256 "$disk_image_path" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$checksum" "$disk_image_name" > "$checksum_path"

echo "Created $disk_image_path"
echo "Created $checksum_path"
