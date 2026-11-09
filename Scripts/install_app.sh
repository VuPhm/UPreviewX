#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="UPreviewX.app"
DIST_APP="${ROOT_DIR}/dist/${APP_NAME}"
USER_APPS_DIR="${INSTALL_DIR:-${HOME}/Applications}"
TARGET_APP="${USER_APPS_DIR}/${APP_NAME}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DO_CLEAN=0
DO_BUILD=1

for arg in "$@"; do
    case "${arg}" in
        --clean)
            DO_CLEAN=1
            ;;
        --no-build)
            DO_BUILD=0
            ;;
    esac
done

echo "==> Stopping any running UPreviewX instances..."
killall UPreviewX 2>/dev/null || true

if [ "${DO_CLEAN}" -eq 1 ]; then
    echo "==> Cleaning previous build artifacts..."
    (cd "${ROOT_DIR}" && swift package clean)
    rm -rf "${ROOT_DIR}/.build" "${ROOT_DIR}/dist"
fi

if [ "${DO_BUILD}" -eq 1 ] || [ ! -d "${DIST_APP}" ]; then
    echo "==> Building release bundle..."
    "${ROOT_DIR}/Scripts/build_app.sh" release
fi

echo "==> Removing stale bundle at ${TARGET_APP}..."
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -u "${TARGET_APP}" 2>/dev/null || true
    "${LSREGISTER}" -u "${DIST_APP}" 2>/dev/null || true
fi

rm -rf "${TARGET_APP}"

mkdir -p "${USER_APPS_DIR}"
echo "==> Installing clean bundle to ${TARGET_APP}..."
ditto "${DIST_APP}" "${TARGET_APP}"
touch "${TARGET_APP}"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "${TARGET_APP}"

if [ -x "${LSREGISTER}" ]; then
    echo "==> Registering ${TARGET_APP} with macOS LaunchServices..."
    "${LSREGISTER}" -u "${DIST_APP}" 2>/dev/null || true
    "${LSREGISTER}" -f -R -trusted "${TARGET_APP}"
fi

echo "==> Notifying macOS file system and LaunchServices..."
swift -e '
import AppKit
let path = CommandLine.arguments[1]
NSWorkspace.shared.noteFileSystemChanged(path)
' "${TARGET_APP}" 2>/dev/null || true

echo "==> Successfully installed UPreviewX to: ${TARGET_APP}"
echo "==> User preferences preserved in ~/Library/Preferences/com.vuphm.upreviewx.plist"
