#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
ARCH="${ARCH:-x86_64}"
VERSION="${VERSION:-0.3.0}"
BUILD_NUM="${BUILD_NUM:-3}"

"${ROOT_DIR}/Scripts/prepare_libs.sh"

echo "==> Building UPreviewX (${CONFIG}, ${ARCH})..."
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
chmod 755 "${MACOS_DIR}/UPreviewX"
cp "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

ICON_PNG="${ROOT_DIR}/Resources/AppIcon.png"
ICON_ICNS="${ROOT_DIR}/Resources/AppIcon.icns"
if [ -f "${ICON_PNG}" ] && { [ ! -f "${ICON_ICNS}" ] || [ "${ICON_PNG}" -nt "${ICON_ICNS}" ]; }; then
    echo "==> Regenerating AppIcon.icns from AppIcon.png..."
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

# Set version metadata
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${CONTENTS_DIR}/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD_NUM}" "${CONTENTS_DIR}/Info.plist"

# Remove local developer build rpath from packaged binary so it strictly uses @executable_path/../Frameworks
install_name_tool -delete_rpath "${ROOT_DIR}/Vendor/lib" "${MACOS_DIR}/UPreviewX" 2>/dev/null || true

echo "==> Bundling runtime libraries into ${FRAMEWORKS_DIR}..."
for dylib in "${ROOT_DIR}/Vendor/lib"/*.dylib; do
    if [ ! -L "${dylib}" ]; then
        cp -f "${dylib}" "${FRAMEWORKS_DIR}/"
        chmod 755 "${FRAMEWORKS_DIR}/$(basename "${dylib}")"
    fi
done

# Ensure libmpv.dylib symlink exists inside Frameworks if needed
if [ -f "${FRAMEWORKS_DIR}/libmpv.2.dylib" ] && [ ! -e "${FRAMEWORKS_DIR}/libmpv.dylib" ]; then
    (cd "${FRAMEWORKS_DIR}" && ln -sf libmpv.2.dylib libmpv.dylib)
fi

echo "==> Stripping leaked development and Homebrew rpaths from bundled libraries..."
python3 - "${FRAMEWORKS_DIR}" <<'PYEOF'
import os, subprocess, sys

fw_dir = sys.argv[1]
for f in os.listdir(fw_dir):
    p = os.path.join(fw_dir, f)
    if os.path.isfile(p) and not os.path.islink(p) and f.endswith(".dylib"):
        rpath_out = subprocess.check_output(["otool", "-l", p], text=True)
        for line in rpath_out.splitlines():
            l_str = line.strip()
            if l_str.startswith("path /") and ("cellar" in l_str.lower() or "homebrew" in l_str.lower() or "/usr/local" in l_str or "documents/agy" in l_str.lower()):
                leaked_rpath = l_str.split("path ")[1].split(" (offset")[0].strip()
                subprocess.run(["install_name_tool", "-delete_rpath", leaked_rpath, p], check=False)
PYEOF

echo "==> Signing UPreviewX.app bundle (ad-hoc)..."
for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    if [ ! -L "${dylib}" ]; then
        codesign --force --sign - --timestamp=none "${dylib}"
    fi
done
codesign --force --deep --sign - --timestamp=none "${APP_DIR}"

echo "==> Successfully built standalone app bundle at: ${APP_DIR}"
