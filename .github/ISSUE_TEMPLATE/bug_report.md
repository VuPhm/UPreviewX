---
name: Báo cáo lỗi (Bug Report)
about: Tạo báo cáo lỗi để giúp hoàn thiện UPreviewX
title: '[BUG] '
labels: bug
assignees: ''
---

**Mô tả lỗi**
Mô tả ngắn gọn và rõ ràng về vấn đề gặp phải.

**Thông tin tệp video thử nghiệm**
- Định dạng / Đuôi tệp (ví dụ: `.mp4`, `.mov`, `.mkv`, `.webm`):
- Codec video & audio (ví dụ: H.264, HEVC, AV1, ProRes 422, AAC):
- Độ phân giải & Tỷ lệ (ví dụ: 1080×1920 dọc, 4K 16:9, xoay 90°):
- Dung lượng ước tính:

**Môi trường hệ thống**
- Phiên bản macOS: macOS 13 / 14 / 15
- Phần cứng Mac: MacBook Pro 2019 (Intel Core i7/i9) / Intel Mac khác / Apple Silicon (qua Rosetta 2)
- Phiên bản UPreviewX: v0.3.0-beta

**Các bước tái hiện**
1. Mở video bằng cách...
2. Thực hiện thao tác (tua, chỉnh âm lượng, chuyển 2x, phóng to)...
3. Quan sát thấy lỗi xuất hiện.

**Hành vi kỳ vọng**
Ứng dụng nên hoạt động như thế nào trong trường hợp này.

**Ảnh chụp màn hình / Nhật ký (Logs)**
Nếu có thể, bật lớp phủ chẩn đoán (`D` hoặc `⌘I`) và đính kèm ảnh chụp màn hình, hoặc chạy lệnh từ Terminal:
```bash
/Applications/UPreviewX.app/Contents/MacOS/UPreviewX --diagnostics /path/to/video.mp4
```
