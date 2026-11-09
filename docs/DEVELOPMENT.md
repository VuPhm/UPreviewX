# UPreviewX — Tài liệu Kỹ thuật & Hướng dẫn Nhà phát triển

Tài liệu này cung cấp chi tiết về kiến trúc mã nguồn, cơ chế dựng hình OpenGL / CGL, quản lý tiến trình và quy trình xây dựng ứng dụng **UPreviewX**.

---

## 1. Cấu trúc Mô-đun (Architecture)

UPreviewX được phân tách thành các tầng độc lập để đảm bảo tính module hóa và dễ bảo trì:

```text
Sources/
├── CMPV/                               # C module, CGL virtual-screen selector & Mach usage shim
│   ├── include/mpv_shim.h
│   ├── include/module.modulemap
│   └── shim.c
├── UPreviewXCore/
│   ├── Engine/                         # Playback engine & rendering layer
│   │   ├── PlaybackDiagnostics.swift   # Real-time decoding telemetry data model
│   │   ├── PlaybackEngineProtocol.swift
│   │   ├── MPVPlaybackEngine.swift     # 100% async property/command pipeline over libmpv
│   │   └── MPVVideoView.swift          # NSView + CAOpenGLLayer (mpv_render_context)
│   ├── Services/                       # Reserved conversion interface (decoupled)
│   │   └── ConversionServiceProtocol.swift
│   ├── Settings/                       # User preferences & customizable shortcuts
│   │   ├── UserSettings.swift
│   │   └── KeyShortcut.swift
│   └── UI/                             # Native AppKit adaptive window & HUD controls
│       ├── PlayerWindowController.swift
│       ├── HUDControlsView.swift
│       ├── DiagnosticsOverlayView.swift
│       ├── SettingsWindowController.swift
│       └── TimeFormatter.swift
└── UPreviewX/                          # Application lifecycle & CLI benchmark runner
    ├── AppDelegate.swift
    └── main.swift
```

---

## 2. Cơ chế Điều hướng GPU kép (Dual-GPU Awareness)

Trên các dòng MacBook Pro Intel trang bị hai GPU (như MacBook Pro 16-inch 2019 với Intel UHD 630 và AMD Radeon Pro 5300M):
- Hệ điều hành macOS thường tự động kích hoạt GPU AMD rời khi một ứng dụng khởi tạo OpenGL context, làm tiêu hao pin nhanh chóng.
- UPreviewX giải quyết vấn đề này tại hai cấp độ:
  1. **Metadata**: Cấu hình `NSSupportsAutomaticGraphicsSwitching = true` trong `Info.plist`.
  2. **CGL Virtual Screen**: Thiết lập thuộc tính `kCGLPFASupportsAutomaticGraphicsSwitching` và `kCGLPFAAllowOfflineRenderers`. Hàm `cmpv_prefer_integrated_gpu` trong `CMPV/shim.c` duyệt qua các virtual screen khả dụng của CGL và chủ động chọn renderer chứa chuỗi `"Intel"`.

---

## 3. Quản lý Thư viện Động Runtime (Vendor/lib & Frameworks)

- Toàn bộ các thư viện giải mã gồm `libmpv.2.dylib` và FFmpeg được đặt trong `Contents/Frameworks/`.
- Mã nhị phân chính `UPreviewX` liên kết thông qua `@rpath/libmpv.2.dylib` với LC_RPATH trỏ về `@executable_path/../Frameworks`.
- Các dylib phụ thuộc lẫn nhau cũng được viết lại đường dẫn liên kết dạng `@rpath/lib*.dylib`, loại bỏ 100% sự phụ thuộc vào đường dẫn tuyệt đối hoặc Homebrew trên máy người dùng.

---

## 4. Các lệnh Make hỗ trợ phát triển

```bash
# 1. Biên dịch nhị phân
make build

# 2. Chạy bộ kiểm thử đơn vị
make test

# 3. Đóng gói bundle ứng dụng dist/UPreviewX.app
make app

# 4. Đóng gói bộ phân phối (DMG, ZIP, SHA256SUMS)
make package

# 5. Chạy cổng kiểm tra phát hành (Release check)
make release-check

# 6. Chạy thử nghiệm phát lại và benchmark trên bộ test vector
make validate

# 7. Cài đặt vào ~/Applications (cho nhà phát triển thử nghiệm)
make install

# 8. Gỡ cài đặt khỏi ~/Applications
make uninstall
```

---

## 5. Chạy Tiện ích Dòng lệnh & Benchmark

```bash
# Mở video kèm lớp phủ chẩn đoán kỹ thuật:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --diagnostics /path/to/video.mp4

# Mở với chế độ xem nhanh Fast Preview (bỏ qua loop filter trên video 4K nặng):
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --fast-preview /path/to/video.mp4

# Chạy benchmark tự động trên một file:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark /path/to/video.mp4

# Chạy benchmark suite trên toàn bộ thư mục video:
./dist/UPreviewX.app/Contents/MacOS/UPreviewX --benchmark-suite /path/to/video_dir
```
