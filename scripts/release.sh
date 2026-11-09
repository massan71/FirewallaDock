#!/bin/bash
# Build, verify and publish a FirewallaDock release on GitHub.
#
#   scripts/release.sh <version> <notes.md> [--yes]
#
#   <version>   e.g. 1.3 or 1.3.1 (the tag will be v<version>)
#   <notes.md>  release notes ("What's new"); the install steps and the
#               zip's SHA-256 are appended automatically
#   --yes       publish without asking for confirmation
#
# Steps: checks the repository, sets the version (build number + 1), builds a
# clean universal Release, zips it without Finder/iCloud attributes, verifies the
# unzipped app, then (after confirmation) commits, tags, pushes and creates the
# GitHub release. Nothing is pushed if any check fails.
#
# Optional: RELEASE_COMMIT_TRAILER is appended to the release commit message.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
NOTES="${2:-}"
YES="${3:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "usage: scripts/release.sh <version> <notes.md> [--yes]"
[[ -f "$NOTES" ]] || die "notes file not found: $NOTES"
NOTES="$(cd "$(dirname "$NOTES")" && pwd)/$(basename "$NOTES")"
TAG="v$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PBX="FirewallaDock.xcodeproj/project.pbxproj"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# --- Repository checks -------------------------------------------------------
command -v gh >/dev/null || die "GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"
[[ "$(git branch --show-current)" == "main" ]] || die "not on main"
[[ -z "$(git status --porcelain)" ]] || die "working tree has uncommitted changes"
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not in sync with origin/main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on GitHub"

# --- Version -----------------------------------------------------------------
OLD_BUILD="$(grep -m1 -Eo 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBX" | grep -Eo '[0-9]+')"
BUILD=$((OLD_BUILD + 1))
restore() { git checkout -q -- "$PBX"; }
trap 'echo "Aborted: version change reverted." >&2; restore' ERR INT
sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = $VERSION;/g; s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PBX"
echo "Version $VERSION (build $BUILD)"

# --- Build -------------------------------------------------------------------
OUT="build/release"
rm -rf "$OUT"
echo "Building universal Release…"
xcodebuild -project FirewallaDock.xcodeproj -scheme FirewallaDock -configuration Release \
  -derivedDataPath "$OUT/DerivedData" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO clean build -quiet

# Finder/iCloud extended attributes break the signature check, so copy without them
mkdir -p "$OUT/stage"
ditto --norsrc --noextattr --noacl "$OUT/DerivedData/Build/Products/Release/FirewallaDock.app" "$OUT/stage/FirewallaDock.app"
ZIP="$OUT/FirewallaDock-$VERSION.zip"
ditto -c -k --norsrc --noextattr --keepParent "$OUT/stage/FirewallaDock.app" "$ZIP"

# --- Verify the unzipped app -------------------------------------------------
CHECK="$(mktemp -d)"
ditto -x -k "$ZIP" "$CHECK"
APP="$CHECK/FirewallaDock.app"
codesign --verify --deep --strict "$APP" || die "signature check failed"
ENT="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
grep -q app-sandbox <<<"$ENT" || die "sandbox entitlement missing"
grep -q network.client <<<"$ENT" || die "network entitlement missing"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/FirewallaDock")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || die "not a universal binary: $ARCHS"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$VERSION" ]] || die "app reports version $APP_VERSION"
rm -rf "$CHECK"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "Verified: signature, sandbox, $ARCHS, version $APP_VERSION"
echo "$ZIP ($(du -h "$ZIP" | cut -f1)) SHA-256 $SHA"

# --- Release notes -----------------------------------------------------------
FULL_NOTES="$OUT/notes.md"
{
  cat "$NOTES"
  cat <<EOF

## Install

1. Download \`FirewallaDock-$VERSION.zip\`, unzip it and move \`FirewallaDock.app\` to \`/Applications\` (replace the old version).
2. **This build is not notarized** (ad-hoc signed, no Apple Developer ID). The first time, macOS blocks it: go to **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 14 or later. Universal binary (Apple Silicon and Intel).

SHA-256 of \`FirewallaDock-$VERSION.zip\`:
\`$SHA\`

This project is independent and not affiliated with Firewalla Inc.
EOF
} > "$FULL_NOTES"

# --- Publish -----------------------------------------------------------------
if [[ "$YES" != "--yes" ]]; then
  read -r -p "Commit, tag and publish $TAG on GitHub? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { restore; echo "Not published; version change reverted."; exit 1; }
fi
trap - ERR INT

MESSAGE="Release $VERSION"
[[ -n "${RELEASE_COMMIT_TRAILER:-}" ]] && MESSAGE="$MESSAGE"$'\n\n'"$RELEASE_COMMIT_TRAILER"
git commit -q -m "$MESSAGE" -- "$PBX"
git tag -a "$TAG" -m "FirewallaDock $VERSION"
git push -q origin main
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "FirewallaDock $VERSION" --notes-file "$FULL_NOTES" --verify-tag

# Confirm GitHub has the same file
REMOTE_SHA="$(gh release view "$TAG" --json assets --jq '.assets[0].digest' | sed 's/^sha256://')"
[[ "$REMOTE_SHA" == "$SHA" ]] || die "uploaded file checksum differs: $REMOTE_SHA"
echo "Published $TAG: $(gh release view "$TAG" --json url --jq .url)"
