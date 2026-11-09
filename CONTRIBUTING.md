# Contributing to UPreviewX

Cảm ơn bạn đã quan tâm đóng góp cho dự án **UPreviewX**! Chúng tôi hoan nghênh các đóng góp về mã nguồn, sửa lỗi, tối ưu hóa hiệu năng, cải thiện tài liệu và đề xuất tính năng mới.

---

## 1. Nguyên tắc Phát triển (Core Principles)

1. **Native & Lightweight:**
   - Sử dụng Swift và AppKit thuần.
   - Tuyệt đối không cài đặt daemon hoặc service chạy ngầm.
   - Đóng cửa sổ là thoát ứng dụng hoàn toàn (`applicationShouldTerminateAfterLastWindowClosed = true`).
   - Khởi động nhanh, tiêu tốn ít RAM và giữ thời lượng pin tối ưu.
2. **Trải nghiệm Preview Tức thì (Direct Video Window):**
   - Mở thẳng cửa sổ xem video, không có màn hình chờ hay cửa sổ đệm.
   - Thích ứng kích thước cửa sổ theo đúng tỷ lệ hiển thị thực (`9:16`, `1:1`, `16:9`, `21:9`) và rotation metadata.
3. **Phần cứng Tiêu chuẩn (Baseline Focus):**
   - Hệ thống tham chiếu baseline: **Intel MacBook Pro 16-inch 2019** (macOS 13.0+).
   - Tối ưu hóa điều phối đồ họa kép (ưu tiên Intel UHD Graphics 630).
   - Tiếp cận Apple Silicon theo kiến trúc chuẩn xác thực tế, không giả lập hỗ trợ khi chưa đủ điều kiện.
4. **An toàn Hệ thống & Phân phối:**
   - Không tự ý can thiệp xóa quarantine của macOS hoặc yêu cầu tắt Gatekeeper.
   - Bản phân phối phải tự chứa 100% (zero dependencies trên máy người dùng cuối).

---

## 2. Quy trình Làm việc Local (Local Development Workflow)

### Yêu cầu môi trường
- macOS 13.0 trở lên (Intel x86_64 hoặc môi trường Rosetta 2).
- Xcode 15+ / Swift 5.10+ Command Line Tools.

### Các lệnh kiểm thử & đóng gói
```bash
# 1. Biên dịch ứng dụng
make build

# 2. Chạy bộ kiểm thử đơn vị
make test

# 3. Đóng gói ứng dụng standalone vào dist/UPreviewX.app
make app

# 4. Đóng gói bộ cài đặt phân phối (DMG, ZIP, SHA256SUMS)
make package

# 5. Chạy cổng kiểm tra phát hành (10 tiêu chí nghiêm ngặt)
make release-check

# 6. Chạy thử nghiệm phát lại và benchmark trên bộ test vector
make validate
```

---

## 3. Quy ước Gửi Pull Request (PR)

1. Luôn tạo nhánh mới từ `main` với tên nhánh có ý nghĩa:
   ```bash
   git checkout -b feat/ten-tinh-nang
   # hoặc
   git checkout -b fix/ten-loi
   ```
2. Đảm bảo toàn bộ kiểm thử và cổng phát hành đều vượt qua:
   ```bash
   make test
   make release-check
   ```
3. Commit messages rõ ràng, tuân thủ conventional commits (ví dụ: `feat: ...`, `fix: ...`, `docs: ...`, `ci: ...`).
4. Tuyệt đối không commit các file nhị phân lớn, đường dẫn cá nhân, thông tin nhạy cảm hoặc thư mục build tạm (`.build`, `dist`, `Vendor/lib`).
5. Tạo Pull Request trỏ về nhánh `main`.
