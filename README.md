# UPreviewX — Ứng dụng xem nhanh video native siêu nhẹ cho macOS

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="UPreviewX Icon" />
</p>

[![Release](https://img.shields.io/badge/release-v0.3.0--beta-blue.svg)](https://github.com/VuPhm/UPreviewX/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2013.0%2B-brightgreen.svg)]()
[![Architecture](https://img.shields.io/badge/arch-Intel%20x86__64-orange.svg)]()
[![License](https://img.shields.io/badge/license-GPLv2%2B-lightgrey.svg)](LICENSE)

**UPreviewX** là tiện ích xem trước video native nhẹ, hiệu năng cao dành cho macOS (`Swift` + `AppKit`, `x86_64`), tối ưu hóa đặc biệt cho dòng **Intel MacBook Pro 16-inch (2019)**.

Ứng dụng mang lại trải nghiệm xem nhanh tức thì như QuickTime / QuickLook nhưng sở hữu sức mạnh giải mã toàn diện từ **libmpv + FFmpeg + VideoToolbox + dav1d**, tự động thích ứng với mọi tỷ lệ khung hình video mà không có bất kỳ tiến trình chạy ngầm nào.

---

## 1. Tải về & Cài đặt nhanh

Các tệp cài đặt chính thức được phát hành tại trang [GitHub Releases](https://github.com/VuPhm/UPreviewX/releases):

| Tệp phân phối | Định dạng | Mô tả |
|---|---|---|
| **[`UPreviewX-v0.3.0-macos-x86_64.dmg`](https://github.com/VuPhm/UPreviewX/releases/download/v0.3.0-beta/UPreviewX-v0.3.0-macos-x86_64.dmg)** | **Apple Disk Image** | **Khuyên dùng:** Kéo-thả vào Applications, sẵn sàng sử dụng. |
| **`UPreviewX-v0.3.0-macos-x86_64.zip`** | Portable ZIP | Bản chạy trực tiếp không cần mount đĩa. |
| **`SHA256SUMS`** | Checksum Text | Mã băm kiểm tra tính toàn vẹn của tệp cài đặt. |

### Các bước cài đặt:
1. Tải tệp **`UPreviewX-v0.3.0-macos-x86_64.dmg`**.
2. Nhấp đúp mở file `.dmg`, kéo biểu tượng **`UPreviewX`** vào thư mục **`Applications`**.
3. Mở `Applications` và khởi chạy `UPreviewX` lần đầu tiên.

---

## 2. Hướng dẫn cấp quyền mở lần đầu (Gatekeeper Trust UX)

UPreviewX là phần mềm mã nguồn mở độc lập và được ký số ad-hoc hợp lệ (`codesign --sign -`). Khi mở ứng dụng lần đầu trên macOS 13+, Gatekeeper có thể hiển thị cảnh báo từ chối do chưa đăng ký tài khoản trả phí Apple Developer ID:

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                       QUY TRÌNH MỞ ỨNG DỤNG LẦN ĐẦU                         │
│            (Chuẩn của Apple trên macOS 13 Ventura, 14 Sonoma, 15+)          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Cách 1 — Mở nhanh qua Finder (Khuyên dùng):                                │
│    1. Mở Finder, truy cập thư mục Applications.                             │
│    2. Nhấp chuột phải (hoặc giữ phím Control và bấm chuột) vào UPreviewX.   │
│    3. Chọn "Open" (Mở) từ menu ngữ cảnh.                                    │
│    4. Trong hộp thoại bảo mật xuất hiện, bấm nút [Open] (Mở).                │
│                                                                             │
│  Cách 2 — Xác nhận qua Cài đặt hệ thống (System Settings):                 │
│    1. Mở System Settings (Cài đặt hệ thống) → Privacy & Security.           │
│    2. Cuộn xuống mục Security (Bảo mật).                                    │
│    3. Tại dòng thông báo chặn UPreviewX, bấm nút [Open Anyway] (Vẫn mở).    │
│    4. Nhập mật khẩu máy Mac hoặc Touch ID để hoàn tất.                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!TIP]
> Bạn chỉ cần thực hiện thao tác này **duy nhất một lần**. macOS sẽ lưu ghi nhận và các lần sau bạn có thể mở video bằng cách nhấp đúp hoặc qua menu chuột phải **Open With → UPreviewX** bình thường.

---

## 3. Điểm nổi bật & Tính năng chính

- **Mở video tức thì, không màn hình chờ**: Nhấp đúp vào video hoặc dùng **Open With**, cửa sổ phát lập tức hiển thị và bắt đầu phát lại.
- **Tự động co giãn theo tỷ lệ video thực (Adaptive Aspect Ratio)**:
  - Tự động nhận diện tỷ lệ khung hình thực tế (`9:16`, `4:5` dọc, `1:1` vuông, `16:9`, `21:9` ngang), tính toán theo SAR/DAR và metadata xoay (`90°`/`270°`).
  - Video dọc (Shorts, Reels, TikTok) mở lên khớp khung hình chính xác, **không bị hai viền đen** (black bars).
  - Tự động giới hạn video 4K trong phạm vi an toàn của màn hình (`NSScreen.visibleFrame`), không bao giờ bị tràn qua Menu Bar hay Dock.
- **Vòng đời ứng dụng sạch (Clean Lifecycle)**:
  - Khi đóng cửa sổ xem video, ứng dụng **thoát hoàn toàn**.
  - Tuyệt đối không có daemon hay tiến trình chạy ngầm làm chậm máy.
- **Tách biệt Tua nhanh (Shuttle) và Tốc độ phát (Speed Playback)**:
  - **Tua nhanh (Shuttle)**: Nhấn giữ phím `←` hoặc `→` để lướt nhanh mượt mà qua các keyframe; nhả phím sẽ lập tức trả về đúng trạng thái ban đầu (đang tạm dừng tiếp tục tạm dừng, đang phát tiếp tục phát).
  - **Tốc độ phát (Speed Playback)**: Nút bấm và phím tắt chuyển đổi tức thì giữa `1×` và `2×` (mặc định phím `2`), giữ nguyên cao độ âm thanh (pitch correction).
- **Thanh HUD điều khiển nhỏ gọn**: Thiết kế tối ưu cho cả video dọc, thanh âm lượng tự động mở rộng/thu gọn thông minh, tích hợp menu phụ cho các tác vụ nâng cao.
- **Lưu ảnh chụp khung hình unscaled**: Phím tắt `⌘ + ⇧ + S` chụp khung hình gốc đang phát và lưu thành tệp PNG vào `~/Pictures/UPreviewX`.
- **Tùy chỉnh phím tắt linh hoạt**: Cửa sổ Settings native (`⌘,`) có bộ ghi phím tắt trực quan, tự phát hiện xung đột với phím tắt hệ thống macOS.
- **Tiết kiệm pin với Dual-GPU (MacBook Pro 2019)**: Tự động điều hướng OpenGL context về GPU tích hợp **Intel UHD Graphics 630**, tránh đánh thức GPU rời AMD khi đang dùng pin.
- **Lớp phủ chẩn đoán kỹ thuật (`D` hoặc `⌘I`)**: Hiển thị thời gian thực codec, bộ giải mã (Hardware VideoToolbox hay Software dav1d/FFmpeg), GPU đang chạy, FPS thực tế, số khung hình rớt, độ trễ và dung lượng RAM tiêu thụ.
- **Tự chứa 100% (Zero Dependencies)**: Đóng gói sẵn 72 thư viện dylib trong `Contents/Frameworks/`. Người dùng không cần cài đặt Homebrew, FFmpeg hay gõ Terminal.

---

## 4. Bảng phím tắt & Thao tác sử dụng

| Thao tác | Phím tắt mặc định | Mô tả |
|---|---|---|
| **Phát / Tạm dừng** | `Space` | Chuyển đổi phát/dừng; phát lại từ đầu nếu file đã kết thúc |
| **Shuttle Tua tới** | `Nhấn giữ →` | Tua nhanh mượt mà; nhả phím trở về trạng thái cũ |
| **Shuttle Tua lùi** | `Nhấn giữ ←` | Tua lùi mượt mà; nhả phím trở về trạng thái cũ |
| **Bước tới 5 giây** | `Bấm phím →` | Nhảy nhanh 5 giây tới trước |
| **Bước lùi 5 giây** | `Bấm phím ←` | Nhảy nhanh 5 giây về sau |
| **Bước chính xác 1 giây**| `⇧ + ← / →` | Tua tiến/lùi đúng 1 giây |
| **Bật/Tắt 1× / 2×** | `2` | Chuyển nhanh giữa tốc độ thường và 2× (âm thanh giữ cao độ) |
| **Lưu khung hình hiện tại** | `⌘ + ⇧ + S` | Lưu ảnh chụp uncompressed PNG vào thư mục Ảnh |
| **Toàn màn hình** | `F` hoặc `⌘ + ⌃ + F` | Chuyển đổi chế độ toàn màn hình native macOS |
| **Bật/Tắt Lớp phủ chẩn đoán** | `D` hoặc `⌘ + I` | Hiển thị thông số giải mã, FPS, CPU và bộ nhớ |
| **Chế độ xem nhanh Fast Preview** | `P` | Tăng tốc seek trên các file 4K nặng (bỏ qua in-loop filter) |
| **Tăng / Giảm âm lượng** | `↑` / `↓` | Điều chỉnh âm lượng ±5% |
| **Tắt tiếng (Mute)** | `M` | Tắt hoặc bật lại âm thanh |
| **Cài đặt (Settings)** | `⌘ + ,` | Mở hộp thoại cấu hình và bộ ghi phím tắt |
| **Mở video mới** | `⌘ + O` | Hộp thoại chọn tệp video tiêu chuẩn |
| **Đóng cửa sổ** | `⌘ + W` | Đóng cửa sổ đang phát (tự thoát app nếu là cửa sổ cuối) |
| **Thoát ứng dụng** | `⌘ + Q` | Thoát ứng dụng UPreviewX |

---

## 5. Yêu cầu hệ thống & Kiến trúc tương thích

- **Hệ điều hành**: macOS 13.0 (Ventura) trở lên (hỗ trợ đầy đủ macOS 14 Sonoma và macOS 15 Sequoia).
- **Kiến trúc phần cứng**:
  - **macOS Intel (`x86_64`)**: Hỗ trợ native (tối ưu hóa phần cứng dòng MacBook Pro, iMac, Mac mini Intel).
  - **Apple Silicon (M1/M2/M3/M4)**: Chạy ổn định thông qua môi trường chuyển đổi Rosetta 2 của macOS. Bản build native `arm64` hoàn chỉnh sẽ được cập nhật khi hoàn tất kiểm chứng trên phần cứng Apple Silicon.

---

## 6. Hướng dẫn gỡ cài đặt sạch (Uninstallation)

Nếu bạn không còn nhu cầu sử dụng:
1. Thoát hoàn toàn UPreviewX nếu đang mở (`⌘Q`).
2. Kéo `/Applications/UPreviewX.app` vào Thùng rác (Trash).
3. *(Tùy chọn)* Xóa file lưu cấu hình và phím tắt cá nhân:
   ```bash
   rm -f ~/Library/Preferences/com.vuphm.upreviewx.plist
   ```

---

## 7. Tài liệu chuyên sâu & Hướng dẫn Nhà phát triển

- [Báo cáo Đo lường Hiệu năng & Benchmarks](docs/BENCHMARKS.md): Đo lường chi tiết kích thước cửa sổ, FPS thực tế, thử nghiệm đa codec và phân tích áp lực video 4K trên CPU Intel Coffee Lake.
- [Tài liệu Kỹ thuật & Phát triển](docs/DEVELOPMENT.md): Chi tiết kiến trúc mô-đun, cơ chế dựng hình OpenGL/CGL, điều phối đồ họa kép và hướng dẫn các lệnh `make`.
- [Quy ước Đóng góp (Contributing Guidelines)](CONTRIBUTING.md): Hướng dẫn gửi PR, báo lỗi và tiêu chuẩn mã nguồn.

---

## 8. Giấy phép & Bản quyền bên thứ ba

UPreviewX được phát hành theo giấy phép **GNU General Public License v2.0 or later (GPLv2+)** ([LICENSE](LICENSE)) do liên kết với bản build động GPL của `libmpv` và `FFmpeg`.

Xem chi tiết danh sách bản quyền, thông báo pháp lý và liên kết mã nguồn của các thư viện tại [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
