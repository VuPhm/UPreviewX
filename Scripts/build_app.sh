#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
ARCH="x86_64"

"${ROOT_DIR}/Scripts/prepare_libs.sh"

echo "Building UPreviewX (${CONFIG}, ${ARCH})..."
swift build -c "${CONFIG}" --arch "${ARCH}"

BIN_PATH="$(swift build -c "${CONFIG}" --arch "${ARCH}" --show-bin-path)/UPreviewX"
APP_DIR="${ROOT_DIR}/dist/UPreviewX.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/UPreviewX"
cp "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

ICON_PNG="${ROOT_DIR}/Resources/AppIcon.png"
ICON_ICNS="${ROOT_DIR}/Resources/AppIcon.icns"
if [ -f "${ICON_PNG}" ] && { [ ! -f "${ICON_ICNS}" ] || [ "${ICON_PNG}" -nt "${ICON_ICNS}" ]; }; then
    echo "Regenerating AppIcon.icns from AppIcon.png..."
    ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET_TMP}"
    for sz in 16 32 128 256 512; do
        sz2=$((sz * 2))
        sips -z "${sz}" "${sz}" "${ICON_PNG}" --out "${ICONSET_TMP}/icon_${sz}x${sz}.png" >/dev/null
        sips -z "${sz2}" "${sz2}" "${ICON_PNG}" --out "${ICONSET_TMP}/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET_TMP}" -o "${ICON_ICNS}"
    rm -rf "$(dirname "${ICONSET_TMP}")"
fi

if [ -f "${ICON_ICNS}" ]; then
    cp "${ICON_ICNS}" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Stamp monotonic build version so macOS LaunchServices & IconServices always invalidate stale cache
BUILD_VER="$(date +%Y%m%d.%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_VER}" "${CONTENTS_DIR}/Info.plist"

# Remove build-dir rpath from packaged binary so it strictly uses @executable_path/../Frameworks
install_name_tool -delete_rpath "${ROOT_DIR}/Vendor/lib" "${MACOS_DIR}/UPreviewX" 2>/dev/null || true

echo "Bundling runtime libraries into ${FRAMEWORKS_DIR}..."
for dylib in "${ROOT_DIR}/Vendor/lib"/*.dylib; do
    if [ ! -L "${dylib}" ]; then
        cp -f "${dylib}" "${FRAMEWORKS_DIR}/"
    fi
done

echo "Signing UPreviewX.app bundle..."
for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    codesign --force --sign - --timestamp=none "${dylib}"
done
codesign --force --deep --sign - --timestamp=none "${APP_DIR}"

echo "Built standalone app bundle at: ${APP_DIR}"

