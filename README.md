# UPreviewX

**UPreviewX** is a lightweight, native macOS video preview utility (`Swift` + `AppKit`, `x86_64`) optimized for the **Intel MacBook Pro 16-inch (2019)** (Intel Core i7-9750H, 16 GB RAM, Intel UHD Graphics 630 + AMD Radeon Pro 5300M).

It delivers a fast, minimal, single-window preview experience similar to QuickTime / QuickLook while leveraging **libmpv + FFmpeg + VideoToolbox + dav1d** (the playback foundation of IINA) for broad codec and container compatibility.

---

## Key Features & UX

- **Direct Video Window (No Home Screen)**: Double-clicking a supported video in Finder or using **Open With → UPreviewX** opens the video window immediately and begins playback.
- **Adaptive Aspect-Ratio Window Sizing**:
  - Automatically sizes and centers the player window to fit the **actual display aspect ratio** of the video (`9:16` and `4:5` portrait, `1:1` square, `16:9` and `21:9` landscape) without opening vertical videos inside a 16:9 box with side black bars.
  - Accounts for container display rotation metadata (`90°` / `270°`), sample aspect ratio (`SAR`), and display aspect ratio (`DAR`), not just coded width/height.
  - Constrains oversized windows (e.g., 4K `3840×2160` or `2160×3840`) to `NSScreen.visibleFrame` (respecting the macOS menu bar and Dock) and locks `NSWindow.aspectRatio` so manual resizing preserves video proportions.
  - Reveals the window only once video display geometry is resolved (or after a short 180 ms fallback) so portrait/square videos never flash inside a default 16:9 frame.
- **Quit-on-Last-Window-Close Lifecycle**: Closing the video window terminates the application completely (`applicationShouldTerminateAfterLastWindowClosed = true`). It never remains resident in the background.
- **Unobtrusive Auto-Hiding HUD**: Compact, flexible floating controls (Play/Pause, interactive timeline scrubber, elapsed/duration time, Mute, Volume, Diagnostics toggle, Fullscreen toggle) automatically adapt to narrow portrait windows (`minSize = 210×210`) and fade out after 2 seconds of cursor inactivity.
- **Dual-GPU Power Awareness (MBP 2019)**: Configures `NSSupportsAutomaticGraphicsSwitching` in `Info.plist`, `kCGLPFASupportsAutomaticGraphicsSwitching` + `kCGLPFAAllowOfflineRenderers`, and explicitly selects the integrated **Intel UHD Graphics 630** virtual screen via `CGLSetVirtualScreen` (`cmpv_prefer_integrated_gpu`) even when another process has powered on the discrete **AMD Radeon Pro 5300M**.
- **Two-Tier Responsive Timeline Scrubbing**: Uses coalesced keyframe seeking (`absolute+keyframes`) while dragging the timeline slider for fast scrubbing across long GOPs, followed by an exact frame-accurate seek (`absolute+exact`) on mouse release.
- **Optional Fast Preview Mode (`P` Key / `--fast-preview`)**: Strictly opt-in preview mode (`vd-lavc-skiploopfilter=all` + `vd-lavc-fast=yes`) that accelerates decoding and Long-GOP seeking on heavy software-decoded 4K streams without ever silently lowering fidelity by default.
- **Developer Decoder Diagnostics (`D` or `Cmd+I`)**: Built-in real-time overlay reporting file size, container, codec, pixel format, active decode path (`Hardware (videotoolbox)` vs. `Software (FFmpeg/dav1d fallback)` vs. `Software (Fast Preview Mode)`), active GPU renderer, coded vs. display resolution, rotation, bitrate, nominal/effective FPS, dropped frames, A/V sync offset, engine init latency, first-frame latency, seek latency, CPU %, and current/peak RSS memory.
- **Standalone Self-Contained App Bundle**: All required `x86_64` `libmpv` and `FFmpeg` runtime `.dylib` files are thinned, signed, and bundled inside `UPreviewX.app/Contents/Frameworks/` via `@rpath` (`@executable_path/../Frameworks`). Homebrew is **not** required at runtime.

---

## Architecture

```text
Sources/
├── CMPV/                               # C module, CGL virtual-screen selector & Mach usage shim
│   ├── include/mpv_shim.h
│   ├── include/module.modulemap
│   └── shim.c
├── UPreviewXCore/
│   ├── Engine/                         # Isolated playback engine & rendering layer
│   │   ├── PlaybackDiagnostics.swift
│   │   ├── PlaybackEngineProtocol.swift
│   │   ├── MPVPlaybackEngine.swift     # 100% async property/command pipeline over libmpv
│   │   └── MPVVideoView.swift          # NSView + CAOpenGLLayer (mpv_render_context)
│   ├── Services/                       # Reserved conversion interface (decoupled)
│   │   └── ConversionServiceProtocol.swift
│   └── UI/                             # Native AppKit adaptive window & HUD controls
│       ├── PlayerWindowController.swift
│       ├── HUDControlsView.swift
│       ├── DiagnosticsOverlayView.swift
│       └── TimeFormatter.swift
└── UPreviewX/                          # Application lifecycle & CLI benchmark runner
    ├── AppDelegate.swift
    └── main.swift
```

---

## 1. Adaptive Window Sizing Validation (Suite A)

Validated on the target **MacBook Pro 16-inch (2019)** (`1792×1120` logical points, `NSScreen.visibleFrame` constraining max initial window height to `908 pt` and width to `1612 pt`):

| Test Video | Coded Resolution | Rotation / SAR | Effective Display Resolution | Video Aspect | Window Size (`pt`) | Window Aspect | Side / Top Black Bars |
|------------|------------------|----------------|------------------------------|--------------|--------------------|---------------|-----------------------|
| `portrait_9_16.mp4` | `1080×1920` | `0°` / `1:1` | `1080×1920` | `0.563` (`9:16`) | **`511×908`** | **`0.563`** | None (0 px) |
| `ADS - T9 - KB1 - VERTIKTOK.mp4` | `1080×1920` | `0°` / `1:1` | `1080×1920` | `0.563` (`9:16`) | **`511×908`** | **`0.563`** | None (0 px) |
| `C2378.MP4` (4K Rotated Camera Clip) | `3840×2160` | **`270°`** / `1:1` | **`2160×3840`** | `0.563` (`9:16`) | **`511×908`** | **`0.563`** | None (0 px) |
| `C3585.MP4` (4K Rotated Sony XAVC) | `3840×2160` | **`270°`** / `1:1` | **`2160×3840`** | `0.563` (`9:16`) | **`511×908`** | **`0.563`** | None (0 px) |
| `portrait_4_5.mp4` | `1080×1350` | `0°` / `1:1` | `1080×1350` | `0.800` (`4:5`) | **`726×908`** | **`0.800`** | None (0 px) |
| `square_1_1.mp4` | `1080×1080` | `0°` / `1:1` | `1080×1080` | `1.000` (`1:1`) | **`908×908`** | **`1.000`** | None (0 px) |
| `landscape_16_9.mp4` | `1920×1080` | `0°` / `1:1` | `1920×1080` | `1.778` (`16:9`) | **`1612×907`** | **`1.777`** | None (0 px) |
| `anamorphic_sar_16_9.mp4` | `1440×1080` | `0°` / **`SAR 4:3`** | **`1920×1080`** | `1.778` (`16:9`) | **`1612×907`** | **`1.777`** | None (0 px) |
| `ultrawide_21_9.mp4` | `2520×1080` | `0°` / `1:1` | `2520×1080` | `2.333` (`21:9`) | **`1612×691`** | **`2.333`** | None (0 px) |

---

## 2. Heavy Video Performance Optimization & Benchmarks (Suite B)

### Three Distinct Performance Concerns Addressed

1. **Large File Size & Local I/O**:
   - Disabled unnecessary stream caching (`cache=no`) and bounded demuxer readahead (`demuxer-readahead-secs=1.0`, `demuxer-max-bytes=64MiB`, `demuxer-max-back-bytes=32MiB`).
   - Result: Opening and seeking across a **9.9 GB (`9898.8 MB`) 4K60 10-bit HEVC file** (`large_10gb_4k60_hevc10.mp4`, 102.7 Mbps) consumes only **`120.9 MB` peak RSS memory** (identical to an 800 MB clip), with `149.95 ms` first-frame latency and `44.38 ms` keyframe seek latency.
2. **Computationally Expensive Decoding**:
   - Eliminated a 2-thread rendezvous stall between `vo_libmpv` and synchronous `mpv_get_property`/`mpv_command` calls by converting `MPVPlaybackEngine` to a **100% asynchronous event-driven pipeline** (`mpv_observe_property` across 27 properties + `mpv_command_async` + `mpv_set_property_async`).
   - Tuned `vd-lavc-threads=8` (`vd-lavc-dr=no`) for the 6-core / 12-thread Intel Core i7-9750H, allowing real **1.60 GB 4K 29.97fps Sony XAVC H.264 High 4:2:2 10-bit (`149 Mbps`)** camera footage (`C3585.MP4`) to software-decode at full **`29.97 / 29.97 fps` with `0` dropped frames** (`306.3%` CPU).
3. **Rendering & Long-GOP Seeking Overhead**:
   - Configured lightweight GPU texture scaling (`scale=bilinear`, `dscale=bilinear`, `cscale=bilinear`, `correct-downscaling=no`, ` hdr-compute-peak=no`) on the integrated **Intel UHD Graphics 630**.
   - Implemented coalesced keyframe scrubbing (`exact: false` → `absolute+keyframes`) during slider drag and accurate seeking (`exact: true` → `absolute+exact`) on slider release, reducing seek latency across 250-frame 4K60 GOPs from `909.24 ms` (exact) to **`92.22 ms` (keyframe scrub)** (**9.8× faster**).

### Heavy 4K, High-Bitrate, Long-Duration, VFR & 10 GB Benchmark Table

Measured on the target **2019 MacBook Pro 16-inch** (`Intel Core i7-9750H @ 2.60 GHz`, `16 GB RAM`, active GPU: `Intel(R) UHD Graphics 630`):

- **Cold-Start to Native Window Ready**: `96.7–126.2 ms`
- **Cold-Launch to First Visible 4K Frame**: `342.2–516.4 ms`
- **Engine Initialization (`mpv_initialize`)**: `2.79–5.18 ms`

| Workload / File | Size & Bitrate | Format & Resolution | Decode Path | 1st Frame | Keyframe Scrub / Exact Seek | Effective / Source FPS | Drops (VO/Dec) | CPU % | Peak / RSS Memory |
|-----------------|----------------|---------------------|-------------|-----------|-----------------------------|------------------------|----------------|-------|-------------------|
| **`DJI_..._0030_D.MP4`** (Real Camera 4K60 10-bit) | `803.0 MB` (`90.8 Mbps`) | HEVC Main10 (`yuv420p10le`) `3840×2160` | **Hardware (`videotoolbox`)** | `84.09 ms` | `33.39 ms` / `50.91 ms` | **`59.94 / 59.94`** | `5 / 0` | `47.4%` | `125.9 / 120.7 MB` |
| **`C1117.MP4`** (Real Camera 4K60 10-bit, 165s) | `1152.7 MB` (`44.2 Mbps`) | HEVC Main10 (`yuv420p10le`) `3840×2160` | **Hardware (`videotoolbox`)** | `85.02 ms` | `32.98 ms` / `116.50 ms` | **`59.94 / 59.94`** | `0 / 0` | `41.6%` | `131.8 / 131.7 MB` |
| **`large_10gb_4k60_hevc10.mp4`** (Large ~10 GB File) | **`9898.8 MB`** (`102.7 Mbps`) | HEVC Main10 (`yuv420p10le`) `3840×2160` | **Hardware (`videotoolbox`)** | `149.95 ms` | `44.38 ms` / `87.79 ms` | **`59.92 / 59.92`** | `10 / 0` | `40.6%` | **`120.9 / 120.9 MB`** |
| **`C2378.MP4`** (Real Camera 4K25 Rotated 270°) | `396.0 MB` (`101.4 Mbps`) | H.264 8-bit `3840×2160` → `2160×3840` | **Hardware (`videotoolbox`)** | `83.74 ms` | `146.96 ms` / `166.16 ms` | **`25.00 / 25.00`** | `0 / 0` | `15.7%` | `120.6 / 120.6 MB` |
| **`copy_694EE865...mov`** (Real 4K 120fps VFR Portrait) | `613.3 MB` (`45.1 Mbps`) | HEVC Main `2160×3840` (120fps VFR) | **Hardware (`videotoolbox`)** | `129.38 ms` | `39.49 ms` / `71.91 ms` | **`120.0 / 120.0`** *(60Hz VSync)* | `90 / 0` *(VSync)* | `51.1%` | `94.7 / 94.6 MB` |
| **`4k_hevc_10bit_422_30fps.mov`** (4K30 HEVC 4:2:2 `hvc1`) | `8.7 MB` (`14.0 Mbps`) | HEVC RExt (`yuv422p10le`) `3840×2160` | **VideoToolbox (`p210`)** | `86.94 ms` | `172.15 ms` / `344.58 ms` | **`30.00 / 30.00`** | `32 / 0` | `28.6%` | `104.3 / 94.0 MB` |
| **`real_4k60_hevc_422_10bit_sw.mkv`** (4K60 HEVC 4:2:2) | `14.6 MB` (`12.3 Mbps`) | HEVC RExt (`yuv422p10le`) `3840×2160` | **VideoToolbox (`p210`)** | `471.39 ms` | `452.97 ms` / `452.97 ms` | **`59.94 / 59.94`** | `2 / 0` | `25.9%` | `92.7 / 92.4 MB` |
| **`C3585.MP4`** (Real Sony XAVC 4K30 10-bit 4:2:2 Rotated) | **`1600.2 MB`** (`140.9 Mbps`) | H.264 High 4:2:2 (`yuv422p10`) `2160×3840` | **Software (`ff-h264`)** | `153.51 ms` | `511.94 ms` / `338.44 ms` | **`29.97 / 29.97`** | **`0 / 0`** | `306.3%` | `633.0 / 623.4 MB` |
| **`C3585.MP4` (`--fast-preview`)** | `1600.2 MB` (`140.9 Mbps`) | H.264 High 4:2:2 (`yuv422p10`) `2160×3840` | **Software (`Fast Preview`)** | **`93.14 ms`** | **`346.80 ms` / `244.27 ms`** | **`29.97 / 29.97`** | **`0 / 0`** | `340.1%` | `664.2 / 659.2 MB` |
| **`real_4k60_h264_422_10bit.mp4`** (4K60 CAVLC 175 Mbps, GOP=250) | `167.0 MB` (`174.9 Mbps`) | H.264 High 4:2:2 (`yuv422p10`) `3840×2160` | **Software (`ff-h264`)** | `92.03 ms` | **`92.22 ms`** / `909.24 ms` | **`59.94 / 59.94`** | **`0 / 0`** | `231.9%` | `619.9 / 619.9 MB` |
| **`real_4k60_h264_422_10bit.mp4` (`--fast-preview`)** | `167.0 MB` (`174.9 Mbps`) | H.264 High 4:2:2 (`yuv422p10`) `3840×2160` | **Software (`Fast Preview`)** | **`49.70 ms`** | **`110.19 ms` / `110.19 ms`** | **`59.94 / 59.94`** | `7 / 0` | `289.2%` | `605.1 / 605.1 MB` |
| **`Know My Name...webm`** (Real 4K24 AV1 Music Video, 257s) | `258.9 MB` (`6.1 Mbps`) | AV1 (`yuv420p`) `3840×2160` | **Software (`libdav1d`)** | `167.84 ms` | `89.14 ms` / `317.82 ms` | **`24.00 / 24.00`** | **`0 / 0`** | `203.2%` | `335.7 / 335.7 MB` |
| **`4k_av1_60fps.mkv`** (4K60 AV1 47 Mbps) | `27.3 MB` (`46.9 Mbps`) | AV1 (`yuv420p`) `3840×2160` | **Software (`libdav1d`)** | `112.23 ms` | `105.83 ms` / `92.76 ms` | **`60.00 / 60.00`** | **`0 / 0`** | `187.2%` | `324.2 / 324.2 MB` |
| **`4k_av1_60fps.mkv` (`--fast-preview`)** | `27.3 MB` (`46.9 Mbps`) | AV1 (`yuv420p`) `3840×2160` | **Software (`Fast Preview`)** | **`54.28 ms`** | `137.57 ms` / `112.91 ms` | **`60.00 / 60.00`** | **`0 / 0`** | **`176.6%`** | `324.4 / 323.6 MB` |
| **`Vợ tôi là số 1...webm`** (30-Min Long Duration AV1, 1794s) | `290.2 MB` (`0.9 Mbps`) | AV1 (`yuv420p`) `1920×1080` | **Software (`libdav1d`)** | `69.98 ms` | `22.98 ms` / `148.51 ms` | **`25.00 / 25.00`** | **`0 / 0`** | `67.9%` | `140.2 / 140.2 MB` |
| **`4k_prores_422hq_30fps.mov`** (4K30 ProRes 422 HQ) | `161.1 MB` (`261.2 Mbps`) | ProRes 422 HQ (`yuv422p10`) `3840×2160` | **Software (`ff-prores`)** | `34.77 ms` | `70.32 ms` / `75.50 ms` | **`30.00 / 30.00`** | **`0 / 0`** | `110.3%` | `503.9 / 497.4 MB` |
| **`4k_prores_4444_30fps.mov`** (4K30 ProRes 4444) | `278.9 MB` (`458.5 Mbps`) | ProRes 4444 (`yuva444p12`) `3840×2160` | **Software (`ff-prores`)** | `75.16 ms` | `251.92 ms` / `389.85 ms` | **`30.00 / 30.00`** | **`0 / 0`** | `409.1%` | `928.2 / 893.8 MB` |
| **`4k_dnxhr_hq_30fps.mov`** (4K30 Avid DNxHR HQ) | `520.9 MB` (`873.9 Mbps`) | DNxHR HQ (`yuv422p`) `3840×2160` | **Software (`ff-dnxhd`)** | `73.97 ms` | `65.75 ms` / `57.78 ms` | **`30.00 / 30.00`** | **`0 / 0`** | `101.2%` | `432.9 / 432.9 MB` |

### Software-Only 4K Hardware Ceiling on Intel Core i7-9750H (2019 MBP)

All **4K 24/25/30fps** software-decoded formats (Sony XAVC 4K30 H.264 10-bit 4:2:2 at 149 Mbps, 4K30 ProRes 422 HQ at 261 Mbps, 4K30 ProRes 4444 at 458 Mbps, 4K30 DNxHR HQ at 874 Mbps, and 4K24/60 AV1 via `libdav1d`) sustain **100% real-time playback with zero dropped frames** on this machine.

The following extreme **software-only 4K 60fps** combinations exceed the 6-core Coffee Lake CPU ceiling (`i7-9750H @ 2.60 GHz`, lacking hardware decode silicon for H.264 10-bit 4:2:2 or ProRes):

| Codec / Resolution / Framerate | Bitrate & Format | Measured Behavior on i7-9750H | Mitigation (`Fast Preview Mode` — `P` Key / `--fast-preview`) |
|--------------------------------|------------------|-------------------------------|---------------------------------------------------------------|
| **4K 59.94fps CABAC H.264 High 4:2:2 10-bit** (`real_4k60_h264_422_10bit_cabac.mp4`) | `160 Mbps` (`yuv422p10le`, `cabac=1`) | Sequential per-frame CABAC entropy decoding saturates threads at `648.2%` CPU (`656.8 MB` RSS), dropping `63` frames over 2.2s (~31–34 fps effective vs. 59.94 fps source). | Enabling **Fast Preview Mode** (`vd-lavc-skiploopfilter=all`, `vd-lavc-fast=yes`) skips H.264 in-loop deblocking, reducing first-frame latency (`132.6 ms` → `115.0 ms`) and improving effective frame rate and Long-GOP seek response without silently altering default fidelity. |
| **4K 60fps Apple ProRes 4444 12-bit + Alpha** (`4k60_prores_4444.mov`) | `927.5 Mbps` (`yuva444p12le`) | Uncompressed 12-bit 4:4:4:4 slice decoding + GPU texture upload reaches `808.9%` CPU (`921.8 MB` RSS), dropping `20` frames over 2.2s (~51 fps effective vs. 60 fps source). | Full-fidelity **4K 30fps ProRes 4444** (`458.5 Mbps`) and **4K 30/60fps ProRes 422 HQ** play in real time with `0` dropped frames. |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Space` | Play / Pause (replays from `00:00` if at end of file) |
| `Left` / `Right` | Seek backward / forward 5 seconds (keyframe seek) |
| `Shift + Left` / `Shift + Right` | Seek backward / forward 1 second (exact seek) |
| `Up` / `Down` | Increase / decrease volume by 5% |
| `M` | Toggle audio mute |
| `P` | Toggle **Fast Preview Mode** (for heavy software-decoded 4K streams) |
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

# Open with optional Fast Preview Mode enabled for heavy software-only 4K60 streams:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --fast-preview --diagnostics /path/to/video.mp4

# Run automated benchmark on a single file or directory of test media:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark /path/to/video.mp4
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark-suite /path/to/test_media_dir
```

---

## License & Third-Party Notices

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for a complete audit of bundled dynamic libraries (`libmpv`, `FFmpeg`, `libdav1d`, `libplacebo`, `lcms2`, `zimg`, `libass`), their runtime linkage (`@rpath`), and GPLv2+/GPLv3 distribution requirements.
