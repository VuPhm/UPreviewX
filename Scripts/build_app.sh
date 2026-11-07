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

