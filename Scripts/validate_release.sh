#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${ROOT_DIR}/dist/UPreviewX.app"
BIN_PATH="${APP_PATH}/Contents/MacOS/UPreviewX"

if [ ! -x "${BIN_PATH}" ]; then
    echo "Error: ${BIN_PATH} not found. Run ./Scripts/build_app.sh first." >&2
    exit 1
fi

MODE="${1:-}"
if [ -z "${MODE}" ]; then
    if [ "${CI:-false}" = "true" ]; then
        MODE="--smoke"
    else
        MODE="--full"
    fi
fi

FFMPEG="$(command -v ffmpeg || echo "")"
if [ -z "${FFMPEG}" ]; then
    if [ -x "/usr/local/bin/ffmpeg" ]; then
        FFMPEG="/usr/local/bin/ffmpeg"
    elif [ -x "/opt/homebrew/bin/ffmpeg" ]; then
        FFMPEG="/opt/homebrew/bin/ffmpeg"
    else
        echo "Error: ffmpeg not found in PATH or standard locations." >&2
        exit 1
    fi
fi

# Finite timeout runner using Python standard library (no extra dependencies)
run_with_timeout() {
    local timeout_sec="$1"
    shift
    python3 -c '
import subprocess, sys

timeout_sec = float(sys.argv[1])
cmd = sys.argv[2:]

try:
    proc = subprocess.run(cmd, timeout=timeout_sec)
    sys.exit(proc.returncode)
except subprocess.TimeoutExpired:
    cmd_str = " ".join(cmd)
    print(f"\n[FAIL] Command timed out after {timeout_sec:.1f}s: {cmd_str}", file=sys.stderr)
    sys.exit(124)
except Exception as e:
    print(f"\n[FAIL] Execution error: {e}", file=sys.stderr)
    sys.exit(1)
' "${timeout_sec}" "$@"
}

TEST_DIR="$(mktemp -d)"
BENCH_OUT="$(mktemp)"

cleanup() {
    rm -rf "${TEST_DIR:-}" "${BENCH_OUT:-}"
}
trap cleanup EXIT INT TERM

# Record existing PIDs of UPreviewX so we never kill user instances
KNOWN_PIDS="$(pgrep -x UPreviewX 2>/dev/null || true)"

verify_clean_exit() {
    local sleep_sec="${1:-0.5}"
    sleep "${sleep_sec}"
    local current_pids
    current_pids="$(pgrep -x UPreviewX 2>/dev/null || true)"
    local lingering=""
    for pid in ${current_pids}; do
        if ! echo "${KNOWN_PIDS}" | grep -q -w "${pid}"; then
            lingering="${lingering} ${pid}"
        fi
    done

    if [ -n "${lingering}" ]; then
        echo "  [FAIL] Test instance of UPreviewX still running in background: ${lingering}" >&2
        for pid in ${lingering}; do
            kill -9 "${pid}" 2>/dev/null || true
        done
        return 1
    else
        echo "  [PASS] Zero background processes remaining (Clean termination verified)."
        return 0
    fi
}

echo "========================================================"
echo " UPreviewX Release Validation (${MODE})"
echo "========================================================"

echo "==> Creating test vectors in ${TEST_DIR} using ${FFMPEG}..."

# 1. H.264 Landscape 1080p with audio tone
"${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=2" \
    -f lavfi -i "sine=f=440:d=2" \
    -c:v libx264 -pix_fmt yuv420p -preset ultrafast -c:a aac -shortest \
    "${TEST_DIR}/01_h264_landscape_1080p.mp4" >/dev/null 2>&1

# 7. Matroska MKV H.264
"${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=2" \
    -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
    "${TEST_DIR}/07_mkv_landscape_1080p.mkv" >/dev/null 2>&1

if [ "${MODE}" = "--full" ] || [ "${MODE}" = "--benchmark" ]; then
    # 2. H.264 Portrait 9:16 (1080x1920) with audio tone
    "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1080x1920:rate=30:duration=2" \
        -f lavfi -i "sine=f=440:d=2" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast -c:a aac -shortest \
        "${TEST_DIR}/02_h264_portrait_9_16.mp4" >/dev/null 2>&1

    # 3. H.264 Rotated 90° (Display rotation metadata)
    "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=2" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast -metadata:s:v:0 rotate=90 \
        "${TEST_DIR}/03_h264_rotated_90deg.mp4" >/dev/null 2>&1

    # 4. HEVC / H.265 1080p
    "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=2" \
        -f lavfi -i "sine=f=440:d=2" \
        -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -preset ultrafast -c:a aac -shortest \
        "${TEST_DIR}/04_hevc_landscape_1080p.mp4" >/dev/null 2>&1

    # 5. AV1 720p
    if "${FFMPEG}" -encoders 2>/dev/null | grep -q "libsvtav1"; then
        "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1280x720:rate=30:duration=2" \
            -c:v libsvtav1 -pix_fmt yuv420p \
            "${TEST_DIR}/05_av1_landscape_720p.mp4" >/dev/null 2>&1
    fi

    # 6. Apple ProRes 422
    "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1920x1080:rate=24:duration=2" \
        -c:v prores -profile:v 2 -pix_fmt yuv422p10le \
        "${TEST_DIR}/06_prores_1080p.mov" >/dev/null 2>&1

    # 8. WebM VP9 (or VP8 fallback)
    if "${FFMPEG}" -encoders 2>/dev/null | grep -q "libvpx-vp9"; then
        "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1280x720:rate=30:duration=2" \
            -c:v libvpx-vp9 -pix_fmt yuv420p \
            "${TEST_DIR}/08_webm_landscape_720p.webm" >/dev/null 2>&1
    elif "${FFMPEG}" -encoders 2>/dev/null | grep -q "libvpx"; then
        "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=1280x720:rate=30:duration=2" \
            -c:v libvpx -pix_fmt yuv420p \
            "${TEST_DIR}/08_webm_landscape_720p.webm" >/dev/null 2>&1
    fi

    # 9. 4K UHD H.264 (3840x2160)
    "${FFMPEG}" -nostdin -y -f lavfi -i "testsrc=size=3840x2160:rate=30:duration=2" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast \
        "${TEST_DIR}/09_4k_landscape_3840x2160.mp4" >/dev/null 2>&1

    # 10. Corrupted / unsupported media file
    echo "THIS IS CORRUPTED MEDIA DATA" > "${TEST_DIR}/99_corrupt_payload.mp4"
fi

echo "==> Generated $(ls -1 "${TEST_DIR}" | wc -l | tr -d ' ') test vectors."

if [ "${MODE}" = "--full" ] || [ "${MODE}" = "--benchmark" ]; then
    echo "==> Running Automated Benchmark Suite with 90s hard timeout..."
    if ! python3 -c '
import subprocess, sys

cmd = [sys.argv[1], "--benchmark-suite", sys.argv[2]]
with open(sys.argv[3], "w") as out:
    try:
        proc = subprocess.run(cmd, stdout=out, stderr=subprocess.STDOUT, timeout=90)
        sys.exit(proc.returncode)
    except subprocess.TimeoutExpired:
        print("[FAIL] Benchmark suite timed out after 90 seconds!", file=sys.stderr)
        sys.exit(124)
' "${BIN_PATH}" "${TEST_DIR}" "${BENCH_OUT}"; then
        echo "  [FAIL] Benchmark execution exited with non-zero status!" >&2
        cat "${BENCH_OUT}" >&2
        exit 1
    fi

    # Process verification
    echo "==> Verifying zero lingering background processes after benchmark..."
    if ! verify_clean_exit; then
        exit 1
    fi

    # Verify and parse benchmark JSON strictly
    python3 - "${BENCH_OUT}" << 'PYEOF'
import json, re, sys

with open(sys.argv[1]) as f:
    text = f.read()

m = re.search(r'BENCHMARK_JSON_BEGIN\s*(\[.*?\])\s*BENCHMARK_JSON_END', text, re.DOTALL)
if not m:
    print("Error: Benchmark JSON markers not found in output!", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(m.group(1))
except Exception as e:
    print(f"Error: Failed to parse benchmark JSON: {e}", file=sys.stderr)
    sys.exit(1)

print(f"\nBenchmark results summary across {len(data)} test vectors:")
for item in data:
    name = item.get("file", "unknown")
    codec = item.get("codec", "unknown")
    fps = item.get("effectiveFPS", 0)
    first_frame = item.get("firstFrameLatencyMs", 0)
    seek_exact = item.get("seekExactLatencyMs", 0)
    thumb_ms = item.get("thumbnailLatencyMs", 0)
    cpu = item.get("cpuUsagePercent", 0)
    paused_cpu = item.get("pausedCpuPercent", 0)
    rss = item.get("residentMemoryMB", 0)
    hwdec = item.get("hwdecCurrent", "none")
    print(f"  • {name} [{codec}|{hwdec}]: firstFrame={first_frame:.1f}ms, seek={seek_exact:.1f}ms, fps={fps:.1f}, playCPU={cpu:.1f}%, pausedCPU={paused_cpu:.1f}%, thumb={thumb_ms:.1f}ms, rss={rss:.1f}MB")

print("\nBenchmark validation completed successfully.")
PYEOF
fi

# Test CLI on-demand thumbnail generation with finite 10s timeout
echo "==> Testing on-demand CLI thumbnail extraction (with 10s timeout)..."

CLI_THUMB_OUT="${TEST_DIR}/cli_thumb_test.png"
if run_with_timeout 10 "${BIN_PATH}" --thumbnail "${TEST_DIR}/01_h264_landscape_1080p.mp4" "${CLI_THUMB_OUT}" --size 256 >/dev/null 2>&1; then
    if [ -s "${CLI_THUMB_OUT}" ]; then
        echo "  [PASS] CLI thumbnail generated successfully for MP4 ($(wc -c < "${CLI_THUMB_OUT}" | tr -d ' ') bytes)."
    else
        echo "  [FAIL] CLI thumbnail file is empty for MP4!" >&2
        exit 1
    fi
else
    echo "  [FAIL] CLI thumbnail command failed or timed out for MP4!" >&2
    exit 1
fi

CLI_MKV_THUMB="${TEST_DIR}/cli_mkv_thumb.png"
if run_with_timeout 10 "${BIN_PATH}" --thumbnail "${TEST_DIR}/07_mkv_landscape_1080p.mkv" "${CLI_MKV_THUMB}" --size 256 >/dev/null 2>&1; then
    if [ -s "${CLI_MKV_THUMB}" ]; then
        echo "  [PASS] CLI thumbnail generated successfully for MKV fallback ($(wc -c < "${CLI_MKV_THUMB}" | tr -d ' ') bytes)."
    else
        echo "  [FAIL] CLI thumbnail file is empty for MKV!" >&2
        exit 1
    fi
else
    echo "  [FAIL] CLI thumbnail command failed or timed out for MKV!" >&2
    exit 1
fi

# Verify zero lingering background processes after CLI thumbnail
if ! verify_clean_exit; then
    exit 1
fi

echo "========================================================"
echo " RELEASE VALIDATION COMPLETED SUCCESSFULLY!"
echo "========================================================"
