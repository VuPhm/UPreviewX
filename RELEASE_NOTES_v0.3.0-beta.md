# UPreviewX v0.3.0-beta Release Notes

UPreviewX is a lightweight, native macOS video preview utility (`Swift` + `AppKit`, `x86_64`) delivering a fast, single-window video preview experience similar to QuickTime while leveraging the robust playback foundation of `libmpv` + `FFmpeg` + `VideoToolbox` + `dav1d`.

> [!IMPORTANT]
> **Architecture & Distribution Notice**:
> This `v0.3.0-beta` release is built and verified specifically for **macOS x86_64** (Baseline: Intel MacBook Pro 2019 running macOS 13+).
> On Apple Silicon Macs (M1/M2/M3/M4), this package runs via Apple's Rosetta 2 translation environment. Native `arm64` builds will be provided in a future release once full native dependencies are audited. This release is intentionally **not** labeled Universal to prevent misleading architecture claims.

---

## What's New in v0.3.0-beta

### 1. Standardized Distribution Packaging
- **Drag-and-Drop DMG**: Easy installation by dragging `UPreviewX.app` directly into `/Applications`.
- **Portable ZIP**: Self-contained archive preserving all execution permissions and Mach-O dylib symlinks.
- **100% Self-Contained Dependency Closure**: Bundles 72 dynamic libraries (`libmpv.2.dylib`, `FFmpeg` 7.x decoders, `dav1d`, `libplacebo`, `libass`, etc.) under `Contents/Frameworks/` via `@rpath`.
- **Zero Runtime Dependencies**: End users do **not** need Homebrew, FFmpeg, or command-line tools installed.

### 2. Native macOS Video Preview Experience
- **Instant Single-Window Playback**: Opens directly to playback when double-clicked or opened via Finder.
- **Adaptive Window Sizing**: Automatically adapts window dimensions to match portrait (`9:16`, `4:5`), square (`1:1`), or ultrawide (`21:9`) aspect ratios, accounting for container rotation metadata (`90°`/`270°`) without letterboxing vertical videos in a 16:9 box.
- **Clean Lifecycle**: Terminates completely when the last window is closed (`applicationShouldTerminateAfterLastWindowClosed = true`). No background daemons or lingering processes.
- **Dual-GPU Awareness (MBP 2019)**: Directs OpenGL context to the integrated Intel UHD Graphics 630 to conserve battery power.

### 3. Transport UX & Keyboard Customization
- **Separation of Shuttling from Speed Playback**: Press-and-hold shuttle seeking (`←`/`→`) with immediate state restoration upon release; dedicated `1× / 2×` speed toggle button and shortcut (`2`).
- **Compact HUD**: Streamlined controls designed for narrow portrait windows with an auto-collapsing expandable volume slider.
- **Customizable Shortcuts**: Native Settings tab (`⌘,`) with shortcut recorder and collision detection against system keys.
- **Real-Time Diagnostics**: In-app overlay (`D` or `⌘I`) showing codec, decode path, nominal/effective FPS, dropped frames, bitrate, CPU %, and memory RSS.

---

## Gatekeeper First-Launch Guide (Apple Unidentified Developer)

UPreviewX is open-source software distributed with valid ad-hoc code signing (`codesign --sign -`) without an Apple Developer ID certificate.

When opening for the first time on macOS 13+ (Ventura, Sonoma, Sequoia), macOS Gatekeeper may display:
> *"UPreviewX cannot be opened because Apple cannot check it for malicious software."*

**Recommended Apple Standard Procedure:**
1. Open **Finder** and navigate to **Applications** (or the folder where you installed UPreviewX).
2. **Right-click** (or **Control-click**) `UPreviewX.app` and choose **Open**.
3. In the security dialog that appears, click **Open**.
*(Alternatively: Open **System Settings** → **Privacy & Security** → scroll to **Security** → click **Open Anyway** next to UPreviewX).*

Once approved on first launch, macOS remembers your authorization and subsequent launches occur seamlessly via normal double-click or **Open With**.

---

## Verification & SHA256 Checksums

Verify the authenticity of downloaded artifacts using the SHA256 checksums in Terminal:

```bash
shasum -a 256 -c SHA256SUMS
```

| File | SHA256 Checksum |
|------|-----------------|
| `UPreviewX-v0.3.0-macos-x86_64.dmg` | `4e077c04caa001cdfe8bb6cf1d938767c7eced6d8bb61ba618cb350e8956ff00` |
| `UPreviewX-v0.3.0-macos-x86_64.zip` | `3f9e15f7d6530951806ebf0dbea063e1bf94f1b9fe1c6b10d3e89302c77d0ffb` |

---

## Licensing & Third-Party Notice
UPreviewX is licensed under the **GNU General Public License v2.0 or later (GPLv2+)** due to bundling GPL-configured dynamic builds of `libmpv` and `FFmpeg`. Complete source code for UPreviewX is available at [VuPhm/UPreviewX](https://github.com/VuPhm/UPreviewX), and upstream library source pointers are provided in `THIRD_PARTY_NOTICES.md`.
