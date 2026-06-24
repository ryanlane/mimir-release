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
  info ".env created with generated secrets"
  info "Mimir will be accessible at http://mimir.local:8080 on your LAN (no IP config needed)"
  info "If mDNS doesn't work in your environment, set PUBLIC_HOST in .env before re-running"
  info "then re-run this script to complete installation"
  exit 0
fi

# PUBLIC_HOST is optional — mDNS handles LAN discovery for most setups.
# Only warn if it's set to the example placeholder (clearly unintentional).
grep -qE '^PUBLIC_HOST=192\.168\.1\.50$' .env \
  && warn "PUBLIC_HOST is still the example value (192.168.1.50) — update it or leave it blank to use mDNS"

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
# Docker (root) may have created these as bind-mount mountpoints before we
# did — repair ownership so the update script can write the release cache.
mkdir -p "$DATA_DIR/uploads" "$DATA_DIR/channels" "$DATA_DIR/client-releases" 2>/dev/null || true
if [ ! -w "$DATA_DIR/client-releases" ]; then
  warn "data dirs are root-owned (created by docker) — repairing ownership"
  sudo mkdir -p "$DATA_DIR/uploads" "$DATA_DIR/channels" "$DATA_DIR/client-releases"
  sudo chown -R "$(id -u):$(id -g)" "$DATA_DIR"
fi

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

info "done. Mimir is running."
info "Web UI: http://mimir.local:8080  (or http://YOUR-SERVER-IP:8080)"
cat <<'EOF'
  systemctl list-timers mimir-update.timer       # next run
  journalctl -u mimir-update.service -f          # update logs
  docker compose --env-file .env --env-file .env.versions ps
EOF
