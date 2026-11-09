#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/UPreviewX.app"

VERSION="${VERSION:-0.3.0}"
ARCH="${ARCH:-x86_64}"
PKG_NAME="UPreviewX-v${VERSION}-macos-${ARCH}"

DMG_FILE="${DIST_DIR}/${PKG_NAME}.dmg"
ZIP_FILE="${DIST_DIR}/${PKG_NAME}.zip"
CHECKSUM_FILE="${DIST_DIR}/SHA256SUMS"

echo "========================================================"
echo " Packaging UPreviewX Distribution: ${PKG_NAME}"
echo "========================================================"

# Step 1: Build the clean standalone app bundle
VERSION="${VERSION}" ARCH="${ARCH}" "${ROOT_DIR}/Scripts/build_app.sh" release

if [ ! -d "${APP_DIR}" ]; then
    echo "Error: ${APP_DIR} does not exist!" >&2
    exit 1
fi

# Step 2: Verify code signature before packaging
echo "==> Verifying app bundle code signature..."
codesign --verify --deep --strict "${APP_DIR}"

# Step 3: Create portable ZIP archive
echo "==> Creating portable distribution ZIP: ${ZIP_FILE}..."
rm -f "${ZIP_FILE}"
(cd "${DIST_DIR}" && ditto -c -k --keepParent --sequesterRsrc "UPreviewX.app" "${ZIP_FILE}")

# Step 4: Create drag-and-drop DMG
echo "==> Creating drag-and-drop DMG: ${DMG_FILE}..."
rm -f "${DMG_FILE}"
DMG_STAGING="$(mktemp -d)/UPreviewX-DMG"
mkdir -p "${DMG_STAGING}"

echo "==> Copying app bundle and Applications symlink into DMG staging..."
ditto "${APP_DIR}" "${DMG_STAGING}/UPreviewX.app"
ln -s /Applications "${DMG_STAGING}/Applications"

# Add a user-friendly README text in the DMG
cat << 'EOF' > "${DMG_STAGING}/ReadMe (Gatekeeper).txt"
UPreviewX — Native Lightweight macOS Video Preview Utility

INSTALLATION:
1. Drag "UPreviewX.app" into the "Applications" folder.
2. Eject this disk image.

FIRST LAUNCH ON macOS (Gatekeeper / Apple Unidentified Developer):
UPreviewX is distributed as open-source software with valid ad-hoc code
signing without an Apple Developer ID subscription.

On first launch, if macOS displays:
  "UPreviewX cannot be opened because Apple cannot check it for malicious software"
Follow Apple's standard procedure:
  1. Open Finder -> Go to Applications.
  2. Right-click (or Control-click) "UPreviewX.app" and choose "Open".
  3. Click "Open" in the security prompt.
  Or open System Settings -> Privacy & Security -> Security section -> Click "Open Anyway".

After opening once, macOS remembers the approval and UPreviewX opens normally
via double-click or "Open With".
EOF

echo "==> Building compressed DMG..."
hdiutil create -volname "UPreviewX" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDZO \
    "${DMG_FILE}"

rm -rf "$(dirname "${DMG_STAGING}")"

echo "==> Signing DMG (ad-hoc)..."
codesign --force --sign - --timestamp=none "${DMG_FILE}"

# Step 5: Generate SHA256 checksums
echo "==> Generating SHA256 checksums..."
(
    cd "${DIST_DIR}"
    shasum -a 256 "$(basename "${DMG_FILE}")" "$(basename "${ZIP_FILE}")" > "${CHECKSUM_FILE}"
)

echo "==> Checksums generated:"
cat "${CHECKSUM_FILE}"

echo "========================================================"
echo " Distribution Package Ready:"
echo "   DMG:      ${DMG_FILE}"
echo "   ZIP:      ${ZIP_FILE}"
echo "   Checksum: ${CHECKSUM_FILE}"
echo "========================================================"
