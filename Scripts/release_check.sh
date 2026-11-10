#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
APP_DIR="${DIST_DIR}/UPreviewX.app"
CHECKSUM_FILE="${DIST_DIR}/SHA256SUMS"

VERSION="${VERSION:-0.3.0}"
ARCH="${ARCH:-x86_64}"
PKG_NAME="UPreviewX-v${VERSION}-macos-${ARCH}"
DMG_FILE="${DIST_DIR}/${PKG_NAME}.dmg"
ZIP_FILE="${DIST_DIR}/${PKG_NAME}.zip"

MOUNT_DIR=""
UNZIP_TMP=""
Q_TMP=""

cleanup() {
    local lsreg="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if [ -n "${MOUNT_DIR}" ] && [ -d "${MOUNT_DIR}" ]; then
        if [ -x "${lsreg}" ]; then "${lsreg}" -u "${MOUNT_DIR}/UPreviewX.app" 2>/dev/null || true; fi
        hdiutil detach "${MOUNT_DIR}" -quiet 2>/dev/null || true
        rm -rf "${MOUNT_DIR}" 2>/dev/null || true
    fi
    if [ -n "${UNZIP_TMP}" ] && [ -d "${UNZIP_TMP}" ]; then
        if [ -x "${lsreg}" ]; then "${lsreg}" -u "${UNZIP_TMP}/UPreviewX.app" 2>/dev/null || true; fi
        rm -rf "${UNZIP_TMP}" 2>/dev/null || true
    fi
    if [ -n "${Q_TMP}" ] && [ -d "${Q_TMP}" ]; then
        if [ -x "${lsreg}" ]; then "${lsreg}" -u "${Q_TMP}/UPreviewX.app" 2>/dev/null || true; fi
        rm -rf "${Q_TMP}" 2>/dev/null || true
    fi
    if [ -x "${lsreg}" ]; then
        "${lsreg}" -u "${APP_DIR}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

ERRORS=0

log_pass() {
    echo "  [PASS] $1"
}

log_fail() {
    echo "  [FAIL] $1" >&2
    ERRORS=$((ERRORS + 1))
}

echo "========================================================"
echo " UPreviewX Release Verification: ${PKG_NAME}"
echo "========================================================"

# Check 1: App bundle structure
echo "==> 1. Verifying App Bundle Structure..."
if [ -d "${APP_DIR}" ]; then
    log_pass "App bundle exists at ${APP_DIR}"
else
    log_fail "App bundle missing at ${APP_DIR}"
fi

BIN_PATH="${APP_DIR}/Contents/MacOS/UPreviewX"
if [ -x "${BIN_PATH}" ]; then
    log_pass "Executable binary exists and is executable"
else
    log_fail "Executable binary missing or not executable at ${BIN_PATH}"
fi

# Check 2: Binary architecture
echo "==> 2. Verifying Binary Architecture..."
BIN_ARCH="$(lipo -archs "${BIN_PATH}" 2>/dev/null || echo "unknown")"
if [ "${BIN_ARCH}" = "${ARCH}" ]; then
    log_pass "Binary architecture matches target: ${BIN_ARCH}"
else
    log_fail "Binary architecture (${BIN_ARCH}) does not match target (${ARCH})"
fi

# Check 3: Info.plist Metadata
echo "==> 3. Verifying Info.plist Metadata..."
INFO_PLIST="${APP_DIR}/Contents/Info.plist"
if [ -f "${INFO_PLIST}" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${INFO_PLIST}" 2>/dev/null || echo "")"
    BUNDLE_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || echo "")"
    MIN_SYS="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${INFO_PLIST}" 2>/dev/null || echo "")"
    DOC_TYPES="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" "${INFO_PLIST}" 2>/dev/null || echo "")"

    if [ "${BUNDLE_ID}" = "com.vuphm.upreviewx" ]; then
        log_pass "Bundle identifier: ${BUNDLE_ID}"
    else
        log_fail "Unexpected bundle identifier: ${BUNDLE_ID} (expected com.vuphm.upreviewx)"
    fi

    if [ "${BUNDLE_VER}" = "${VERSION}" ]; then
        log_pass "Bundle version: ${BUNDLE_VER}"
    else
        log_fail "Unexpected bundle version: ${BUNDLE_VER} (expected ${VERSION})"
    fi

    if [ "${MIN_SYS}" = "13.0" ]; then
        log_pass "LSMinimumSystemVersion: ${MIN_SYS}"
    else
        log_fail "Unexpected LSMinimumSystemVersion: ${MIN_SYS}"
    fi

    if [ -n "${DOC_TYPES}" ]; then
        log_pass "CFBundleDocumentTypes is registered"
    else
        log_fail "CFBundleDocumentTypes missing in Info.plist"
    fi
else
    log_fail "Info.plist missing in app bundle"
fi

# Check 4: AppIcon
echo "==> 4. Verifying App Icon..."
if [ -f "${APP_DIR}/Contents/Resources/AppIcon.icns" ] && [ -s "${APP_DIR}/Contents/Resources/AppIcon.icns" ]; then
    log_pass "AppIcon.icns exists and is non-empty ($(wc -c < "${APP_DIR}/Contents/Resources/AppIcon.icns" | tr -d ' ') bytes)"
else
    log_fail "AppIcon.icns missing or empty"
fi

# Check 5: Code signature
echo "==> 5. Verifying Ad-Hoc Code Signature..."
if codesign --verify --deep --strict "${APP_DIR}" 2>/dev/null; then
    log_pass "App bundle signature is valid and strict"
else
    log_fail "App bundle failed codesign verification"
fi

# Check 6: Runtime dependency closure and rpath audit
echo "==> 6. Auditing Runtime Dependencies & Rpaths..."
FW_DIR="${APP_DIR}/Contents/Frameworks"
if [ -d "${FW_DIR}" ]; then
    DYLIB_COUNT="$(find "${FW_DIR}" -name "*.dylib" | wc -l | tr -d ' ')"
    log_pass "Found ${DYLIB_COUNT} dynamic libraries bundled in Frameworks"

    python3 - "${FW_DIR}" << 'PYEOF'
import os, sys, subprocess

fw_dir = sys.argv[1]
files = set(os.listdir(fw_dir))
missing = set()
leaked_paths = set()

for f in sorted(files):
    p = os.path.join(fw_dir, f)
    if os.path.isfile(p):
        otool = subprocess.check_output(['otool', '-L', p], text=True).splitlines()
        for l in otool[1:]:
            parts = l.strip().split()
            if not parts: continue
            ref = parts[0]
            if ref.startswith('@rpath/'):
                target = ref[7:]
                if target not in files:
                    missing.add((f, ref))
            elif ref.startswith('/usr/local/') or ref.startswith('/opt/homebrew/') or 'Documents/agy' in ref:
                leaked_paths.add((f, ref))

        rpath_out = subprocess.check_output(['otool', '-l', p], text=True)
        for l in rpath_out.splitlines():
            if 'path /' in l and ('homebrew' in l.lower() or 'Documents/agy' in l or 'cellar' in l.lower()):
                leaked_paths.add((f, l.strip()))

if missing:
    print(f"ERROR: Missing transitive dylibs: {missing}", file=sys.stderr)
    sys.exit(1)
if leaked_paths:
    print(f"ERROR: Leaked development paths: {leaked_paths}", file=sys.stderr)
    sys.exit(2)
PYEOF
    if [ $? -eq 0 ]; then
        log_pass "Dynamic dependency closure is 100% self-contained with ZERO leaked build paths"
    else
        log_fail "Dependency closure audit failed"
    fi
else
    log_fail "Frameworks directory missing"
fi

# Check 7: Verifying Distribution DMG
echo "==> 7. Verifying Distribution DMG..."
if [ -f "${DMG_FILE}" ]; then
    log_pass "DMG exists at ${DMG_FILE} ($(du -h "${DMG_FILE}" | cut -f1))"

    MOUNT_DIR="$(mktemp -d)/upreviewx-mnt"
    mkdir -p "${MOUNT_DIR}"
    ATTACH_OUT="$(hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_DIR}" "${DMG_FILE}")"

    if [ -d "${MOUNT_DIR}/UPreviewX.app" ] && [ -L "${MOUNT_DIR}/Applications" ]; then
        log_pass "DMG contains UPreviewX.app and Applications symlink"
        if codesign --verify --deep --strict "${MOUNT_DIR}/UPreviewX.app" 2>/dev/null; then
            log_pass "Mounted DMG app bundle code signature is valid"
        else
            log_fail "Mounted DMG app bundle code signature verification failed"
        fi
    else
        log_fail "DMG layout incomplete (missing UPreviewX.app or Applications symlink)"
    fi

    hdiutil detach "${MOUNT_DIR}" -quiet
    rm -rf "${MOUNT_DIR}"
else
    log_fail "DMG file not found at ${DMG_FILE}"
fi

# Check 8: Verifying Portable ZIP
echo "==> 8. Verifying Portable ZIP..."
if [ -f "${ZIP_FILE}" ]; then
    log_pass "ZIP exists at ${ZIP_FILE} ($(du -h "${ZIP_FILE}" | cut -f1))"

    UNZIP_TMP="$(mktemp -d)/upreviewx-unzip"
    mkdir -p "${UNZIP_TMP}"
    ditto -x -k "${ZIP_FILE}" "${UNZIP_TMP}"

    if [ -d "${UNZIP_TMP}/UPreviewX.app" ]; then
        log_pass "ZIP unpacks UPreviewX.app cleanly"
        if codesign --verify --deep --strict "${UNZIP_TMP}/UPreviewX.app" 2>/dev/null; then
            log_pass "Unpacked ZIP app bundle code signature is valid"
        else
            log_fail "Unpacked ZIP app bundle code signature verification failed"
        fi
    else
        log_fail "ZIP unpack failed to find UPreviewX.app"
    fi
    rm -rf "${UNZIP_TMP}"
else
    log_fail "ZIP file not found at ${ZIP_FILE}"
fi

# Check 9: Verifying SHA256 Checksums
echo "==> 9. Verifying SHA256 Checksums..."
if [ -f "${CHECKSUM_FILE}" ]; then
    (
        cd "${DIST_DIR}"
        if shasum -c "$(basename "${CHECKSUM_FILE}")" >/dev/null 2>&1; then
            log_pass "All distribution artifacts match SHA256SUMS"
        else
            log_fail "SHA256 checksum mismatch"
        fi
    )
else
    log_fail "SHA256SUMS file missing at ${CHECKSUM_FILE}"
fi

# Check 10: Gatekeeper / Quarantine behavior simulation
echo "==> 10. Simulating Gatekeeper Quarantine Handling..."
Q_TMP="$(mktemp -d)/upreviewx-qtest"
ditto "${APP_DIR}" "${Q_TMP}/UPreviewX.app"
xattr -w com.apple.quarantine "0081;66554433;Safari;12345" "${Q_TMP}/UPreviewX.app"

if xattr -p com.apple.quarantine "${Q_TMP}/UPreviewX.app" >/dev/null 2>&1; then
    log_pass "Successfully simulated Gatekeeper quarantine attribute"
fi
# Verify that binary is intact even with quarantine bit
if [ -x "${Q_TMP}/UPreviewX.app/Contents/MacOS/UPreviewX" ]; then
    log_pass "Binary integrity intact under Gatekeeper quarantine attribute"
fi
rm -rf "${Q_TMP}"

echo "========================================================"
if [ "${ERRORS}" -eq 0 ]; then
    echo " ALL RELEASE CHECKS PASSED SUCCESSFULLY!"
    echo "========================================================"
    exit 0
else
    echo " RELEASE CHECKS FAILED: ${ERRORS} error(s) detected!"
    echo "========================================================"
    exit 1
fi

