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
- **Thử nghiệm Thực tế trên Mẫu Video Máy quay Sony XAVC-S (`C3585.MP4`)**:
  - *Đặc tính file thực tế*: Dung lượng `1.6 GB`, thời lượng `90.09s`, luồng video `140 Mbps` AVC/H.264 High 4:2:2 Profile (`yuv422p10le`), 10-bit màu, kích thước coded `3840×2160`, ma trận xoay `90.00°` (kích thước hiển thị `2160×3840` 9:16 dọc), âm thanh Linear PCM stereo 48kHz (`pcm_s16be`), container edit list thiếu keyframe ở thời điểm đầu.
  - *Nguyên nhân macOS Finder không hiển thị thumbnail*: Bộ giải mã phần cứng Apple VideoToolbox trên phần cứng Intel chỉ hỗ trợ giải mã phần cứng H.264 8-bit `4:2:0`. Khi gặp luồng H.264 10-bit `4:2:2` từ máy quay Sony, pipeline AVFoundation / QuickLook mặc định của hệ thống trả về lỗi không giải mã được và Finder bỏ qua việc tạo thumbnail.
  - *Đo lường giải mã thumbnail phần mềm*: Khi ép buộc giải mã bằng `libmpv` / FFmpeg thuần phần mềm (Software decoding), quá trình tìm kiếm keyframe và giải mã khung hình 4K 10-bit tiêu tốn **15.7 giây** thời gian CPU thực tế, tiêu hao `190% – 250%` CPU và tạo ra ảnh PNG unscaled `32.7 MB`.
  - *Cơ chế bảo vệ của UPreviewX*: `VideoThumbnailService` áp dụng giới hạn thời gian (timeout budget) `2.5s`. Khi giải mã vượt quá ngưỡng an toàn, hệ thống tự động hủy tiến trình con, dọn dẹp bộ nhớ đệm và trả về lỗi `.extractionTimeout` để bảo toàn hiệu năng máy, không gây đơ hoặc giật hệ thống.

---

## 7. Triệt tiêu Hiện tượng Giật Hình học Cửa sổ (Window Geometry Stabilization)

### Nguyên nhân hiện tượng giật ngang → dọc:
Khi mở video quay dọc có độ phân giải 4K 10-bit như `C3585.MP4`:
- Cửa sổ AppKit ban đầu mở ở kích thước mặc định `640×480` và có timer dự phòng 180 ms.
- Engine `libmpv` mất khoảng ~850–890 ms để demux và đọc metadata xoay (`video-params/rotate = 270`).
- Ở 33 ms đầu tiên, `libmpv` phát sự kiện kích thước pixel thô `video-params/w = 3840, h = 2160` trong khi thuộc tính góc xoay vẫn là `0°`. Nếu áp dụng ngay, cửa sổ sẽ nhảy sang tỷ lệ `16:9` ngang.
- Khi hết timer 180 ms, cửa sổ hiện lên dưới dạng chữ nhật ngang, sau đó đến 892 ms khi metadata xoay được phân tích xong, cửa sổ mới đột ngột co lại thành chữ nhật dọc `9:16`, tạo ra trải nghiệm giật hình rất khó chịu.

### Giải pháp kỹ thuật triển khai:
1. **Metadata Preflight siêu tốc bằng AVFoundation (`AVURLAsset`)**:
   - Trước khi hiển thị cửa sổ (`alphaValue == 0.0`), hệ thống gọi hàm bất đồng bộ `preflightVideoDisplaySize` với timeout bảo vệ 50 ms.
   - Hàm này chỉ trích xuất thông tin track kích thước tự nhiên (`naturalSize`) và ma trận biến đổi affine (`preferredTransform`) của container MP4/MOV mà **không giải mã bất kỳ khung hình video nào**.
   - Thời gian trích xuất thực tế trên file `C3585.MP4`: chỉ mất **19.1 ms** (so với 892 ms của mpv demuxer).
   - Cửa sổ được định hình kích thước và tỷ lệ khung hình chuẩn `2160×3840` (9:16) ngay lập tức khi còn đang ẩn.
2. **Khử cập nhật sai lệch từ Decoder (Orientation Consistency Check)**:
   - Trong quá trình phát, nếu decoder phát ra sự kiện kích thước có tỷ lệ trái ngược với kết quả preflight (ví dụ: decoder báo ngang trong khi preflight xác nhận là video dọc), cập nhật này sẽ bị từ chối cho đến khi decoder cập nhật đầy đủ góc xoay.
3. **Hiển thị đồng bộ theo khung hình đầu (First Rendered Frame Gating)**:
   - Cửa sổ chỉ được bật sáng (`alphaValue = 1.0`) khi tầng OpenGL thực sự dựng xong khung hình đầu tiên (`playbackEngineDidRenderFirstFrame`), kết hợp timer an toàn 1.2s cho các tệp chỉ có âm thanh (audio-only) hoặc tệp hỏng.
4. **Kết quả đo lường**:
   - Số lần thay đổi kích thước cửa sổ sau khi hiển thị (Resizes after reveal): **0 lần**.
   - Trải nghiệm mở video dọc mượt mà, ổn định tuyệt đối từ khoảnh khắc đầu tiên xuất hiện trên màn hình.

---

## 8. Tích hợp Finder & Kiểm soát Bản ghi LaunchServices (Clean LaunchServices)

### Thực trạng xung đột:
Khi phát triển và đóng gói UPreviewX, các bản build trung gian trong thư mục `dist/UPreviewX.app` hoặc các mount point tạm thời của DMG/ZIP thường tự động được daemon LaunchServices của macOS ghi nhận. Điều này dẫn đến hiện tượng menu chuột phải **Open With** (Mở bằng) hiển thị nhiều mục "UPreviewX" trùng lặp.

### Cơ chế tự động làm sạch:
1. Tích hợp lệnh hủy đăng ký `lsregister -u` vào tất cả các quy trình tự động:
   - `Scripts/build_app.sh`: Hủy đăng ký `${DIST_DIR}/UPreviewX.app` ngay sau khi ký số hoàn tất.
   - `Scripts/package_distribution.sh`: Giữ sạch staging folder và không để sót bản ghi bundle tạm.
   - `Scripts/release_check.sh`: Thêm hook dọn dẹp `cleanup()` tự động gỡ bỏ các bản ghi bundle trong thư mục mount DMG và thư mục giải nén ZIP tạm thời.
2. **Trạng thái hệ thống**:
   - Bản cài đặt chính thức tại `/Applications/UPreviewX.app` (hoặc `~/Applications/UPreviewX.app`) là bản duy nhất được đăng ký cho các định dạng media (`public.mpeg-4`, `public.movie`, v.v.).
   - Loại bỏ hoàn toàn tình trạng nhân bản mục trong menu **Open With** của Finder.

---

## 9. Đánh giá Thực nghiệm Quick Look Extension trong Điều kiện Ad-hoc Signing

Nhằm đánh giá tính khả thi của việc tích hợp Quick Look Preview / Thumbnail Extension (`.appex`) cho Finder trên các bản phân phối mã nguồn mở:

### Thử nghiệm thực tế với `pluginkit` và `quicklookd`:
1. Tạo một App Extension thử nghiệm đóng gói bên trong `UPreviewX.app/Contents/PlugIns/` với protocol `com.apple.quicklook.preview`.
2. Ký số ad-hoc toàn bộ bundle (`codesign --sign -`).
3. Đăng ký extension vào hệ thống bằng `pluginkit -a`.
4. Quan sát nhật ký hệ thống qua `log stream --predicate 'subsystem == "com.apple.runningboard" OR process == "quicklookd"'`:

```text
RunningBoard: Launch denied for com.vuphm.upreviewx.quicklook (pid -1):
[RBSRequestErrorDomain Code=5: Launch failed: Launch denied by policy]
POSIX error: 111 (Connection refused / Not permitted)
```

### Kết luận kỹ thuật:
- Kể từ macOS 13 Ventura trở đi, tiến trình điều phối `quicklookd` và daemon kiểm soát tiến trình `RunningBoard` (`pkd`) áp đặt chính sách bảo mật bắt buộc: **Mọi Quick Look App Extension phải có chữ ký số hợp lệ từ Apple Developer Program (có Team ID)**.
- Các App Extension có chữ ký ad-hoc (`-`) bị RunningBoard từ chối khởi chạy ngay từ bước phân giải quyền hạn.
- Do đó, việc nhồi nhét Quick Look Extension vào bản build ad-hoc không thể kích hoạt được tính năng xem trước phím Space hay thumbnail Finder, mà chỉ làm tăng dung lượng gói cài đặt và gây cảnh báo Gatekeeper. UPreviewX duy trì kiến trúc native app độc lập, cung cấp khả năng mở tức thì qua nhấp đúp và CLI `--thumbnail` nhẹ nhàng, an toàn.

---

## 10. Thử nghiệm Tải Áp lực Thumbnail theo Quy mô Thư mục (Folder-Scale Stress Benchmarks)

Khi duyệt một thư mục chứa 20, 50 hoặc 100+ video hỗn hợp có nhiều định dạng nặng như `C3585.MP4` (Sony XAVC-S 4K 10-bit H.264 4:2:2):

### A. So sánh Hiệu năng & Mức Tiêu thụ Tài nguyên Trước và Sau:

| Chỉ số đo lường | Trước khi tối ưu (PR #2) | Sau khi triển khai Smart Thumbnail (Vòng này) | Mức độ cải thiện |
|---|---|---|---|
| **Bộ giải mã hoạt động đồng thời** | Không kiểm soát (nhiều decoder con chạy song song) | **Tối đa đúng 1 decoder (`activeDecoders <= 1`)** | Triệt tiêu xung đột CPU/GPU |
| **Dung lượng Hàng đợi (Queue Capacity)** | Không giới hạn (tích lũy 50-100 task) | **Hữu hạn (Tối đa 16 task, kích hoạt Backpressure)** | Ngăn chặn tràn bộ nhớ RAM |
| **Xử lý tệp nặng `C3585.MP4`** | Decode phần mềm tốn **15.7s CPU** (`250%` CPU) | Phân loại `HIGH` trong **14 ms**, fast-fail an toàn | **Nhanh hơn 1,000 lần**, tiết kiệm 100% CPU |
| **Phản hồi lần 2 với tệp nặng** | Lặp lại thử nghiệm đắt đỏ 15.7s | **Negative Cache Hit dưới 0.1 ms** | **0% CPU**, không retry vô ích |
| **Bộ nhớ RAM sử dụng (RSS)** | Tăng lũy tiến (sinh nhiều ảnh 4K uncompressed 32MB) | **Giới hạn nghiêm ngặt dưới 16 MiB** (ảnh thu nhỏ) | Tiết kiệm > 85% RAM |
| **Tác động lên Playback đang phát** | Khung hình bị rớt (dropped frames do tranh chấp CPU) | **Tự động tạm hoãn thumbnail (`0` dropped frames)** | Bảo đảm tuyệt đối 60fps |
| **Hủy tác vụ khi rời thư mục** | Quá trình decode tiếp tục chạy ngầm | **Hủy tức thì trong < 1 ms** (`metricCancelled >= 10`) | Thu hồi tài nguyên tức thì |

### B. Đánh giá: Có nên hỗ trợ Thumbnail cho `C3585.MP4` bằng Video Decode hay không?
- **Đo lường kỹ thuật**: Giải mã keyframe phần mềm cho luồng 4K H.264 10-bit 4:2:2 140 Mbps đòi hỏi từ **12.8 đến 15.7 giây** thời gian CPU thực tế trên Intel Core i7-9750H, bão hòa 2 luồng CPU ở mức 200–250% và tạo nhiệt lượng lớn trên MBP 2019.
- **Quyết định thiết kế**: **KHÔNG NÊN** giải mã video bằng CPU chỉ để lấy một thumbnail trong phiên duyệt thư mục. Smart Cost Classification gắn nhãn `HIGH` cho tệp này, thử ảnh bìa metadata trước; nếu không có, hệ thống lập tức fast-fail an toàn và lưu vào Negative Cache, trả về icon mặc định của hệ thống. Điều này giữ cho máy Mac luôn mát mẻ, pin không bị sụt và giao diện người dùng luôn phản hồi tức thì.

---

## 11. Khắc phục Triệt để Cú Giật Nhẹ Cửa sổ (Zero-Jerk Final Stability Audit)

Mặc dù lỗi nhảy tỷ lệ ngang (16:9) sang dọc (9:16) đã được khắc phục ở PR #3, việc kiểm thử chi tiết trên mẫu `C3585.MP4` cho thấy vẫn còn một cú giật nhẹ xuất phát từ 3 nguyên nhân:

1. **Thứ tự gọi WindowServer**: Trước đây, `showWindow(nil)` và `makeKeyAndOrderFront(nil)` được gọi trước khi metadata preflight hoàn tất, khiến WindowServer ghi nhận cửa sổ ở kích thước khởi tạo `640×480` trước khi `setFrame` co lại thành dọc.
   - *Khắc phục*: Preflight và định hình kích thước cửa sổ chuẩn trong bộ nhớ **trước khi** gọi `orderFront` lên WindowServer.
2. **Thời điểm mở sáng cửa sổ (First-Frame Render Gating)**: Trước đây, cửa sổ mở sáng ngay khi mpv phát sự kiện `MPV_EVENT_PLAYBACK_RESTART` (~33 ms), trong khi frame đầu tiên chưa thực sự được vẽ lên OpenGL layer (~850 ms), tạo ra cảm giác giật từ khung đen sang khung hình video.
   - *Khắc phục*: Tách biệt hoàn toàn `useNullVideoOutput` (headless thumbnail) và GUI interactive playback. Cửa sổ chỉ mở sáng (`alphaValue = 1.0`) khi tầng OpenGL thực sự hoàn tất render và swap khung hình đầu tiên trong `reportRenderSwap()`.
3. **Triệt tiêu vi sai kích thước & Aspect Tolerance**: Trước đây, các cập nhật sau reveal với sai số nhỏ do làm tròn điểm ảnh (< 1 pt) hoặc vi sai tỷ lệ (< 1.5%) vẫn kích hoạt `win.setFrame(display: true)`.
   - *Khắc phục*: Bỏ qua toàn bộ các cập nhật có delta kích thước < 1.0 pt và vi sai tỷ lệ < 1.5% sau khi cửa sổ đã hiển thị.

**Kết quả kiểm chứng**: Số lần thay đổi kích thước sau khi cửa sổ hiển thị (Resizes after reveal) là **0 lần** trên toàn bộ 34 bài kiểm thử của test suite.
