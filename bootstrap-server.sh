#!/usr/bin/env bash
# ==============================================================================
# MNV Panel – Dựng server mới & khôi phục TOÀN BỘ hiện trạng từ Cloudflare R2
#
#   R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... R2_BUCKET_NAME=... \
#   PANEL_DOMAIN=panel.example.com \
#   bash bootstrap-server.sh
#
# Ubuntu 22.04/24.04, chạy bằng root. Chạy lại nhiều lần an toàn (idempotent).
#  1. Cài Node.js 22, PM2, Nginx, Certbot, swap
#  2. Tải bản MNV Panel mới nhất + snapshot cấu hình mới nhất từ R2
#  3. Khởi động panel; panel tự: ghi .env, deploy lại đúng commit đang chạy,
#     dựng Nginx cho domain, cấp SSL khi DNS trỏ về server mới.
#
# Biến tùy chọn:
#   PANEL_DOMAIN   domain truy cập panel (vd panel.example.com). Bỏ trống => http://IP:4000
#   PANEL_PORT     mặc định 4000
#   PANEL_SHA      cài đúng commit panel này thay vì bản mới nhất
#   STATE_KEY      dùng snapshot cụ thể (key trên R2) thay vì state/panel-latest.sqlite.gz
#   FRESH=1        KHÔNG khôi phục cấu hình (cài panel trắng)
#   R2_ENDPOINT    endpoint S3 tùy chỉnh (MinIO…); mặc định https://<account>.r2.cloudflarestorage.com
# ==============================================================================
set -euo pipefail

PANEL_DIR=/var/www/panel
APP_DIR=/var/www/app
PANEL_PORT="${PANEL_PORT:-4000}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
WORK=/tmp/mnv-bootstrap

c_ok() { echo -e "\033[32m✔ $*\033[0m"; }
c_step() { echo -e "\n\033[36m==> $*\033[0m"; }
die() { echo -e "\033[31m❌ $*\033[0m" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Hãy chạy bằng root (sudo bash bootstrap-server.sh)"

# Tự động nạp file .env nếu có (trong thư mục hiện tại hoặc cùng thư mục script)
ENV_FILE=""
if [ -f "./.env" ]; then
  ENV_FILE="./.env"
elif [ -f "$(dirname "$0")/.env" ]; then
  ENV_FILE="$(dirname "$0")/.env"
fi

if [ -n "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  c_ok "Đã nạp cấu hình từ $ENV_FILE"
fi

for v in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET_NAME; do
  [ -n "${!v:-}" ] || die "Thiếu biến $v (truyền qua ENV hoặc khai báo trong file .env)"
done

# ------------------------------------------------------------------------------
c_step "1/6 Cài gói hệ thống (nginx, certbot, swap)"
export DEBIAN_FRONTEND=noninteractive

MISSING_PKGS=()
for pkg in curl ca-certificates tar gzip nginx certbot python3-certbot-nginx ufw; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  c_step "Cài các gói còn thiếu: ${MISSING_PKGS[*]}"
  apt-get update -y -qq
  apt-get install -y -qq "${MISSING_PKGS[@]}" >/dev/null
  c_ok "Đã cài đặt xong gói hệ thống còn thiếu"
else
  c_ok "Gói hệ thống đã có đủ (bỏ qua apt-get install)"
fi

if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10; grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  c_ok "Đã tạo swap 2GB"
else
  c_ok "Swap đã sẵn sàng (bỏ qua tạo swap)"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
  c_ok "Nginx service đang hoạt động"
else
  systemctl enable --now nginx >/dev/null 2>&1 || nginx 2>/dev/null || true
  c_ok "Nginx service đã kích hoạt"
fi

# ------------------------------------------------------------------------------
c_step "2/6 Cài Node.js 22 & PM2"
NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0)
fi

if [ "${NODE_MAJOR:-0}" -ge 22 ]; then
  c_ok "Node.js đã sẵn sàng: $(node -v) (>= v22, bỏ qua cài đặt)"
else
  c_step "Cài Node.js 22 LTS qua NodeSource (hiện tại: $(node -v 2>/dev/null || echo 'chưa cài'))"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
  c_ok "Đã cài Node.js $(node -v)"
fi

NPM_BIN="$(npm config get prefix 2>/dev/null)/bin"
export PATH="$PATH:/usr/local/bin:$NPM_BIN"
hash -r 2>/dev/null || true

if command -v pm2 >/dev/null 2>&1; then
  c_ok "PM2 đã sẵn sàng: v$(pm2 -v 2>/dev/null) (bỏ qua cài đặt)"
else
  npm install -g pm2 --silent >/dev/null
  hash -r 2>/dev/null || true
  c_ok "Đã cài PM2 v$(pm2 -v 2>/dev/null || echo 'mới nhất')"
fi

# ------------------------------------------------------------------------------
c_step "3/6 Tải MNV Panel & snapshot cấu hình từ R2 (bucket ${R2_BUCKET_NAME})"
rm -rf "$WORK" && mkdir -p "$WORK" && cd "$WORK"
echo '{"type":"module","private":true}' > package.json
npm install --silent --no-audit --no-fund @aws-sdk/client-s3@3 >/dev/null
cat > fetch.mjs <<'NODE'
import fs from 'node:fs';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { S3Client, GetObjectCommand, ListObjectsV2Command } from '@aws-sdk/client-s3';

const env = process.env;
const Bucket = env.R2_BUCKET_NAME;
const s3 = new S3Client({
  region: 'auto',
  endpoint: env.R2_ENDPOINT || `https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  forcePathStyle: Boolean(env.R2_ENDPOINT),
  credentials: { accessKeyId: env.R2_ACCESS_KEY_ID, secretAccessKey: env.R2_SECRET_ACCESS_KEY },
});
const get = async (Key) => (await s3.send(new GetObjectCommand({ Bucket, Key }))).Body;
const getText = async (Key) => {
  try { return await (await get(Key)).transformToString(); } catch { return null; }
};
const list = async (Prefix) => {
  const out = []; let ContinuationToken;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket, Prefix, ContinuationToken }));
    out.push(...(r.Contents || []));
    ContinuationToken = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (ContinuationToken);
  return out.sort((a, b) => b.LastModified - a.LastModified);
};
const download = async (Key, file) => pipeline(await get(Key), fs.createWriteStream(file));
const sha256 = (f) => crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex');

// --- panel
let sha = env.PANEL_SHA, manifest = null;
if (!sha) {
  const latest = await getText('releases/panel/latest.manifest.json');
  if (latest) { manifest = JSON.parse(latest); sha = manifest.commitSha; }
  else {
    const tgz = (await list('releases/panel/')).find((o) => /[a-f0-9]{7,40}\.tar\.gz$/.test(o.Key));
    if (!tgz) throw new Error('Không có bản panel nào tại releases/panel/ – chạy "npm run release:panel" trên máy dev trước.');
    sha = tgz.Key.match(/([a-f0-9]{7,40})\.tar\.gz$/)[1];
  }
}
if (!manifest) { const m = await getText(`releases/panel/${sha}.manifest.json`); manifest = m ? JSON.parse(m) : null; }
await download(`releases/panel/${sha}.tar.gz`, 'panel.tar.gz');
if (manifest?.sha256Checksum && sha256('panel.tar.gz') !== manifest.sha256Checksum) throw new Error('SHA-256 gói panel không khớp manifest');
console.log(`   panel  : ${sha.slice(0, 7)} ${manifest?.version ? 'v' + manifest.version : ''} ${manifest?.message || ''}`);

// --- snapshot cấu hình
if (env.FRESH !== '1') {
  let key = env.STATE_KEY;
  let meta = null;
  if (!key) {
    const m = await getText('state/panel-latest.json');
    if (m) { meta = JSON.parse(m); key = 'state/panel-latest.sqlite.gz'; }
    else {
      const b = (await list('backups/panel/')).find((o) => o.Key.endsWith('.sqlite.gz'));
      if (b) key = b.Key;
    }
  }
  if (key) {
    await download(key, 'panel.sqlite.gz');
    await pipeline(fs.createReadStream('panel.sqlite.gz'), zlib.createGunzip(), fs.createWriteStream('panel.sqlite'));
    console.log(`   cấu hình: ${key}${meta ? ` (đồng bộ lúc ${meta.syncedAt}, app ${meta.appName}, commit ${String(meta.lastSuccessfulCommit || '').slice(0, 7)}, domain ${meta.appDomain || '—'})` : ''}`);
    if (meta?.panelDomain) fs.writeFileSync('panel-domain.txt', meta.panelDomain);
  } else {
    console.log('   cấu hình: không tìm thấy snapshot – panel sẽ khởi động trắng');
  }
}
NODE
node fetch.mjs || die "Không tải được dữ liệu từ R2 (kiểm tra R2_* và kết nối mạng)"
[ -z "$PANEL_DOMAIN" ] && [ -f panel-domain.txt ] && PANEL_DOMAIN=$(cat panel-domain.txt)

# ------------------------------------------------------------------------------
c_step "4/6 Cài panel vào ${PANEL_DIR}"
mkdir -p "$PANEL_DIR/data" "$APP_DIR/releases/blue" "$APP_DIR/releases/green" "$APP_DIR/shared"
if pm2 describe mnv-panel >/dev/null 2>&1; then pm2 stop mnv-panel >/dev/null 2>&1 || true; fi
rm -rf "$PANEL_DIR/dist" "$PANEL_DIR/public"
tar xzf "$WORK/panel.tar.gz" -C "$PANEL_DIR"
(cd "$PANEL_DIR" && npm install --omit=dev --silent --no-audit --no-fund >/dev/null)

if [ -f "$WORK/panel.sqlite" ]; then
  if [ -f "$PANEL_DIR/data/panel.sqlite" ]; then
    cp "$PANEL_DIR/data/panel.sqlite" "$PANEL_DIR/data/panel.sqlite.before-restore-$(date +%s)"
  fi
  rm -f "$PANEL_DIR/data/panel.sqlite-wal" "$PANEL_DIR/data/panel.sqlite-shm"
  cp "$WORK/panel.sqlite" "$PANEL_DIR/data/panel.sqlite"
  printf '{"panelDomain":"%s","at":"%s"}\n' "$PANEL_DOMAIN" "$(date -Is)" > "$PANEL_DIR/data/.restore-pending.json"
  c_ok "Đã khôi phục cấu hình panel – sẽ tự dựng lại ứng dụng khi khởi động"
fi

if [ ! -f "$PANEL_DIR/.env" ]; then
  cat > "$PANEL_DIR/.env" <<EOF
PORT=${PANEL_PORT}
HOST=0.0.0.0
JWT_SECRET=$(openssl rand -hex 32)
R2_ACCOUNT_ID=${R2_ACCOUNT_ID}
R2_ACCESS_KEY_ID=${R2_ACCESS_KEY_ID}
R2_SECRET_ACCESS_KEY=${R2_SECRET_ACCESS_KEY}
R2_BUCKET_NAME=${R2_BUCKET_NAME}
EOF
  chmod 600 "$PANEL_DIR/.env"
fi
c_ok "Panel đã cài"

# ------------------------------------------------------------------------------
c_step "5/6 Nginx cho panel & firewall"
if [ -n "$PANEL_DOMAIN" ]; then
  cat > /etc/nginx/sites-available/mnv-panel.conf <<EOF
# Managed by MNV Panel bootstrap
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
EOF
  ln -sf /etc/nginx/sites-available/mnv-panel.conf /etc/nginx/sites-enabled/mnv-panel.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null 2>&1 || die "Cấu hình nginx lỗi (nginx -t)"
  nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || systemctl start nginx 2>/dev/null || nginx
  c_ok "Nginx: http://${PANEL_DOMAIN} → panel"
fi
ufw allow 22/tcp >/dev/null 2>&1 || true; ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true
# mở cổng panel để vào ngay bằng IP trước khi chuyển DNS (đóng lại sau: ufw delete allow ${PANEL_PORT}/tcp)
ufw allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
c_step "6/6 Khởi động panel"
cd "$PANEL_DIR"
if pm2 describe mnv-panel >/dev/null 2>&1; then pm2 restart mnv-panel --update-env >/dev/null; else pm2 start ecosystem.config.cjs >/dev/null; fi
pm2 save >/dev/null
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:${PANEL_PORT}/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fs "http://127.0.0.1:${PANEL_PORT}/health" >/dev/null || die "Panel không khởi động – xem: pm2 logs mnv-panel"
rm -rf "$WORK"

IP=$(curl -fs --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
echo
echo "=================================================================="
c_ok "SERVER MỚI ĐÃ SẴN SÀNG"
echo "  Panel ngay bây giờ : http://${IP}:${PANEL_PORT}"
[ -n "$PANEL_DOMAIN" ] && echo "  Panel sau khi trỏ DNS: https://${PANEL_DOMAIN}"
echo "  Đăng nhập bằng mật khẩu panel CŨ (đã khôi phục từ R2)."
echo "  Trang Tổng quan hiển thị tiến trình khôi phục: .env → deploy → Nginx → SSL."
echo
echo "  Việc còn lại: trỏ bản ghi DNS A của domain app & panel về ${IP}."
echo "  Panel tự cấp SSL khi DNS cập nhật (kiểm tra mỗi 2 phút)."
echo "=================================================================="
