# UPreviewX — Báo cáo Đo lường Hiệu năng & Thử nghiệm (Benchmarks)

Tài liệu này ghi lại chi tiết các kết quả đo lường hiệu năng, mức tiêu thụ tài nguyên và thử nghiệm áp lực (stress tests) của **UPreviewX** trên cấu hình baseline phần cứng tiêu chuẩn.

---

## 1. Môi trường Thử nghiệm Chuẩn (Baseline Environment)

- **Thiết bị**: Apple MacBook Pro 16-inch (2019)
- **Bộ vi xử lý (CPU)**: 2.60 GHz 6-Core Intel Core i7 (i7-9750H, 12 Threads)
- **Bộ nhớ (RAM)**: 16 GB 2667 MHz DDR4
- **Đồ họa kép (Dual-GPU)**:
  - **iGPU**: Intel UHD Graphics 630 (1536 MB VRAM)
  - **dGPU**: AMD Radeon Pro 5300M (4 GB GDDR6 VRAM)
- **Hệ điều hành**: macOS 14.6 Sonoma (Darwin Kernel 23.6.0 x86_64)
- **Màn hình hiển thị**: 16-inch Retina (độ phân giải logic `1792×1120 pt`, `visibleFrame` trừ Menu Bar và Dock: `1612×908 pt`)

---

## 2. Đo lường Co giãn Cửa sổ Thích ứng (Adaptive Window Sizing)

UPreviewX tự động tính toán kích thước cửa sổ dựa trên tỷ lệ hiển thị thực tế (SAR/DAR và rotation metadata `90°`/`270°`) thay vì coded pixel, loại bỏ hoàn toàn viền đen hai bên khi xem video dọc:

| Test Video | Kích thước mã hóa | Rotation / SAR | Độ phân giải hiển thị | Tỷ lệ video | Kích thước cửa sổ (`pt`) | Tỷ lệ cửa sổ | Viền đen |
|------------|-------------------|----------------|-----------------------|-------------|--------------------------|--------------|----------|
| **Vertical 9:16 Shorts/Reels** | `1080×1920` | `0°` / `1:1` | `1080×1920` | `9:16` (`0.5625`) | `511 × 908` | `0.5628` | **0 pt** |
| **Portrait 4:5 Instagram** | `1080×1350` | `0°` / `1:1` | `1080×1350` | `4:5` (`0.8000`) | `726 × 908` | `0.7996` | **0 pt** |
| **Square 1:1 Social Post** | `1080×1080` | `0°` / `1:1` | `1080×1080` | `1:1` (`1.0000`) | `908 × 908` | `1.0000` | **0 pt** |
| **Standard 16:9 Landscape** | `1920×1080` | `0°` / `1:1` | `1920×1080` | `16:9` (`1.7778`) | `1612 × 907` | `1.7773` | **0 pt** |
| **Ultrawide 21:9 Cinema** | `2560×1080` | `0°` / `1:1` | `2560×1080` | `21:9` (`2.3704`) | `1612 × 680` | `2.3706` | **0 pt** |
| **Smartphone 4K Rotated 90°** | `3840×2160` | `90°` | `2160×3840` | `9:16` (`0.5625`) | `511 × 908` | `0.5628` | **0 pt** |
| **Smartphone 4K Rotated 270°** | `3840×2160` | `270°` | `2160×3840` | `9:16` (`0.5625`) | `511 × 908` | `0.5628` | **0 pt** |
| **Anamorphic HD (1440×1080)** | `1440×1080` | `SAR 4:3` | `1920×1080` | `16:9` (`1.7778`) | `1612 × 907` | `1.7773` | **0 pt** |

---

## 3. Thử nghiệm Phát lại Đa Codec & Quản lý Tài nguyên (Release Validation Suite)

Kết quả đo đạc từ tiện ích benchmark tự động (`--benchmark-suite`) trên 10 test vectors chuẩn hóa:

| Test Vector | Định dạng & Codec | Bộ giải mã | GPU Renderer | First Frame | Seek (Exact) | FPS Thực tế | CPU Playback | CPU Khi Pause | Tạo Thumbnail | RAM (RSS) |
|---|---|---|---|---|---|---|---|---|---|---|
| `01_h264_landscape_1080p.mp4` | H.264 1080p 30fps | VideoToolbox (HW) | Intel UHD 630 | 81.5 ms (Cold) | 187.5 ms | 30.0 fps | 16.8% | **0.5%** | 76.4 ms | 75.9 MB |
| `02_h264_portrait_9_16.mp4` | H.264 9:16 30fps | VideoToolbox (HW) | Intel UHD 630 | 43.2 ms | 186.2 ms | 30.0 fps | 11.9% | **0.6%** | 30.5 ms | 78.3 MB |
| `03_h264_rotated_90deg.mp4` | H.264 Rotate 90° 30fps | VideoToolbox (HW) | Intel UHD 630 | 39.4 ms | 239.3 ms | 30.0 fps | 12.0% | **0.3%** | 40.1 ms | 76.7 MB |
| `04_hevc_landscape_1080p.mp4` | HEVC / H.265 1080p 30fps | VideoToolbox (HW) | Intel UHD 630 | 47.2 ms | 239.2 ms | 30.0 fps | 15.1% | **0.4%** | 48.9 ms | 93.7 MB |
| `05_av1_landscape_720p.mp4` | AV1 720p 30fps | dav1d (Software) | Intel UHD 630 | 67.0 ms | 20.3 ms | 30.0 fps | 8.8% | **0.5%** | 496.4 ms | 124.6 MB |
| `06_prores_1080p.mov` | ProRes 422 1080p 24fps | FFmpeg (Software) | Intel UHD 630 | 15.6 ms | 9.9 ms | 24.0 fps | 9.1% | **0.3%** | 53.3 ms | 182.8 MB |
| `07_mkv_landscape_1080p.mkv` | Matroska H.264 1080p | VideoToolbox (HW) | Intel UHD 630 | 59.5 ms | 210.9 ms | 30.0 fps | 10.6% | **0.5%** | 612.5 ms | 88.3 MB |
| `08_webm_landscape_720p.webm` | WebM VP9 720p | FFmpeg (Software) | Intel UHD 630 | 8.5 ms | 14.9 ms | 30.0 fps | 5.9% | **0.5%** | 467.4 ms | 111.1 MB |
| `09_4k_landscape_3840x2160.mp4` | 4K UHD H.264 30fps | VideoToolbox (HW) | Intel UHD 630 | 13.7 ms | 437.5 ms | 30.0 fps | 9.7% | **0.3%** | 77.2 ms | 102.9 MB |
| `99_corrupt_payload.mp4` | Payload lỗi / không hợp lệ | Fallback | Intel UHD 630 | 0.0 ms | 0.0 ms | 0.0 fps | 0.7% | **0.5%** | 30.2 ms | 107.2 MB |

> [!NOTE]
> Tất cả các phép thử đều duy trì `0 dropped frames` ở trạng thái steady-state (ngoại trừ vài khung hình đầu khi khởi tạo pipeline giải mã phần cứng).
> Khi tạm dừng (Paused), mức tiêu thụ CPU giảm về gần **0%** (`0.1% – 0.6%`), và khi đóng cửa sổ xem, tiến trình ứng dụng thoát sạch hoàn toàn (`0 lingering processes`).

---

## 4. Thử nghiệm Áp lực 4K Khối lượng Lớn & Chế độ Fast Preview

Trên phần cứng Intel Coffee Lake 2019, các luồng video 4K 60fps không có bộ giải mã phần cứng tích hợp (như H.264 10-bit 4:2:2 hoặc ProRes 4444 12-bit) đòi hỏi năng lực tính toán cực lớn:

| Codec & Thông số | Định dạng Pixel & Bitrate | Đo lường trên i7-9750H (Mặc định) | Hiệu quả khi bật Chế độ Fast Preview (`P`) |
|---|---|---|---|
| **4K 60fps H.264 High 4:2:2 10-bit** | `yuv422p10le`, `160 Mbps` | Giải mã tuần tự CABAC bão hòa các luồng CPU ở `648.2%` CPU (`656.8 MB` RSS), rớt khung hình (~31–34 fps thực tế). | Bật **Fast Preview** (`vd-lavc-skiploopfilter=all`, `vd-lavc-fast=yes`) bỏ qua bộ lọc in-loop deblocking, giảm độ trễ khung hình đầu (`132.6 ms` → `115.0 ms`) và tăng tốc độ seek Long-GOP mượt mà. |
| **4K 60fps ProRes 4444 12-bit + Alpha** | `yuva444p12le`, `927.5 Mbps` | Giải mã lát cắt 12-bit 4:4:4:4 không nén và đẩy texture lên GPU đạt `808.9%` CPU (`921.8 MB` RSS), rớt khoảng 20 khung hình. | Với các file phổ biến như **4K 30fps ProRes 4444** (`458.5 Mbps`) và **4K 30/60fps ProRes 422 HQ**, ứng dụng phát mượt thời gian thực với `0` khung hình rớt. |

---

## 5. Kiểm thử Vòng đời & Quản lý Tài nguyên Thông minh (Lifecycle Audit)

UPreviewX áp dụng kiến trúc quản lý tài nguyên thích ứng (Adaptive Resource Management) xuyên suốt toàn bộ vòng đời ứng dụng:

1. **Khởi chạy ứng dụng (App Launch)**: Không tạo bất kỳ background daemon, agent hay service chạy ngầm nào. Chỉ khởi tạo OpenGL context và mpv engine khi có tệp video được yêu cầu mở.
2. **Mở và chuyển đổi tệp (File Opening / Switching)**: Tái sử dụng cửa sổ và OpenGL context hiện có mà không phá hủy/cấp phát lại liên tục. Hủy phiên shuttle/seek đang chạy, giải phóng buffer cũ trước khi nhận stream mới.
3. **Phát video (Playback)**: Throttling giao diện HUD: khi thanh điều khiển đang ẩn (`isControlsHidden`), hệ thống bỏ qua việc cập nhật chuỗi thời gian và thanh trượt, giảm thiểu layout passes của AppKit.
4. **Tạm dừng (Pause)**: Hủy bỏ `diagnosticsTimer` liên tục, không render thêm khung hình OpenGL, đưa mức sử dụng CPU về mức nhàn rỗi danh nghĩa (~0.1% – 0.6%).
5. **Cửa sổ bị che khuất hoặc thu nhỏ (Window Occluded / Minimized)**:
   - Lắng nghe `NSWindow.didChangeOcclusionStateNotification`, `windowDidMiniaturize`, `windowDidDeminiaturize`.
   - Khi cửa sổ bị che khuất hoàn toàn hoặc thu nhỏ vào Dock, cờ `isOccluded = true` được bật: dừng render OpenGL FBO và tạm ngưng diagnostics polling để tiết kiệm điện năng GPU/CPU.
   - Khi cửa sổ hiển thị trở lại, khung hình hiện tại được vẽ lại ngay lập tức (`setNeedsDisplay()`).
6. **Áp lực bộ nhớ hệ thống (Memory Pressure)**:
   - Tích hợp `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])`.
   - Khi nhận cảnh báo áp lực bộ nhớ: tự động giải phóng demuxer back-cache (`demuxer-max-back-bytes = 0`) và thu hẹp demuxer forward buffer để bảo toàn tài nguyên RAM hệ thống.
7. **Đóng cửa sổ & Thoát ứng dụng (Termination)**:
   - Khi đóng cửa sổ cuối cùng, toàn bộ timers, OpenGL render context và mpv handles được thu hồi sạch sẽ.
   - `NSApp.terminate(nil)` giải phóng tiến trình hoàn toàn, đảm bảo `0` tiến trình tồn dư trong nền (`Clean Termination`).

---

## 6. Hỗ trợ Thumbnail: Đánh giá & Giới hạn Kỹ thuật (Thumbnail Strategy)

### Định dạng Thumbnail đã khắc phục:
- **Tập tin chuẩn macOS (MP4, MOV, M4V, ProRes)**: Tận dụng trực tiếp AVFoundation với cấu hình seek nhanh `requestedTimeTolerance = .positiveInfinity`, tạo thumbnail trong ~30–80 ms mà không cần giải mã tuần tự GOP.
- **Embedded Cover Art (Artwork đính kèm)**: Trích xuất trực tiếp từ metadata (`commonKeyArtwork`) trong < 5 ms với mức tiêu thụ CPU gần bằng 0.
- **Định dạng container mở (MKV, WebM, AVI, TS, AV1)**: Khắc phục thông qua headless `VideoThumbnailService` (sử dụng null VO, giới hạn bộ nhớ 4MB, 2 luồng giải mã, timeout 2.5s) và tiện ích dòng lệnh `--thumbnail`.

### Định dạng và Giới hạn cố ý không hỗ trợ:
- **Quick Look Thumbnail Extension cho MKV/WebM trong bản phân phối ad-hoc**:
  - *Nguyên nhân kỹ thuật*: macOS 13+ (Sonoma/Sequoia) yêu cầu các App Extension hệ thống (`com.apple.quicklook.thumbnail`) phải được ký số bởi chứng chỉ **Apple Developer Team ID** có trả phí để giao tiếp an toàn qua daemon hệ thống (`quicklookd` / `pluginkit`). Trên các bản build ad-hoc mã nguồn mở, `pluginkit` từ chối kích hoạt thumbnail extension của bên thứ ba.
  - *Quyết định thiết kế*: UPreviewX cố ý không nhồi nhét `.appex` không khả dụng vào bản phân phối để tránh làm phình kích thước app bundle, tránh rủi ro Gatekeeper cách ly và giữ trọn vẹn quy trình kiểm tra bảo mật `make release-check`. Thay vào đó, việc trích xuất thumbnail được cung cấp thông qua `VideoThumbnailService` nội bộ và CLI `--thumbnail`.
