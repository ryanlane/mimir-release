# Mimir Platform — Review & Deployment Plan

**Date:** 2026-06-10
**Scope:** Full project review + a deployment/update architecture for one Ubuntu server and 10–50 headless display clients.

---

## 1. Current state (summary)

- **Server stack** (`mimir-server/`, formerly `service/`): FastAPI API, React UI, Postgres, Redis, Mosquitto in Docker Compose. API and MQTT run with `network_mode: host` so LAN hardware and mDNS work. Discovery runs natively on the Ubuntu host (or via the `discovery` compose profile).
- **Clients**: `mimir-display` (Python, systemd, multi-backend: Inky / HyperPixel / HDMI / RGB matrix), plus `mimir-display-electron` and `mimir-display-magtag`.
- **Deploys today:** server = `task up:build` on the box; clients = `task display:deploy -- pi@host` (rsync + `update_display.sh` + systemd restart), one device at a time, driven manually from the dev machine.
- **No CI** anywhere (no `.github/workflows`). No image registry. No client version reporting, no OTA path, no coordinated server+client rollout.

The hybrid model (containers for app services, host network/native process for mDNS) is the right call — keep it. The gap is purely in build/release/update automation.

---

## 2. Key items to address

### A. Deployment & updates (the main ask — design in §3)
1. No release pipeline: everything builds on the server or rsyncs from the dev machine.
2. Client updates are manual, per-device, and must be remembered whenever the server changes — exactly the pain you described.
3. No version visibility: the server can't tell which client version a display runs (`update_display.sh` writes `.deploy-version` locally but nothing reports it).
4. No rollback story on clients: rsync overwrites in place; a bad deploy means SSHing into each frame.

### B. Security defaults (quick wins, do first)
5. Mosquitto: `allow_anonymous true` on `0.0.0.0:1883` with host networking — anyone on the LAN can publish display commands. Enable the password auth already documented in `mosquitto/mosquitto.conf`.
6. Postgres `mimir/mimir` published on `5432`, pgAdmin `admin/admin` on `5050`. Bind both to `127.0.0.1` in compose and change credentials.
7. Redis published on `6379` with no auth — bind to `127.0.0.1` (the API uses host networking, so localhost binding still works).

### C. Repo hygiene
8. ~~Stray Windows `.venv/` in the server repo~~ — removed during the 2026-06-10 reorg (it was untracked local junk; `.gitignore` already covered it).
9. `mimir-api/deploy/` describes an obsolete deployment (SQLite, `requirements.txt`, root-level `alembic/`, "95% test coverage") that contradicts the Docker/Postgres path — removed during the reorg; one canonical deploy doc remains the goal.
10. Docs drift: `mimir-docs/` (last updated Aug 2025, v2.4) references separate GitHub repos that don't match the current layout. Overlapping deployment docs (`README.md`, `HYBRID_LINUX_DEPLOYMENT.md`) should collapse into one.
11. ~~`mimir-web/mimir-ui/src/_archived/`~~ — removed during the reorg; git history keeps it.

### D. Code structure (mimir-api)
12. Parallel/duplicated layers: `app/services/` vs `app/core/services/` vs `app/infrastructure/` (e.g. `app/services/websocket_manager.py` and `app/infrastructure/websocket/manager.py`; `app/db/models.py` and `app/infrastructure/database/models.py`). Pick one layout and consolidate — this will bite every future refactor.
13. Test coverage is thin (6 test files against a large service surface). Grow tests alongside the consolidation, and gate releases on them once CI exists (§3.1).

### E. Fleet operations (matters at 10–50 displays)
14. No per-device health/version dashboard. MQTT presence exists; extend it with client version, update status, and last-seen, surfaced in the web UI.
15. No staged rollout: at this fleet size you want canary-first updates, not all-at-once.

---

## 3. Deployment & auto-update architecture

**Principle:** a pinned release manifest is the single source of truth for the server *and* the desired client version. Bumping the manifest updates the server, which then makes the matching client release available and triggers the client rollout. One PR updates everything.

```
Component repos (tag vX.Y.Z, own CI)
   ├── multi-arch images ──► GHCR  (api, web, discovery)
   └── client artifact   ──► GitHub Release (mimir-display-vX.Y.Z.tar.gz + manifest)

mimir-release repo
   └── versions.yml pins the tested set  ◄── release = pin-bump PR

Linux server (amd64 or arm64)
   ├── systemd timer: pull mimir-release → compose pull + up -d   ← server self-update
   ├── API caches the pinned client artifact locally              ← LAN-served, no internet needed on Pis
   └── publishes retained MQTT: mimir/fleet/desired_version

Displays (10–50)
   └── update agent: sees desired_version ≠ installed
       → download from server → install to releases/vX.Y.Z (A/B)
       → health check → flip symlink → restart → report status
       → on failure: keep old version, report error
```

### 3.1 CI (GitHub Actions) — multi-repo layout

Each component repo keeps its own dev cycle and CI; a small central **`mimir-release`** repo ties releases together:

- **Component repos** (`mimir-server` — api + web + discovery in one repo, see §6 — plus `mimir-display` and the channel plugin repos): on PR run lint + tests; on tag `vX.Y.Z` build their own artifacts — `mimir-server` builds all three multi-arch (`linux/amd64` + `linux/arm64`) images to GHCR under one tag; `mimir-display` builds sdist/tarball + `manifest.json` (version, min server version, sha256) as a GitHub Release asset. Shared workflow logic lives in the central repo as [reusable workflows](https://docs.github.com/actions/using-workflows/reusing-workflows) so each repo's CI file is ~10 lines.
- **`mimir-release` repo** holds the production `docker-compose.yml`, the update timer/units, bootstrap script, and a `versions.yml` manifest pinning exact tags per channel, e.g.:

  ```yaml
  stable:
    server: v1.4.0          # one tag → api, web, discovery images
    display-client: v2.0.3
  ```

- **Cutting a release** = PR bumping pins in `versions.yml`. Components version independently; the manifest defines what's been tested *together*. A CI job on this repo can run an integration smoke test against the pinned set before merge.

### 3.2 Server self-update (GitOps-style)
- Switch the production `docker-compose.yml` (now living in `mimir-release`) from `build:` to `image: ghcr.io/...:<pinned tag>` (keep `docker-compose.dev.yml` build paths in component repos for development).
- Move discovery into compose with `network_mode: host` (the `discovery` profile already exists) so the whole server updates atomically. Host-network containers do mDNS fine on native Linux.
- Add a `mimir-update.timer` systemd unit (e.g. every 15 min): `git pull` the `mimir-release` repo → render image tags from `versions.yml` → `docker compose pull && docker compose up -d`. Migrations already run on API startup, so DB upgrades are automatic.
- Releasing = merge a pin-bump PR in `mimir-release`. The server converges within the timer interval; rollback = revert the PR.
- Alternative if you want a UI/notifications instead of a timer: *What's Up Docker* or the maintained Watchtower fork (`nickfedor/watchtower`) — original Watchtower was archived Dec 2025. The timer + manifest is fewer moving parts and gives exact-version control; start there.

**Platform support:** images built for `amd64` + `arm64` cover any 64-bit Linux box — x86 mini-PC, NUC, Pi 4/5, etc. The hard requirement is *native Linux* for host networking and mDNS; Docker Desktop on macOS/Windows can't do host networking, so those remain dev-only environments (the existing WSL compose path).

### 3.3 Client OTA
- **Version reporting (first step, small):** include client version + protocol version in MQTT registration/presence; show per-display in the web UI. Immediately tells you what's deployed where.
- **Release cache on the server:** API endpoint (e.g. `/api/client-releases/latest` + artifact download) serving the client release bundled/cached at server release time. Displays never need internet, and server+client versions ship as a pair.
- **Update agent on the Pi** (extend `update_display.sh` logic into a small systemd-run agent or an MQTT command handler in the client — the command pattern already exists in `network/mqtt/commands_display.py`):
  - Trigger: retained `mimir/fleet/desired_version` topic (instant) + daily systemd timer poll (fallback for displays that were offline).
  - Install: download → verify sha256 → install into `/opt/mimir-display/releases/vX.Y.Z/` with its own venv → run `--health` → atomically flip a `current` symlink → restart service.
  - Rollback: health check fails → keep old symlink, report `update_failed` with logs via MQTT.
- **Staged rollout:** server publishes desired version to a `canary` device group first; auto-promote to the rest after the canaries report healthy for N minutes. At 10–50 devices this is cheap insurance.
- Keep `task display:deploy -- pi@host` as a dev-loop tool for iterating on one device; OTA is the production path.

### 3.4 Compatibility
- `protocol_version` in the MQTT registration payload; server refuses/flags clients below its minimum and the UI shows "update pending".
- The `versions.yml` manifest is the compatibility contract: the pinned `display-client` version is the one the server caches and rolls out, so drift only happens while a rollout is in flight.
- **Scope:** OTA targets the Raspberry Pi `mimir-display` client only. Electron and MagTag clients stay manual for now (MagTag/CircuitPython would need a different mechanism anyway); the desired-version topic can carry a per-client-type field later without redesign.

### Why not Mender/balena?
Full fleet platforms add device-agent infrastructure, image-based OS updates, and (for balena) cloud dependency. For one LAN server and ≤50 Python-app clients, MQTT + A/B symlink installs gets you 90% of the value with parts you already run. Revisit if you ever manage remote sites.

---

## 4. Phased roadmap

| Phase | Work | Outcome |
|-------|------|---------|
| **0 — Quick wins** (hours) | Items 5–7: MQTT auth, localhost-bind DB/Redis/pgAdmin, rotate creds *(items 8, 9, 11 done in reorg)* | Safe LAN defaults, cleaner repo |
| **1 — CI + server auto-update** (1–2 days) | §3.1 + §3.2: per-repo Actions + `mimir-release` repo, GHCR multi-arch images, compose on pinned tags, update timer, discovery into compose | pin-bump PR → server updates itself |
| **2 — Client versioning** (1 day) | Version in presence, fleet panel in UI, server-side release cache endpoint | Know what's deployed where |
| **3 — Client OTA** (2–4 days) | Update agent, A/B install + rollback, desired-version topic, canary group | One tag updates server **and** all displays |
| **4 — Consolidation** (ongoing) | Items 10, 12–13: docs collapse, api layer consolidation, test growth gated in CI | Sustainable codebase |

Phases 0–2 are independent of each other and each immediately useful; 3 depends on 1–2.

---

## 5. Decisions (resolved 2026-06-10)

1. **Multi-repo, not monorepo.** Each component keeps its own repo and dev cycle. A central `mimir-release` repo carries reusable CI workflows, the production compose file, and the pinned `versions.yml` manifest (§3.1). Releases are manifest bumps, not cross-repo tag coordination.
2. **Pi clients only** for OTA. Electron and MagTag are future features (§3.4).
3. **Run anywhere reasonable:** multi-arch (`amd64` + `arm64`) images so any 64-bit native-Linux host works, including a Pi as the server. macOS/Windows Docker stay dev-only due to the host-networking/mDNS requirement (§3.2).
4. **Server stays one repo** (renamed `mimir-server`): api, web, and discovery deploy and version together; clients and plugins are where independent dev cycles matter.
5. **Workspace = flat sibling repos** under `~/projects/mimir/`, fixed in place rather than started fresh (§6).

---

## 6. Workspace & repo reorganization — **executed 2026-06-10**

### Before

The top-level `~/projects/mimir/` folder was not a git repo — a loose wrapper around seven independent repos at inconsistent depths: `service/` (one repo: api + web + discovery), `clients/` and `plugins/` holding five more repos, `mimir-documentation/`, a trivial root `.code-workspace`, and a stale workspace file inside the docs repo referencing folders that no longer existed.

**Verdict: fix in place.** The repos and their history are the valuable part and they're healthy; the mess was the wrapper, stale workspace files, and junk inside `service`. A fresh folder would have meant moving these same repos anyway.

### After (flat siblings, consistent names)

```
mimir/
├── mimir-release/              (NEW repo: this file, versions.yml, workspace file,
│                                bootstrap.sh; later: compose, CI workflows, timer units)
├── mimir-server/               (renamed from service/ — GitHub: ryanlane/Mimir-Platform)
├── mimir-display/
├── mimir-display-electron/
├── mimir-display-magtag/       (renamed from magtag-circuitpython-display-mimir)
├── mimir-channel-photoframe/   (renamed from image-frame-channel-mimir)
├── mimir-channel-spotify/      (renamed from spotify-status)
└── mimir-docs/                 (renamed from mimir-documentation)
```

Open the workspace via `code mimir-release/mimir.code-workspace`. New machine setup = clone `mimir-release`, run `bootstrap.sh`.

### What the reorg changed

1. Deleted stray Windows `.venv/` in the server repo (untracked), `mimir-web/mimir-ui/src/_archived/`, legacy `mimir-api/deploy/`, and the stale `mimir-platform.code-workspace` in the docs repo (committed per repo).
2. Created `mimir-release` with workspace file, `bootstrap.sh`, `versions.yml`, this plan.
3. Flattened and renamed folders as above (git is location-independent; remotes unchanged).
4. Fixed the only two cross-repo path references: `docker-compose.dev.yml` plugin mounts and the `display:deploy` rsync path in `Taskfile.yml`.

### Optional follow-ups

- Rename GitHub repos to match local names (`Mimir-Platform` → `mimir-server`, etc.). Old URLs redirect; update `bootstrap.sh` URLs after renaming.
- Create the `mimir-release` repo on GitHub and push.
