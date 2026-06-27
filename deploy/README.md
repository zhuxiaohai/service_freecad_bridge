# freecad-bridge Docker deployment

Build and run the **FreeCAD headless + Robust MCP Bridge** container image.
This repository builds only `freecad-bridge`; MCP server images are maintained
separately and connect to this bridge over XML-RPC on port `9875`.

## Architecture

```text
┌──────────── freecad-bridge container ────────────┐
│  FreeCAD headless + Robust MCP Bridge            │
│  XML-RPC :9875 (compose service name: freecad)   │
│  volume: assembly-data → /app/sessions           │
└──────────────────────────────────────────────────┘
         ▲
         │ XML-RPC (same Docker network or K8s service)
         │
   freecad-robust-mcp (external repo / image)
```

## Quick start

From the repository root:

```bash
cp deploy/.env.example deploy/.env
docker login hub.designorder.cn   # if pushing or pulling from corporate registry

just docker::compose-build
just docker::compose-up
docker compose -f deploy/docker-compose.yml ps
```

## Image workflow

| Step | Command |
| ---- | ------- |
| Build locally | `just docker::compose-build` |
| Run stack | `just docker::compose-up` |
| Build + push `:dev` | `just docker::publish-dev` |
| Push already-built image | `just docker::publish-push` |
| Release semver tag | `just docker::publish 1.0.0` |
| Smoke test (standalone) | `just docker::test` |

Show resolved settings:

```bash
just docker::publish-show
```

## Configuration (`deploy/.env`)

| Variable | Example | Description |
| -------- | ------- | ----------- |
| `FREECAD_BRIDGE_IMAGE` | `hub.designorder.cn/freecad-bridge:dev` | Image tag for build, run, and push |
| `DOCKER_REGISTRY` | `hub.designorder.cn/` | Prefix for base images (`ubuntu:24.04`) |
| `APT_MIRROR` | `http://mirrors.aliyun.com/ubuntu/` | Ubuntu apt mirror (HTTP; Jenkins blocks archive.ubuntu.com) |
| `FREECAD_TAG` | `1.1.1` | FreeCAD AppImage version at build time |
| `APPIMAGE_PARTS_PREFIX` | *(empty)* | Gitee Release URL prefix for split parts |
| `APPIMAGE_PART_COUNT` | *(empty)* | Number of split parts (from mirror script output) |
| `APPIMAGE_SHA256` | *(empty)* | SHA256 of the complete AppImage (required with parts) |
| `APPIMAGE_DOWNLOAD_TOKEN` | *(empty)* | Gitee token (only if repo is private) |
| `APPIMAGE_DOWNLOAD_TOKEN_TYPE` | `auto` | `auto`, `gitee`, `private`, or `deploy` |
| `GITEE_OWNER` | *(empty)* | Gitee username (for `mirror-appimage` upload) |
| `GITEE_ACCESS_TOKEN` | *(empty)* | Gitee private token (upload only, do not commit) |

## FreeCAD AppImage Gitee mirror (split parts)

Corporate Jenkins cannot download the ~782MB AppImage from GitHub quickly.
[Gitee Release attachments](https://gitee.com/help/articles/4328) allow up to
100MB per file, so the AppImage is split into 45MB parts, uploaded to your
**personal Gitee repo**, and reassembled during `docker build`.

### Step 1 — Create Gitee repo

1. Create repo: `freecad-appimage-mirror` (with README / initial commit)
2. **Recommended:** set visibility to **公开 (public)** — then Jenkins needs no download token
3. Create private token: [私人令牌](https://gitee.com/profile/personal_access_tokens) with **`projects`** scope (for upload)

### Step 2 — Configure deploy/.env

```bash
GITEE_OWNER=your-gitee-username
GITEE_ACCESS_TOKEN=<token-for-upload-only>
```

### Step 3 — Split and upload (one-time per FreeCAD version)

```bash
just docker::mirror-appimage
```

Prints values to paste into `deploy/.env`:

```bash
APPIMAGE_PARTS_PREFIX=https://gitee.com/yourname/freecad-appimage-mirror/releases/download/freecad-appimage-1.1.1/part_
APPIMAGE_PART_COUNT=18
APPIMAGE_SHA256=e2006138400b2fa85fa2e160e872d00767eb32964e85075830f7e198a3a876e1
# Private repo only:
APPIMAGE_DOWNLOAD_TOKEN=<gitee-token>
APPIMAGE_DOWNLOAD_TOKEN_TYPE=gitee
```

### Step 4 — Rebuild

```bash
just docker::compose-build
```

### GitLab mirror (optional)

Company GitLab is still supported: `MIRROR_TARGET=gitlab just docker::mirror-appimage`

## Corporate CI (Jenkins)

1. Push to GitLab `dev` branch
2. Trigger Jenkins build manually
3. Jenkins builds root `Dockerfile` and pushes `hub.designorder.cn/freecad-bridge:dev`
4. K8s pulls the new image

Local `just docker::compose-build` uses the same Dockerfile and build args.

## Standalone smoke test

Uses the image tag from `deploy/.env`:

```bash
just docker::test
```

Or manually:

```bash
set -a && source deploy/.env && set +a
docker run -d --name freecad-bridge-test -p 9875:9875 "${FREECAD_BRIDGE_IMAGE}"
# wait 30–90s, then:
curl -sf -X POST -H "Content-Type: text/xml" \
  -d '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' \
  http://localhost:9875
docker rm -f freecad-bridge-test
```

## Troubleshooting

**Container unhealthy on first start:** FreeCAD can take 30–90 seconds to initialize.
Check logs: `docker compose -f deploy/docker-compose.yml logs -f freecad`

**Rebuild after code changes:** `just docker::compose-build && just docker::compose-up`
