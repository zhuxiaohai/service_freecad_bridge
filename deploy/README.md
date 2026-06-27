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
| `APPIMAGE_*` | *(see `deploy/appimage-mirror.env`)* | Optional overrides; Jenkins uses Dockerfile defaults |

## Jenkins zero-config (corporate CI)

Unlike the MCP server repo, this image **downloads FreeCAD (~783MB)** at build
time. MCP needs no extra config because it only builds Python on Alpine.

**Jenkins needs no `deploy/.env` and no build-arg secrets** for the default setup:

| Setting | Default (in Dockerfile) |
| ------- | ----------------------- |
| Base images | `hub.designorder.cn/` |
| apt mirror | Aliyun HTTP |
| AppImage | Public Gitee split mirror ([xiaohaizhu/freecad-appimage-mirror](https://gitee.com/xiaohaizhu/freecad-appimage-mirror)) |

Jenkins runs `docker build -f Dockerfile .` on the repo — same as MCP.

**Why not GitLab zero-config?** GitLab Generic Packages require authentication
(401 without token). Gitee Release is public, so no download token.

**Optional faster mirror:** add to local `deploy/.env` only (GitLab + token).

## FreeCAD AppImage mirror (split parts)

Corporate Jenkins cannot download the ~782MB AppImage from GitHub quickly.
The default mirror is **public Gitee** (18 × 45MB parts). Values live in
`deploy/appimage-mirror.env` and Dockerfile `ARG` defaults.

### Upload new FreeCAD version (one-time)

```bash
GITEE_OWNER=your-gitee-username
GITEE_ACCESS_TOKEN=<token>
just docker::mirror-appimage
# Then update deploy/appimage-mirror.env + Dockerfile ARG defaults with new SHA/count
```

### GitLab mirror (optional, local override)

```bash
MIRROR_TARGET=gitlab just docker::mirror-appimage
# Add APPIMAGE_* overrides to deploy/.env (requires download token)
```

## Corporate CI (Jenkins)

1. Push to company GitLab `develop` branch
2. Trigger Jenkins build manually (no `deploy/.env`, no extra build-args)
3. Jenkins builds root `Dockerfile` → pushes `hub.designorder.cn/freecad-bridge:dev`
4. K8s pulls the new image

Local `just docker::compose-build` uses the same Dockerfile defaults via
`deploy/appimage-mirror.env` + optional `deploy/.env` overrides.

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
