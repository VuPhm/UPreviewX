# UPreviewX

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="UPreviewX App Icon" />
</p>

<p align="center">
  <b>Lightweight, native macOS video preview utility</b><br/>
  <i>Ứng dụng xem nhanh video native siêu nhẹ dành cho macOS</i>
</p>

<p align="center">
  <a href="#english">English</a> • <a href="#tiếng-việt">Tiếng Việt</a> • <a href="#download--installation">Download & Install</a> • <a href="#gatekeeper-guide">Gatekeeper Guide</a> • <a href="#shortcuts">Shortcuts</a>
</p>

---

<a name="english"></a>
## English Overview

**UPreviewX** is a lightweight, native macOS video preview utility (`Swift` + `AppKit`, `x86_64`) optimized for the **Intel MacBook Pro 16-inch (2019)** (Intel Core i7-9750H, 16 GB RAM, Intel UHD Graphics 630 + AMD Radeon Pro 5300M).

It delivers a fast, minimal, single-window preview experience similar to QuickTime / QuickLook while leveraging **libmpv + FFmpeg + VideoToolbox + dav1d** for comprehensive codec and container compatibility.

### Key Features & UX
- **Direct Video Window (No Home Screen)**: Double-clicking a supported video in Finder or using **Open With → UPreviewX** opens the video window immediately and begins playback.
- **Adaptive Aspect-Ratio Window Sizing**:
  - Automatically sizes and centers the player window to fit the **actual display aspect ratio** of the video (`9:16` and `4:5` portrait, `1:1` square, `16:9` and `21:9` landscape) without opening vertical videos inside a 16:9 box with side black bars.
  - Accounts for container display rotation metadata (`90°` / `270°`), sample aspect ratio (`SAR`), and display aspect ratio (`DAR`).
  - Constrains oversized windows (e.g. 4K) to `NSScreen.visibleFrame` (respecting menu bar and Dock) and locks window aspect ratio during resize.
- **Clean Process Lifecycle**: Closing the video window terminates the application completely (`applicationShouldTerminateAfterLastWindowClosed = true`). No background daemons or lingering processes.
- **Transport UX: Separation of Fast Seeking from Speed Playback**:
  - **Fast Seeking / Shuttle**: Rapid timeline navigation using efficient keyframe seeking. Press-and-hold navigation keys (default: `←` / `→`) triggers smooth shuttle seeking without decoder queue accumulation or decoder stalls. Releasing the key restores the exact prior state (paused remains paused, playing resumes playing).
  - **Speed Playback**: Continuous video playback at different speeds with pitch-corrected audio synchronization. Features a dedicated **1× / 2× speed toggle** in both the HUD and keyboard shortcuts (default: `2`).
- **Compact Playback HUD**: Streamlined floating controls optimized for portrait windows with an expandable volume slider and secondary action menu.
- **Customizable Keyboard Shortcuts**: Native AppKit Settings tab (`⌘,`) with interactive recorder and conflict detection against macOS system keys.
- **Dual-GPU Power Awareness (MBP 2019)**: Selects the integrated **Intel UHD Graphics 630** virtual screen via `cmpv_prefer_integrated_gpu` to avoid waking the power-hungry discrete GPU when viewing videos on battery.
- **Developer Decoder Diagnostics (`D` or `⌘I`)**: Real-time overlay reporting codec, decode path (`Hardware videotoolbox` vs. `Software FFmpeg/dav1d`), active GPU renderer, resolution, rotation, bitrate, nominal/effective FPS, dropped frames, A/V sync, latency, CPU %, and RSS memory.
- **100% Self-Contained Distribution Bundle**: 72 dynamic libraries (`libmpv.2.dylib`, `FFmpeg` decoders, `dav1d`, `libplacebo`, `libass`) are signed and bundled in `Contents/Frameworks/` via `@rpath`. End users do **not** need Homebrew, FFmpeg, or command-line tools.

---

<a name="tiếng-việt"></a>
## Tiếng Việt (Tổng quan)

**UPreviewX** là tiện ích xem trước video native nhẹ dành cho macOS (`Swift` + `AppKit`, `x86_64`), tối ưu hóa trên **MacBook Pro 16-inch 2019** (Intel Core i7-9750H, Intel UHD Graphics 630 + AMD Radeon Pro 5300M).

Ứng dụng mang đến trải nghiệm mở video nhanh tức thì như QuickTime / QuickLook, đồng thời tích hợp nền tảng giải mã mạnh mẽ **libmpv + FFmpeg + VideoToolbox + dav1d** hỗ trợ gần như mọi định dạng video hiện đại.

### Điểm nổi bật
- **Mở trực tiếp cửa sổ phát video**: Mở ngay lập tức khi nhấp đúp file trong Finder hoặc dùng menu **Open With → UPreviewX**, không có màn hình chờ hay cửa sổ đệm.
- **Tự động co giãn theo tỷ lệ video thực tế (Adaptive Aspect-Ratio)**:
  - Tự động căn chỉnh kích thước cửa sổ khớp tỷ lệ khung hình thực (`9:16`, `4:5` dọc, `1:1` vuông, `16:9`, `21:9` ngang), không bị viền đen hai bên khi xem video dọc.
  - Tự động nhận diện metadata xoay video (`90°` / `270°`) từ camera điện thoại.
  - Giới hạn kích thước video 4K trong phạm vi hiển thị an toàn (`NSScreen.visibleFrame`), không tràn qua Menu Bar hoặc Dock.
- **Vòng đời ứng dụng sạch (Clean Lifecycle)**: Đóng cửa sổ video sẽ thoát ứng dụng hoàn toàn. Không có daemon hay tiến trình chạy ngầm chiếm tài nguyên.
- **Tách bạch Shuttle Tua nhanh và Tốc độ phát (Speed Playback)**:
  - Tua nhanh (Shuttle): Nhấn giữ `←` hoặc `→` để tua nhanh mượt mà qua keyframe; nhả phím sẽ lập tức trả về trạng thái trước đó (đang tạm dừng tiếp tục tạm dừng, đang phát tiếp tục phát).
  - Tốc độ phát: Nút bấm và phím tắt chuyển đổi tức thì giữa `1×` và `2×` (mặc định phím `2`), giữ nguyên cao độ âm thanh (pitch correction).
- **HUD điều khiển gọn gàng**: Thiết kế phù hợp cho cả video dọc, thanh âm lượng tự thu gọn, menu mở rộng cho các tính năng phụ.
- **Tùy chỉnh phím tắt linh hoạt**: Tab Settings native (`⌘,`) cho phép ghi phím tắt mới, tự động phát hiện và ngăn trùng lặp với phím tắt hệ thống macOS.
- **Tiết kiệm pin với Dual-GPU (Intel MBP 2019)**: Tự động điều hướng OpenGL context về GPU tích hợp **Intel UHD Graphics 630**, hạn chế tối đa kích hoạt GPU rời AMD gây hao pin.
- **Lớp phủ chẩn đoán thời gian thực (`D` hoặc `⌘I`)**: Hiển thị chi tiết bộ giải mã (Hardware VideoToolbox hay Software dav1d/FFmpeg), GPU đang chạy, FPS thực tế, số khung hình rớt, độ trễ và % CPU / RAM.
- **Đóng gói hoàn chỉnh, độc lập**: Tích hợp sẵn 72 thư viện dylib trong `Contents/Frameworks/`. Người dùng cuối **không** cần cài Homebrew hay Terminal.

---

<a name="download--installation"></a>
## Download & Installation / Tải về & Cài đặt

### Distribution Formats (Phát hành)
Each release provides two distribution artifacts in the [Releases](https://github.com/VuPhm/UPreviewX/releases) page:
1. **DMG Installer** (`UPreviewX-v*-macos-x86_64.dmg`): Drag-and-drop installer into `/Applications`.
2. **Portable ZIP** (`UPreviewX-v*-macos-x86_64.zip`): Standalone archive ready to run anywhere.

### System Requirements (Yêu cầu hệ thống)
- **macOS**: 13.0 (Ventura) or later (Sonoma, Sequoia supported).
- **Hardware Architecture**:
  - **macOS Intel (x86_64)**: Native baseline (Intel Core i5/i7/i9 Macs).
  - **Apple Silicon (M1/M2/M3/M4)**: Runs seamlessly via Apple's built-in Rosetta 2 translation environment. Native arm64 builds will be provided in a future release once full native dependencies are audited.

### Installation Steps (Cài đặt)
1. Download `UPreviewX-v0.3.0-macos-x86_64.dmg` from the Releases section.
2. Double-click the DMG to open it.
3. Drag the `UPreviewX` icon into the `Applications` folder shortcut.
4. Eject the DMG.

---

<a name="gatekeeper-guide"></a>
## Gatekeeper First-Launch Guide / Hướng dẫn Gatekeeper

UPreviewX is open-source software distributed with valid ad-hoc code signing (`codesign --sign -`) without an Apple Developer ID subscription.

When opening UPreviewX for the first time, macOS Gatekeeper may show a warning:
> *"UPreviewX cannot be opened because Apple cannot check it for malicious software."*
> *(UPreviewX không thể mở vì Apple không thể kiểm tra phần mềm độc hại).*

### Official Apple Standard Procedure (Hướng dẫn chuẩn theo Apple):
1. Open **Finder** and go to **Applications**.
2. **Right-click** (or hold **Control** and click) `UPreviewX.app`.
3. Choose **Open** from the shortcut menu.
4. In the dialog that appears, click **Open**.

*Alternative method via System Settings:*
1. Open **System Settings** (Cài đặt hệ thống) → **Privacy & Security** (Quyền riêng tư & Bảo mật).
2. Scroll down to the **Security** (Bảo mật) section.
3. Under the message *"UPreviewX was blocked from use because it is not from an identified developer"*, click **Open Anyway** (Vẫn mở).

> [!NOTE]
> You only need to perform this confirmation once on first launch. macOS will remember your decision, and UPreviewX will open normally via double-click or **Open With** from then on.

---

## Uninstallation / Gỡ cài đặt

To completely remove UPreviewX from your Mac:
1. Quit UPreviewX if running (`⌘Q`).
2. Move `/Applications/UPreviewX.app` (or `~/Applications/UPreviewX.app`) to the Trash.
3. *(Optional)* Remove user preferences and saved shortcuts:
   ```bash
   defaults delete com.vuphm.upreviewx
   rm -f ~/Library/Preferences/com.vuphm.upreviewx.plist
   ```

---

<a name="shortcuts"></a>
## Keyboard Shortcuts / Bảng phím tắt

| Action / Thao tác | Default Shortcut | Description / Mô tả |
|-------------------|------------------|---------------------|
| **Play / Pause** | `Space` | Toggles playback; replays from beginning if ended |
| **Shuttle Tua tới** | `Hold →` | Fast-forward shuttle; restores previous state on key release |
| **Shuttle Tua lùi** | `Hold ←` | Rewind shuttle; restores previous state on key release |
| **Tua tới 5 giây** | `Tap →` | Relative jump forward 5s |
| **Tua lùi 5 giây** | `Tap ←` | Relative jump backward 5s |
| **Tua bước 1 giây** | `Shift + ← / →` | Exact 1-second step |
| **Toggle 1× / 2×** | `2` | Instant speed switch with pitch-corrected audio |
| **Save Current Frame** | `⌘ + ⇧ + S` | Captures uncompressed PNG to `~/Pictures/UPreviewX` |
| **Toggle Fullscreen** | `F` or `⌘ + ⌃ + F` | Native macOS fullscreen transition |
| **Decoder Diagnostics** | `D` or `⌘ + I` | Real-time decoder, FPS, GPU, and memory HUD overlay |
| **Fast Preview Mode** | `P` | Skips in-loop deblocking on heavy software-decoded 4K streams |
| **Volume Up / Down** | `↑` / `↓` | Adjusts volume by ±5% |
| **Mute** | `M` | Mutes or unmutes audio |
| **Settings** | `⌘ + ,` | Native preferences & interactive shortcut recorder |
| **Open Video File** | `⌘ + O` | System file picker filtered by video media types |
| **Close Window** | `⌘ + W` | Closes active window (terminates app if last window closed) |
| **Quit App** | `⌘ + Q` | Exits UPreviewX cleanly |

---

## Developer Guide & Building from Source

### Prerequisites
- macOS 13.0+
- Xcode 15+ / Swift 5.10+ Command Line Tools
- `lipo`, `install_name_tool`, `codesign`, `hdiutil` (included with macOS / Xcode)

### Make Targets
```bash
# 1. Compile binary for x86_64
make build

# 2. Run test suite
make test

# 3. Build standalone app bundle into dist/UPreviewX.app
make app

# 4. Package distribution DMG, ZIP, and SHA256SUMS
make package

# 5. Run full release verification gate
make release-check

# 6. Run automated playback & benchmark validation across diverse codecs
make validate

# 7. Install to ~/Applications for local development
make install

# 8. Uninstall from ~/Applications
make uninstall
```

---

## Verification & Checksums

You can verify the cryptographic integrity of any downloaded release package using standard macOS command line tools:

```bash
# Check SHA256 hashes
shasum -a 256 -c SHA256SUMS

# Verify code signature
codesign --verify --deep --strict /path/to/UPreviewX.app
```

---

## License & Third-Party Notices

UPreviewX is licensed under the **GNU General Public License v2.0 or later (GPLv2+)** due to bundling GPL-configured dynamic builds of `libmpv` and `FFmpeg`.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete list of bundled dynamic libraries, their respective open-source licenses, and upstream source code links.
