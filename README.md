# UPreviewX

**UPreviewX** is a lightweight, native macOS video preview utility (`Swift` + `AppKit`, `x86_64`) optimized for the **Intel MacBook Pro 16-inch (2019)** (Intel Core i7-9750H, 16 GB RAM, Intel UHD Graphics 630 + AMD Radeon Pro 5300M).

It delivers a fast, minimal, single-window preview experience similar to QuickTime / QuickLook while leveraging **libmpv + FFmpeg + VideoToolbox + dav1d** (the playback foundation of IINA) for broad codec and container compatibility.

---

## Key Features & UX

- **Direct Video Window (No Home Screen)**: Double-clicking a supported video in Finder or using **Open With → UPreviewX** opens the video window immediately and begins playback.
- **Quit-on-Last-Window-Close Lifecycle**: Closing the video window terminates the application completely (`applicationShouldTerminateAfterLastWindowClosed = true`). It never remains resident in the background.
- **Unobtrusive Auto-Hiding HUD**: Translucent floating controls (Play/Pause, interactive timeline scrubber, elapsed/duration time, Mute, Volume, Diagnostics toggle, Fullscreen toggle) and window traffic lights automatically fade out after 2 seconds of cursor inactivity during playback.
- **Dual-GPU Power Awareness (MBP 2019)**: Configures both `NSSupportsAutomaticGraphicsSwitching` in `Info.plist` and `kCGLPFASupportsAutomaticGraphicsSwitching` + `kCGLPFAAllowOfflineRenderers` on its `CAOpenGLLayer` context so previewing videos stays on the integrated **Intel UHD Graphics 630** instead of unnecessarily waking the discrete **AMD Radeon Pro 5300M**.
- **Developer Decoder Diagnostics (`D` or `Cmd+I`)**: Built-in real-time overlay reporting container, codec, pixel format, active decode path (`Hardware (videotoolbox)` vs. `Software (FFmpeg/dav1d fallback)`), active GPU renderer, resolution, nominal/estimated FPS, dropped frames, A/V sync offset, engine init latency, first-frame latency, seek latency, CPU %, and resident memory (RSS MB).
- **Standalone Self-Contained App Bundle**: All required `x86_64` `libmpv` and `FFmpeg` runtime `.dylib` files are thinned, signed, and bundled inside `UPreviewX.app/Contents/Frameworks/` via `@rpath` (`@executable_path/../Frameworks`). Homebrew is **not** required at runtime.

---

## Architecture

```text
Sources/
├── CMPV/                               # C module & OpenGL/Mach shim for libmpv
│   ├── include/mpv_shim.h
│   ├── include/module.modulemap
│   └── shim.c
├── UPreviewXCore/
│   ├── Engine/                         # Isolated playback engine & rendering layer
│   │   ├── PlaybackDiagnostics.swift
│   │   ├── PlaybackEngineProtocol.swift
│   │   ├── MPVPlaybackEngine.swift
│   │   └── MPVVideoView.swift          # NSView + CAOpenGLLayer (mpv_render_context)
│   ├── Services/                       # Reserved conversion interface (decoupled)
│   │   └── ConversionServiceProtocol.swift
│   └── UI/                             # Native AppKit window & HUD controls
│       ├── PlayerWindowController.swift
│       ├── HUDControlsView.swift
│       ├── DiagnosticsOverlayView.swift
│       └── TimeFormatter.swift
└── UPreviewX/                          # Application lifecycle & CLI benchmark runner
    ├── AppDelegate.swift
    └── main.swift
```

---

## Hardware vs. Software Decoding on MacBook Pro 16-inch (2019)

A codec being supported by FFmpeg or having a `*_videotoolbox` hwaccel symbol in `libavcodec` does **not** mean the target Mac's hardware can decode it. On the **2019 16-inch MacBook Pro** (Intel Coffee Lake Core i7-9750H + Intel UHD Graphics 630 + Apple T2 + macOS 14 Sonoma), `libmpv` probes `videotoolbox` (`videotoolbox_vld`) first and automatically falls back to multi-threaded software decoding when `VTDecompressionSession` rejects the stream:

| Codec / Profile | Container | Active Decode Path on MBP 2019 | Pixel / HW Format | Explanation |
|-----------------|-----------|--------------------------------|-------------------|-------------|
| **H.264 8-bit** (`yuv420p`) | `.mp4` / `.mov` / `.mkv` | **Hardware (`videotoolbox`)** | `videotoolbox[nv12]` | Decoded by Intel QuickSync / VideoToolbox hardware decoder with zero-copy `IOSurface` binding. |
| **HEVC 8-bit** (`yuv420p`, Main) | `.mp4` / `.mov` / `.mkv` | **Hardware (`videotoolbox`)** | `videotoolbox[nv12]` | Decoded in hardware via Intel UHD 630 / T2 VideoToolbox pipeline. |
| **HEVC 10-bit 4:2:0** (`yuv420p10le`, Main 10) | `.mp4` / `.mov` / `.mkv` | **Hardware (`videotoolbox`)** | `videotoolbox[p010]` | Decoded in hardware via Intel UHD 630 / T2 VideoToolbox pipeline (`p010` surface). |
| **HEVC 10-bit 4:2:2** (`yuv422p10le`, RExt) | `.mov` (`hvc1`) / `.mkv` | **VideoToolbox (`p210`) / Software Fallback (`yuv422p10le`)** | `videotoolbox[p210]` or `yuv422p10` | Intel Coffee Lake lacks fixed-function 4:2:2 HEVC silicon; macOS 14 `VTDecoderXPCService` either bridges `hvc1` RExt to a `p210` `IOSurface` or, if rejected (e.g. raw annex-B / unsupported RExt stream), `libmpv` automatically falls back to 13-thread FFmpeg `hevc` software decoding. |
| **VP9 8-bit** (`yuv420p`, Profile 0) | `.webm` / `.mkv` | **Software (`ff-vp9` fallback)** | `yuv420p` | `vp9-videotoolbox` is probed first; when rejected by macOS VideoToolbox on this profile/machine, `libmpv` seamlessly falls back to 13-thread FFmpeg `vp9` software decoding. |
| **AV1 8-bit / 10-bit** (`yuv420p`) | `.mkv` / `.mp4` / `.webm` | **Software (`libdav1d`)** | `yuv420p` | No Intel Mac has hardware AV1 decode (introduced in Apple M3). Decoded via multi-threaded `libdav1d` SIMD assembly. |
| **Apple ProRes 422** (`yuv422p10le`) | `.mov` | **Software (`ff-prores` fallback)** | `yuv422p10` | Dedicated ProRes hardware decode engines only exist on Apple Silicon (M1 Pro/Max+) and Mac Pro Afterburner. `prores-videotoolbox` fails gracefully and falls back to 13-thread FFmpeg `prores` software decoding. |
| **Apple ProRes 4444** (`yuva444p12le`) | `.mov` | **Software (`ff-prores` fallback)** | `yuva444p12` | `prores-videotoolbox` fails gracefully and falls back to 13-thread FFmpeg `prores` software decoding. |
| **Avid DNxHD / DNxHR HQ** (`yuv422p`) | `.mov` | **Software (`ff-dnxhd`)** | `yuv422p` | No VideoToolbox hardware decoder exists for VC3/DNxHR; decoded directly by multi-threaded FFmpeg `dnxhd` software decoder. |

---

## Benchmark Results on Target Machine (MacBook Pro 16-inch, 2019)

Measured on `Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz`, `16 GB RAM`, rendering on integrated `Intel(R) UHD Graphics 630` (3072×1920 Retina display) using `UPreviewX.app --benchmark-suite`:

- **Cold-Start to Native Window Ready**: `111.95 ms`
- **Engine Initialization (`mpv_initialize`)**: `5.61 ms`

| Test Stream (1920×1080) | Codec | Decode Path | Active GPU | 1st Frame Latency | Exact Seek Latency | Dropped Frames (VO/Dec) | CPU Usage | RSS Memory |
|-------------------------|-------|-------------|------------|-------------------|--------------------|-------------------------|-----------|------------|
| `h264_8bit_1080p.mp4` (60 fps) | `h264` | **Hardware (`videotoolbox`)** | Intel UHD 630 | `14.74 ms` | `38.68 ms` | `0 / 0` | `40.5%` | `83.3 MB` |
| `hevc_8bit_1080p.mp4` (60 fps) | `hevc` | **Hardware (`videotoolbox`)** | Intel UHD 630 | `34.31 ms` | `22.18 ms` | `0 / 0` | `39.9%` | `93.7 MB` |
| `hevc_10bit_420_1080p.mp4` (60 fps) | `hevc` | **Hardware (`videotoolbox`)** | Intel UHD 630 | `0.67 ms` | `22.77 ms` | `0 / 0` | `43.4%` | `93.4 MB` |
| `hevc_10bit_422_1080p.mov` (30 fps) | `hevc` | **VideoToolbox (`p210`) / SW Fallback** | Intel UHD 630 | `16.04 ms` | `146.51 ms` | `0 / 0` | `25.1%` | `93.0 MB` |
| `vp9_1080p.webm` (30 fps) | `vp9` | **Software (`ff-vp9`)** | Intel UHD 630 | `48.51 ms` | `57.26 ms` | `0 / 0` | `49.6%` | `168.3 MB` |
| `av1_1080p.mkv` (30 fps) | `av1` | **Software (`libdav1d`)** | Intel UHD 630 | `221.00 ms` | `58.78 ms` | `0 / 0` | `47.1%` | `141.0 MB` |
| `prores_422_1080p.mov` (30 fps) | `prores` | **Software (`ff-prores`)** | Intel UHD 630 | `13.42 ms` | `32.58 ms` | `0 / 0` | `50.5%` | `223.1 MB` |
| `prores_4444_1080p.mov` (30 fps) | `prores` | **Software (`ff-prores`)** | Intel UHD 630 | `14.40 ms` | `84.92 ms` | `0 / 0` | `136.5%` | `385.0 MB` |
| `dnxhr_hq_1080p.mov` (30 fps) | `dnxhd` | **Software (`ff-dnxhd`)** | Intel UHD 630 | `18.81 ms` | `241.48 ms` | `1 / 0` | `43.5%` | `212.1 MB` |

*(Note: macOS reports process CPU usage across 12 logical threads = 1200% max; 20–58% represents ~2–5% of total 6-core/12-thread CPU capacity.)*

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Space` | Play / Pause (replays from `00:00` if at end of file) |
| `Left` / `Right` | Seek backward / forward 5 seconds |
| `Shift + Left` / `Shift + Right` | Seek backward / forward 1 second |
| `Up` / `Down` | Increase / decrease volume by 5% |
| `M` | Toggle audio mute |
| `F` or `Cmd + Ctrl + F` or Double-Click | Toggle native macOS Fullscreen |
| `D` or `Cmd + I` | Toggle Developer Decoder Diagnostics HUD |
| `Cmd + O` | Open video file |
| `Cmd + W` | Close window (terminates app if last window) |

---

## Reproducible Build & Test Instructions

### Prerequisites

- macOS 13.0+ (`x86_64` target)
- Xcode 15+ / Swift 5.10+ Command Line Tools

### Build Standalone App Bundle

```bash
# 1. Prepare thinned x86_64 libmpv/FFmpeg runtime libraries and build dist/UPreviewX.app
make app

# 2. Run unit and engine integration tests
make test
```

The standalone, self-contained application bundle is output to:

```text
dist/UPreviewX.app
```

### Run & Inspect Diagnostics

```bash
# Open a video file directly in UPreviewX.app with Decoder Diagnostics enabled:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --diagnostics /path/to/video.mp4

# Run automated benchmark on a single file or directory of test media:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark /path/to/video.mp4
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark-suite /path/to/test_media_dir
```

---

## License & Third-Party Notices

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for a complete audit of bundled dynamic libraries (`libmpv`, `FFmpeg`, `libdav1d`, `libplacebo`, `lcms2`, `zimg`, `libass`), their runtime linkage (`@rpath`), and GPLv2+/GPLv3 distribution requirements.
