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
