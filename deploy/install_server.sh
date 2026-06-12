#!/usr/bin/env bash
set -euo pipefail
#
# Mimir production server installer (idempotent).
#
# Fresh box:
#   sudo mkdir -p /opt/mimir && sudo chown $USER /opt/mimir
#   git clone https://github.com/ryanlane/mimir-release.git /opt/mimir/mimir-release
#   bash /opt/mimir/mimir-release/deploy/install_server.sh
#
# Requirements: docker + compose plugin, git. If the GHCR packages are
# private, run `docker login ghcr.io` first (PAT with read:packages).

cd "$(dirname "${BASH_SOURCE[0]}")"

info() { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"

DATA_DIR="${MIMIR_DATA_DIR:-/opt/mimir/data}"

# ---------- .env ----------
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate secrets in place
  gen() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(gen)|" .env
  sed -i "s|^MQTT_PASSWORD=.*|MQTT_PASSWORD=$(gen)|" .env
  chmod 600 .env
  warn ".env created with generated secrets — EDIT IT NOW and set PUBLIC_HOST / MQTT_PUBLIC_HOST"
  warn "then re-run this script"
  exit 0
fi

grep -qE '^PUBLIC_HOST=(change-me|)$' .env \
  && die "PUBLIC_HOST in .env is unset — set your server's LAN IP"
grep -qE '^PUBLIC_HOST=192\.168\.1\.50$' .env \
  && warn "PUBLIC_HOST is the example value (192.168.1.50) — make sure that's really this server's IP"

MQTT_USER_VAL=$(grep -E '^MQTT_USER=' .env | cut -d= -f2)
MQTT_PASS_VAL=$(grep -E '^MQTT_PASSWORD=' .env | cut -d= -f2)

# ---------- mosquitto passwd ----------
if [ ! -f mosquitto/passwd ]; then
  info "generating mosquitto/passwd for '$MQTT_USER_VAL'"
  rm -rf mosquitto/passwd
  docker run --rm -v "$(pwd)/mosquitto:/work" eclipse-mosquitto:2 \
    mosquitto_passwd -c -b /work/passwd "$MQTT_USER_VAL" "$MQTT_PASS_VAL"
  sudo chown "$(id -u):$(id -g)" mosquitto/passwd 2>/dev/null || true
  chmod 644 mosquitto/passwd
fi

# ---------- data dirs ----------
mkdir -p "$DATA_DIR/uploads" "$DATA_DIR/channels" "$DATA_DIR/client-releases"

# ---------- first render + pull ----------
bash ./mimir-update.sh || die "initial update failed — check versions.yml pins and GHCR access"

# ---------- seed channels from image (first install only) ----------
if [ -f .env.versions ] && [ -z "$(ls -A "$DATA_DIR/channels" 2>/dev/null)" ]; then
  SERVER_TAG=$(grep -E '^MIMIR_SERVER_TAG=' .env.versions | cut -d= -f2)
  info "seeding bundled channels from mimir-api:${SERVER_TAG}"
  CID=$(docker create "ghcr.io/ryanlane/mimir-api:${SERVER_TAG}")
  docker cp "$CID:/app/channels/." "$DATA_DIR/channels/"
  docker rm "$CID" >/dev/null
fi

# ---------- systemd units ----------
info "installing mimir-update systemd timer"
sudo cp mimir-update.service mimir-update.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mimir-update.timer

info "done. Useful commands:"
cat <<'EOF'
  systemctl list-timers mimir-update.timer       # next run
  journalctl -u mimir-update.service -f          # update logs
  docker compose --env-file .env --env-file .env.versions ps
EOF
