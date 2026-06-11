# mimir-release

Central release & workspace repo for the Mimir platform. This repo holds what
the individual component repos shouldn't: the production deployment definition,
the pinned release manifest, shared CI workflows, and the developer workspace.

## Contents

- `mimir.code-workspace` — multi-root VS Code workspace for all Mimir repos
- `bootstrap.sh` — clones all component repos as siblings (one-command setup)
- `versions.yml` — pinned versions per release channel (the release manifest)
- `PLAN.md` — project review, deployment architecture, and roadmap
- `deploy/` — production deployment bundle:
  - `docker-compose.yml` — pinned GHCR images, no source checkout needed
  - `install_server.sh` — one-shot idempotent server setup
  - `mimir-update.sh` + `.service`/`.timer` — 15-minute self-update loop
  - `mosquitto/mosquitto.conf` — authenticated LAN listener + anon localhost

## Production server setup

```bash
sudo mkdir -p /opt/mimir && sudo chown $USER /opt/mimir
git clone https://github.com/ryanlane/mimir-release.git /opt/mimir/mimir-release
bash /opt/mimir/mimir-release/deploy/install_server.sh   # creates .env, exits
vi /opt/mimir/mimir-release/deploy/.env                  # set PUBLIC_HOST etc.
bash /opt/mimir/mimir-release/deploy/install_server.sh   # installs + starts
```

From then on the server converges to `versions.yml` every 15 minutes.

## New machine setup

```bash
mkdir -p ~/projects/mimir && cd ~/projects/mimir
git clone https://github.com/ryanlane/mimir-release.git
./mimir-release/bootstrap.sh
code mimir-release/mimir.code-workspace
```

## Component repos

| Folder | Repo | What |
|---|---|---|
| `mimir-server` | ryanlane/Mimir-Platform | FastAPI API + React UI + discovery + compose |
| `mimir-display` | ryanlane/mimir-display | Raspberry Pi display client (Inky / HyperPixel / HDMI / RGB matrix) |
| `mimir-display-electron` | ryanlane/mimir-display-electron | Electron display client |
| `mimir-display-magtag` | ryanlane/magtag-circuitpython-display-mimir | MagTag CircuitPython client |
| `mimir-channel-photoframe` | ryanlane/image-frame-channel-mimir | Photo frame channel plugin |
| `mimir-channel-spotify` | ryanlane/spotify-status | Spotify status channel plugin |
| `mimir-docs` | ryanlane/mimir-documentation | Platform documentation |

## Releasing (target state, Phase 1+)

1. Tag a component repo (`vX.Y.Z`) → its CI builds images/artifacts.
2. Open a PR here bumping `versions.yml`.
3. Merge → the production server's update timer converges within ~15 min,
   then rolls the matching display-client release out to the fleet over MQTT.

Rollback = revert the pin-bump PR.
