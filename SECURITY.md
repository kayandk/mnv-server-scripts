# Chính Sách Bảo Mật (Security Policy)

## 1. Nguyên Tắc Quản Lý Bí Mật (Secret Management)

Script `bootstrap-server.sh` thao tác trực tiếp với các khóa truy cập Cloudflare R2 và token hệ thống:

- **KHÔNG BAO GIỜ** ghi cứng (hardcode) giá trị bí mật (`R2_SECRET_ACCESS_KEY`, `JWT_SECRET`,...) vào mã nguồn hoặc file script.
- **KHÔNG COMMIT** file `.env`, file sao lưu database (`*.sqlite`), hoặc tệp chứa thông tin hạ tầng lên Git.
- Truyền biến môi trường trực tiếp trong phiên dòng lệnh (session env) hoặc sử dụng cơ chế bảo mật (như Vault, AWS Secrets Manager, GitHub Secrets).

## 2. Phân Quyền Cloudflare R2 Tối Thiểu (Principle of Least Privilege)

- **API Token R2:** Chỉ cấp quyền `Object Read & Write` cho đúng **1 Bucket** được chỉ định (`R2_BUCKET_NAME`).
- **Tuyệt đối KHÔNG:**
  - Dùng API Key cấp độ Global/Account Admin cho bootstrap script.
  - Cấu hình Bucket R2 ở chế độ **Public Access** (truy cập công khai không cần auth). Dữ liệu snapshot database SQLite (`state/panel-latest.sqlite.gz`) chứa thông tin cấu hình toàn bộ hệ thống; nếu bucket bị public, toàn bộ dữ liệu sẽ bị lộ.

## 3. Quản Lý Tường Lửa (Firewall & Ports)

- Trong quá trình bootstrap ban đầu, script tạm thời mở cổng `${PANEL_PORT}/tcp` (mặc định 4000) để quản trị viên có thể truy cập ngay qua IP trước khi DNS hoàn tất trỏ về.
- **Khuyến nghị ngay sau khi cài đặt:**
  ```bash
  sudo ufw delete allow 4000/tcp
  ```
  Chỉ cho phép truy cập Web qua cổng chuẩn 80/443 thông qua Nginx Reverse Proxy và Cloudflare WAF/Proxy.

## 4. Báo Cáo Lỗ Hổng Bảo Mật (Reporting a Vulnerability)

Nếu bạn phát hiện bất kỳ vấn đề hoặc lỗ hổng bảo mật nào trong script này:
- Vui lòng **KHÔNG** tạo Issue công khai trên GitHub.
- Hãy liên hệ trực tiếp với đội ngũ quản trị hoặc kỹ thuật nội bộ của dự án để được xử lý kịp thời.

