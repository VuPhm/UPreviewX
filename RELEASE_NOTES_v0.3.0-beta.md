# UPreviewX v0.3.0-beta — Thông tin Phát hành (Release Notes)

**UPreviewX** là tiện ích xem trước video native nhẹ, hiệu năng cao dành cho macOS (`Swift` + `AppKit`, `x86_64`), mang lại trải nghiệm xem nhanh như QuickTime / QuickLook đồng thời tích hợp nền tảng giải mã mạnh mẽ của `libmpv` + `FFmpeg` + `VideoToolbox` + `dav1d`.

> [!IMPORTANT]
> **Lưu ý Kiến trúc & Bản dựng:**
> Bản phát hành `v0.3.0-beta` được xây dựng và kiểm định chuyên biệt cho **macOS Intel (`x86_64`)** (Hệ điều hành macOS 13.0+; baseline: MacBook Pro 16-inch 2019).
> Trên máy Mac Apple Silicon (M1/M2/M3/M4), ứng dụng chạy mượt mà thông qua môi trường Rosetta 2. Bản build native `arm64` sẽ được cung cấp riêng khi toàn bộ dependency tree được kiểm chứng trực tiếp trên phần cứng Apple Silicon.

---

## Các điểm mới trong phiên bản v0.3.0-beta

### 1. Chuẩn hóa Quy trình Đóng gói & Phân phối Độc lập
- **Bộ cài đặt DMG Kéo-thả**: Kéo trực tiếp `UPreviewX.app` vào `/Applications` để sử dụng.
- **Bản Portable ZIP**: Lưu trữ độc lập, bảo toàn 100% quyền thực thi và symlink của dynamic libraries.
- **Dependency Closure tự chứa 100%**: Tích hợp sẵn 72 dynamic libraries (`libmpv.2.dylib`, bộ giải mã `FFmpeg` 7.x, `dav1d`, `libplacebo`, `libass`, v.v.) trong `Contents/Frameworks/` thông qua `@rpath`.
- **Zero Dependencies**: Người dùng cuối tuyệt đối không cần cài đặt Homebrew, FFmpeg hay thao tác dòng lệnh.

### 2. Trải nghiệm Xem trước Video Native Hiện đại
- **Mở cửa sổ phát tức thì**: Không có màn hình chờ hay cửa sổ đệm, nhấp đúp video là phát ngay.
- **Co giãn kích thước thích ứng (Adaptive Aspect Ratio)**: Căn chỉnh chính xác theo tỷ lệ hiển thị thực (`9:16`, `4:5` dọc, `1:1` vuông, `16:9`, `21:9` ngang) và metadata xoay (`90°`/`270°`), loại bỏ hiện tượng viền đen hai bên trên video dọc.
- **Vòng đời ứng dụng sạch (Clean Lifecycle)**: Thoát ứng dụng ngay khi đóng cửa sổ phát video. Không có daemon hay tiến trình chạy ngầm làm chậm hệ thống.
- **Tiết kiệm pin trên Dual-GPU (MacBook Pro 2019)**: Chủ động điều hướng context dựng hình OpenGL về GPU tích hợp Intel UHD 630 nhằm tối ưu hóa thời lượng pin khi sử dụng trên nguồn pin.

### 3. Tách biệt Tua nhanh (Shuttle) & Tốc độ phát (Speed Playback)
- **Shuttle Keyframe Tua nhanh**: Nhấn giữ phím `←` hoặc `→` để tua nhanh mượt mà; nhả phím lập tức trả về đúng trạng thái ban đầu.
- **Tốc độ phát 1× / 2×**: Nút bấm HUD và phím tắt `2` chuyển đổi tức thì giữa 1× và 2× kèm pitch correction giữ nguyên cao độ âm thanh.
- **HUD nổi gọn gàng**: Thiết kế phù hợp cho video dọc, thanh âm lượng tự động mở rộng/thu gọn thông minh.
- **Tùy chỉnh phím tắt**: Cửa sổ Cài đặt native (`⌘,`) cho phép ghi phím tắt mới và tự phát hiện trùng lặp với phím tắt hệ thống macOS.
- **Lớp phủ chẩn đoán thời gian thực (`D` hoặc `⌘I`)**: Báo cáo chi tiết codec, luồng giải mã (Hardware VideoToolbox hay Software dav1d/FFmpeg), FPS thực tế, số khung hình rớt, độ trễ và bộ nhớ RAM.

---

## Hướng dẫn Mở ứng dụng lần đầu (Gatekeeper Trust UX)

UPreviewX là phần mềm mã nguồn mở độc lập, được ký số ad-hoc hợp lệ (`codesign --sign -`) nhưng chưa đăng ký chứng chỉ thương mại Apple Developer ID ($99/năm).

Khi mở ứng dụng lần đầu trên macOS 13 Ventura, 14 Sonoma hoặc 15 Sequoia, Gatekeeper có thể hiển thị cảnh báo:
> *"UPreviewX không thể mở vì Apple không thể kiểm tra phần mềm độc hại."*

**Quy trình mở chuẩn theo hướng dẫn của Apple:**
1. Mở **Finder** và truy cập thư mục **Applications** (Ứng dụng).
2. **Nhấp chuột phải** (hoặc giữ phím **Control** và bấm chuột) vào `UPreviewX.app`.
3. Chọn **Open** (Mở) từ menu ngữ cảnh.
4. Trong hộp thoại xuất hiện, nhấn nút **Open** (Mở).
*(Cách khác: Mở **Cài đặt hệ thống** → **Quyền riêng tư & Bảo mật** → cuộn xuống phần **Bảo mật** → bấm **Vẫn mở**).*

Thao tác này chỉ cần thực hiện một lần duy nhất.

---

## Mã băm Kiểm tra Toàn vẹn (SHA256SUMS)

Kiểm tra tính toàn vẹn của tệp tải về bằng lệnh trong Terminal:
```bash
shasum -a 256 -c SHA256SUMS
```

| Tệp cài đặt | Mã băm SHA256 |
|---|---|
| `UPreviewX-v0.3.0-macos-x86_64.dmg` | `4e077c04caa001cdfe8bb6cf1d938767c7eced6d8bb61ba618cb350e8956ff00` |
| `UPreviewX-v0.3.0-macos-x86_64.zip` | `3f9e15f7d6530951806ebf0dbea063e1bf94f1b9fe1c6b10d3e89302c77d0ffb` |

---

## Giấy phép & Bản quyền
UPreviewX được phát hành theo giấy phép **GNU General Public License v2.0 or later (GPLv2+)** ([LICENSE](LICENSE)). Chi tiết xem tại [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
