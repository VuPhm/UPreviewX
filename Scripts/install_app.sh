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

echo "==> Removing stale installations and LaunchServices entries..."
if [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -u "${TARGET_APP}" 2>/dev/null || true
    "${LSREGISTER}" -u "/Applications/${APP_NAME}" 2>/dev/null || true
    "${LSREGISTER}" -u "${DIST_APP}" 2>/dev/null || true
fi

rm -rf "${TARGET_APP}"
if [ -d "/Applications/${APP_NAME}" ] && [ -w "/Applications" ]; then
    rm -rf "/Applications/${APP_NAME}"
fi

mkdir -p "${USER_APPS_DIR}"
echo "==> Installing clean bundle to ${TARGET_APP}..."
ditto "${DIST_APP}" "${TARGET_APP}"
xattr -cr "${TARGET_APP}" 2>/dev/null || true
touch "${TARGET_APP}"

echo "==> Verifying code signature..."
codesign --verify --deep --strict "${TARGET_APP}"

if [ -x "${LSREGISTER}" ]; then
    echo "==> Registering ${TARGET_APP} with macOS LaunchServices..."
    # Unregister build output copy so LaunchServices strictly resolves to ~/Applications/UPreviewX.app
    "${LSREGISTER}" -u "${DIST_APP}" 2>/dev/null || true
    "${LSREGISTER}" -f -R -trusted "${TARGET_APP}"
fi

echo "==> Refreshing macOS icon & Finder/Dock caches..."
swift -e '
import AppKit
let path = CommandLine.arguments[1]
NSWorkspace.shared.noteFileSystemChanged(path)
' "${TARGET_APP}" 2>/dev/null || true

killall iconservicesagent 2>/dev/null || true
killall Dock 2>/dev/null || true
killall Finder 2>/dev/null || true

echo "==> Successfully installed UPreviewX to: ${TARGET_APP}"
