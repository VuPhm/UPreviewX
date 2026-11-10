#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_LIB_DIR="${ROOT_DIR}/Vendor/lib"
mkdir -p "${VENDOR_LIB_DIR}"

if [ -f "${VENDOR_LIB_DIR}/libmpv.2.dylib" ] && [ -L "${VENDOR_LIB_DIR}/libmpv.dylib" ]; then
    echo "Vendor/lib already prepared."
    exit 0
fi

SOURCE_FW_DIR="${MPV_FRAMEWORK_SOURCE:-/Applications/IINA.app/Contents/Frameworks}"

if [ -f "${SOURCE_FW_DIR}/libmpv.2.dylib" ]; then
    echo "Bundling and thinning x86_64 libmpv runtime libraries from ${SOURCE_FW_DIR}..."
    for dylib in "${SOURCE_FW_DIR}"/*.dylib; do
        base="$(basename "${dylib}")"
        if [[ "${base}" == libswift* ]]; then
            continue
        fi
        target="${VENDOR_LIB_DIR}/${base}"
        if lipo -info "${dylib}" 2>/dev/null | grep -q "Non-fat file"; then
            cp -f "${dylib}" "${target}"
        elif lipo -archs "${dylib}" 2>/dev/null | grep -q "x86_64"; then
            lipo -thin x86_64 "${dylib}" -output "${target}"
        else
            cp -f "${dylib}" "${target}"
        fi
        chmod 755 "${target}"
    done
elif command -v brew >/dev/null 2>&1 && brew --prefix mpv >/dev/null 2>&1; then
    MPV_PREFIX="$(brew --prefix mpv)"
    echo "Bundling libmpv runtime libraries from Homebrew (${MPV_PREFIX})..."
    MPV_DYLIB=""
    if [ -f "${MPV_PREFIX}/lib/libmpv.2.dylib" ]; then
        MPV_DYLIB="${MPV_PREFIX}/lib/libmpv.2.dylib"
    elif [ -f "${MPV_PREFIX}/lib/libmpv.dylib" ]; then
        MPV_DYLIB="${MPV_PREFIX}/lib/libmpv.dylib"
    elif [ -f "/usr/local/lib/libmpv.2.dylib" ]; then
        MPV_DYLIB="/usr/local/lib/libmpv.2.dylib"
    elif [ -f "/usr/local/lib/libmpv.dylib" ]; then
        MPV_DYLIB="/usr/local/lib/libmpv.dylib"
    fi

    if [ -z "${MPV_DYLIB}" ]; then
        echo "Error: Could not find libmpv.2.dylib or libmpv.dylib in Homebrew prefix: ${MPV_PREFIX}" >&2
        exit 1
    fi

    python3 - "${MPV_DYLIB}" "${VENDOR_LIB_DIR}" <<'PYEOF'
import os, shutil, subprocess, sys

root_dylib = os.path.realpath(sys.argv[1])
dest_dir = sys.argv[2]
visited = {}
queue = [("libmpv.2.dylib", root_dylib)]

while queue:
    install_name, real_path = queue.pop(0)
    if install_name in visited:
        continue
    target_path = os.path.join(dest_dir, install_name)
    shutil.copy2(real_path, target_path)
    os.chmod(target_path, 0o755)
    visited[install_name] = target_path

    out = subprocess.check_output(["otool", "-L", target_path], text=True)
    subprocess.check_call(["install_name_tool", "-id", f"@rpath/{install_name}", target_path])
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ")[0]
        if dep.startswith("/usr/local/") or dep.startswith("/opt/homebrew/") or dep.startswith("@rpath/"):
            dep_base = os.path.basename(dep)
            subprocess.check_call(["install_name_tool", "-change", dep, f"@rpath/{dep_base}", target_path])
            if dep.startswith("/"):
                dep_real = os.path.realpath(dep)
            else:
                # Resolve relative to Homebrew lib dir
                brew_lib = os.path.dirname(os.path.dirname(os.path.dirname(root_dylib)))
                dep_real = os.path.realpath(os.path.join(brew_lib, "lib", dep_base))
            if os.path.exists(dep_real) and dep_base not in visited:
                queue.append((dep_base, dep_real))

    # Strip any leaked development/Cellar LC_RPATH entries
    rpath_out = subprocess.check_output(["otool", "-l", target_path], text=True)
    for line in rpath_out.splitlines():
        l_str = line.strip()
        if l_str.startswith("path /") and ("cellar" in l_str.lower() or "homebrew" in l_str.lower() or "/usr/local" in l_str or "documents/agy" in l_str.lower()):
            leaked_rpath = l_str.split("path ")[1].split(" (offset")[0].strip()
            subprocess.run(["install_name_tool", "-delete_rpath", leaked_rpath, target_path], check=False)
PYEOF
else
    echo "Error: Could not find libmpv.2.dylib in ${SOURCE_FW_DIR} or Homebrew." >&2
    exit 1
fi

ln -sf libmpv.2.dylib "${VENDOR_LIB_DIR}/libmpv.dylib"

echo "Signing dylibs in ${VENDOR_LIB_DIR}..."
for dylib in "${VENDOR_LIB_DIR}"/*.dylib; do
    if [ ! -L "${dylib}" ]; then
        codesign --force --sign - --timestamp=none "${dylib}" 2>/dev/null || true
    fi
done

echo "Prepared $(ls -1 "${VENDOR_LIB_DIR}"/*.dylib | wc -l | tr -d ' ') dylib files in Vendor/lib."

