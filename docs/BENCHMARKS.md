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

## 3. Thử nghiệm Phát lại Đa Codec (Release Validation Suite)

Kết quả đo đạc từ tiện ích benchmark tự động (`--benchmark-suite`):

| Test Vector | Định dạng & Codec | Bộ giải mã | GPU Renderer | First Frame | Seek (Exact) | FPS Thực tế | CPU Usage | RAM (RSS) |
|---|---|---|---|---|---|---|---|---|
| `01_h264_landscape_1080p.mp4` | H.264 1080p 30fps | VideoToolbox (HW) | Intel UHD 630 | 624 ms (Cold) | 212 ms | 30.0 fps | 15.7% | 72.8 MB |
| `02_h264_portrait_9_16.mp4` | H.264 9:16 30fps | VideoToolbox (HW) | Intel UHD 630 | 60 ms | 194 ms | 30.0 fps | 14.6% | 73.7 MB |
| `03_h264_rotated_90deg.mp4` | H.264 Rotate 90° 30fps | VideoToolbox (HW) | Intel UHD 630 | 43 ms | 210 ms | 30.0 fps | 7.4% | 73.4 MB |
| `04_hevc_landscape_1080p.mp4` | HEVC / H.265 1080p 30fps | VideoToolbox (HW) | Intel UHD 630 | 18 ms | 143 ms | 30.0 fps | 17.1% | 90.3 MB |
| `05_av1_landscape_720p.mp4` | AV1 720p 30fps | dav1d (Software) | Intel UHD 630 | 57 ms | 21 ms | 30.0 fps | 7.0% | 124.6 MB |
| `06_prores_1080p.mov` | ProRes 422 1080p 24fps | FFmpeg (Software) | Intel UHD 630 | 20 ms | 10 ms | 24.0 fps | 28.0% | 201.2 MB |
| `99_corrupt_payload.mp4` | Payload lỗi / không hợp lệ | Fallback | Intel UHD 630 | 0 ms | 0 ms | 0.0 fps | 0.4% | 119.2 MB |

> [!NOTE]
> Tất cả các phép thử đều duy trì `0 dropped frames` ở trạng thái steady-state (ngoại trừ vài khung hình đầu khi khởi tạo pipeline giải mã phần cứng).

---

## 4. Thử nghiệm Áp lực 4K Khối lượng Lớn & Chế độ Fast Preview

Trên phần cứng Intel Coffee Lake 2019, các luồng video 4K 60fps không có bộ giải mã phần cứng tích hợp (như H.264 10-bit 4:2:2 hoặc ProRes 4444 12-bit) đòi hỏi năng lực tính toán cực lớn:

| Codec & Thông số | Định dạng Pixel & Bitrate | Đo lường trên i7-9750H (Mặc định) | Hiệu quả khi bật Chế độ Fast Preview (`P`) |
|---|---|---|---|
| **4K 60fps H.264 High 4:2:2 10-bit** | `yuv422p10le`, `160 Mbps` | Giải mã tuần tự CABAC bão hòa các luồng CPU ở `648.2%` CPU (`656.8 MB` RSS), rớt khung hình (~31–34 fps thực tế). | Bật **Fast Preview** (`vd-lavc-skiploopfilter=all`, `vd-lavc-fast=yes`) bỏ qua bộ lọc in-loop deblocking, giảm độ trễ khung hình đầu (`132.6 ms` → `115.0 ms`) và tăng tốc độ seek Long-GOP mượt mà. |
| **4K 60fps ProRes 4444 12-bit + Alpha** | `yuva444p12le`, `927.5 Mbps` | Giải mã lát cắt 12-bit 4:4:4:4 không nén và đẩy texture lên GPU đạt `808.9%` CPU (`921.8 MB` RSS), rớt khoảng 20 khung hình. | Với các file phổ biến như **4K 30fps ProRes 4444** (`458.5 Mbps`) và **4K 30/60fps ProRes 422 HQ**, ứng dụng phát mượt thời gian thực với `0` khung hình rớt. |
