#!/usr/bin/env bash
# ==============================================================================
# MNV Panel – Gỡ cài đặt hoàn toàn & Xóa sạch dữ liệu hệ thống
#
# Cách dùng:
#   sudo bash uninstall-server.sh             # Hỏi xác nhận trước khi xóa
#   sudo bash uninstall-server.sh --force     # Xóa ngay không cần hỏi
#   sudo bash uninstall-server.sh --purge     # Xóa panel + xóa cả Swap 2GB & Nginx conf
# ==============================================================================
set -euo pipefail

PANEL_DIR=/var/www/panel
APP_DIR=/var/www/app
WORK=/tmp/mnv-bootstrap
FORCE=0
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --force|-f|-y) FORCE=1 ;;
    --purge) PURGE=1 ;;
  esac
done

c_ok() { echo -e "\033[32m✔ $*\033[0m"; }
c_warn() { echo -e "\033[33m⚠ $*\033[0m"; }
c_step() { echo -e "\n\033[36m==> $*\033[0m"; }
die() { echo -e "\033[31m❌ $*\033[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Hãy chạy bằng root (sudo bash uninstall-server.sh)"

# Tự động nạp .env để lấy thông tin PORT & DOMAIN nếu có
ENV_FILE=""
if [ -f "./.env" ]; then
  ENV_FILE="./.env"
elif [ -f "$PANEL_DIR/.env" ]; then
  ENV_FILE="$PANEL_DIR/.env"
elif [ -f "$(dirname "$0")/.env" ]; then
  ENV_FILE="$(dirname "$0")/.env"
fi

if [ -n "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

PANEL_PORT="${PANEL_PORT:-4000}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"

# Cảnh báo xác nhận
if [ "$FORCE" -ne 1 ]; then
  echo "=================================================================="
  c_warn "CẢNH BÁO: THAO TÁC NÀY SẼ XÓA TOÀN BỘ HỆ THỐNG MNV PANEL!"
  echo "  - Dừng và xóa tiến trình PM2 (mnv-panel)"
  echo "  - Xóa toàn bộ mã nguồn & database SQLite tại: ${PANEL_DIR}"
  echo "  - Xóa toàn bộ dữ liệu ứng dụng tại: ${APP_DIR}"
  echo "  - Gỡ cấu hình virtual host Nginx của panel"
  echo "  - Đóng cổng firewall ${PANEL_PORT}/tcp"
  if [ "$PURGE" -eq 1 ]; then
    echo "  - [PURGE] Xóa cả file swap 2GB (/swapfile)"
  fi
  echo "=================================================================="
  read -rp "Bạn có chắc chắn muốn xóa sạch dữ liệu không? (Nhập 'yes' để xác nhận): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Đã hủy thao tác gỡ cài đặt."
    exit 0
  fi
fi

# ------------------------------------------------------------------------------
c_step "1/5 Dừng và gỡ bỏ tiến trình PM2"
PM2_CMD="pm2"
command -v pm2 >/dev/null 2>&1 || PM2_CMD="/usr/local/bin/pm2"

if command -v "$PM2_CMD" >/dev/null 2>&1; then
  if $PM2_CMD describe mnv-panel >/dev/null 2>&1; then
    $PM2_CMD stop mnv-panel >/dev/null 2>&1 || true
    $PM2_CMD delete mnv-panel >/dev/null 2>&1 || true
    $PM2_CMD save --force >/dev/null 2>&1 || true
    c_ok "Đã dừng và xóa tiến trình mnv-panel khỏi PM2"
  else
    c_ok "Không tìm thấy tiến trình mnv-panel đang chạy trong PM2"
  fi
else
  c_warn "Không tìm thấy lệnh pm2, bỏ qua bước PM2"
fi

# ------------------------------------------------------------------------------
c_step "2/5 Xóa sạch thư mục mã nguồn và dữ liệu"
if [ -d "$PANEL_DIR" ]; then
  rm -rf "$PANEL_DIR"
  c_ok "Đã xóa thư mục Panel: ${PANEL_DIR}"
else
  c_ok "Thư mục ${PANEL_DIR} không tồn tại"
fi

if [ -d "$APP_DIR" ]; then
  rm -rf "$APP_DIR"
  c_ok "Đã xóa thư mục App: ${APP_DIR}"
else
  c_ok "Thư mục ${APP_DIR} không tồn tại"
fi

rm -rf "$WORK"
c_ok "Đã dọn dẹp thư mục tạm ${WORK}"

# ------------------------------------------------------------------------------
c_step "3/5 Dọn dẹp cấu hình Nginx"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/mnv-panel.conf"
NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/mnv-panel.conf"

RELOAD_NGINX=0
if [ -f "$NGINX_CONF_ENABLED" ] || [ -L "$NGINX_CONF_ENABLED" ]; then
  rm -f "$NGINX_CONF_ENABLED"
  RELOAD_NGINX=1
fi
if [ -f "$NGINX_CONF_AVAILABLE" ]; then
  rm -f "$NGINX_CONF_AVAILABLE"
  RELOAD_NGINX=1
fi

# Khôi phục default site nếu có sẵn
if [ -f /etc/nginx/sites-available/default ] && [ ! -e /etc/nginx/sites-enabled/default ]; then
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
  RELOAD_NGINX=1
fi

if [ "$RELOAD_NGINX" -eq 1 ]; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    c_ok "Đã gỡ virtual host Nginx và reload cấu hình"
  else
    c_warn "Cấu hình Nginx chưa chuẩn (nginx -t), vui lòng kiểm tra lại /etc/nginx"
  fi
else
  c_ok "Không có cấu hình Nginx của panel cần dọn dẹp"
fi

# ------------------------------------------------------------------------------
c_step "4/5 Đóng cổng tường lửa (UFW)"
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  c_ok "Đã đóng cổng firewall ${PANEL_PORT}/tcp"
fi

# ------------------------------------------------------------------------------
c_step "5/5 Dọn dẹp mở rộng (Purge)"
if [ "$PURGE" -eq 1 ]; then
  if [ -f /swapfile ]; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    sed -i '\#/swapfile#d' /etc/fstab 2>/dev/null || true
    c_ok "Đã gỡ bỏ swapfile 2GB và cập nhật /etc/fstab"
  fi
  if [ -n "$PANEL_DOMAIN" ] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$PANEL_DOMAIN" --non-interactive >/dev/null 2>&1 || true
    c_ok "Đã dọn dẹp chứng chỉ Certbot cho domain ${PANEL_DOMAIN}"
  fi
else
  c_ok "Bỏ qua dọn dẹp Swap & Certbot (dùng cờ --purge nếu muốn xóa cả swap)"
fi

echo
echo "=================================================================="
c_ok "GỠ CÀI ĐẶT MNV PANEL HOÀN TẤT!"
echo "  Hệ thống đã được dọn sạch toàn bộ mã nguồn và cơ sở dữ liệu."
echo "=================================================================="
