# Docker build and run commands for freecad-bridge image only.
#
# Image tag and registry settings live in deploy/.env:
#   just docker::compose-build | compose-up | publish-dev | publish-push
#
# See deploy/README.md for the full workflow.

deploy_compose := project_root + "/deploy/docker-compose.yml"
deploy_env := project_root + "/deploy/.env"
appimage_mirror_env := project_root + "/deploy/appimage-mirror.env"
compose_env_files := "--env-file " + appimage_mirror_env + " --env-file " + deploy_env
project_root := justfile_directory()
dockerfile := project_root + "/Dockerfile"
gui_test_image := "freecad-gui-test"

# Show image tags from deploy/.env
publish-show:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    if [ ! -f "$ENV_FILE" ]; then
        echo "ERROR: Missing ${ENV_FILE}"
        echo "  cp deploy/.env.example deploy/.env"
        exit 1
    fi
    echo "Bridge image settings (deploy/.env):"
    grep -E '^(FREECAD_BRIDGE_IMAGE|DOCKER_REGISTRY|APT_MIRROR|FREECAD_TAG|APPIMAGE_PARTS_PREFIX|APPIMAGE_PART_COUNT|APPIMAGE_SHA256)=' "$ENV_FILE" || true
    echo ""
    echo "AppImage mirror defaults (deploy/appimage-mirror.env — used when .env omits APPIMAGE_*):"
    grep -E '^(APPIMAGE_PARTS_PREFIX|APPIMAGE_PART_COUNT|APPIMAGE_SHA256)=' "{{appimage_mirror_env}}" || true
    echo ""
    echo "Resolved by docker compose config:"
    docker compose -f {{deploy_compose}} {{compose_env_files}} config --images
    echo ""
    echo "Workflow:"
    echo "  just docker::compose-build    # build bridge image"
    echo "  just docker::compose-up       # run via compose"
    echo "  just docker::publish-dev      # build + push :dev"
    echo "  just docker::publish 1.0.0    # build + push semver tag"
    echo "  just docker::test             # standalone XML-RPC smoke test"

# Build bridge image (tag from deploy/.env)
compose-build:
    docker compose -f {{deploy_compose}} {{compose_env_files}} build freecad

# Alias for compose-build
compose-build-bridge: compose-build

# Start bridge container without rebuilding
compose-up:
    docker compose -f {{deploy_compose}} {{compose_env_files}} up -d --no-build

# Stop bridge container
compose-down:
    docker compose -f {{deploy_compose}} {{compose_env_files}} down

# Direct docker build using tag from deploy/.env
build:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    if [ ! -f "$ENV_FILE" ]; then
        echo "ERROR: Missing ${ENV_FILE}"; exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "{{appimage_mirror_env}}"
    source "$ENV_FILE"
    set +a
    docker build \
        --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY:-hub.designorder.cn/}" \
        --build-arg "APT_MIRROR=${APT_MIRROR:-http://mirrors.aliyun.com/ubuntu/}" \
        --build-arg "FREECAD_TAG=${FREECAD_TAG:-1.1.1}" \
        --build-arg "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}" \
        --build-arg "APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}" \
        --build-arg "APPIMAGE_URL=${APPIMAGE_URL:-}" \
        --build-arg "APPIMAGE_SHA256=${APPIMAGE_SHA256}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN=${APPIMAGE_DOWNLOAD_TOKEN:-}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN_TYPE=${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
        -t "${FREECAD_BRIDGE_IMAGE:?Set FREECAD_BRIDGE_IMAGE in deploy/.env}" \
        -f {{dockerfile}} \
        {{project_root}}

# Build with explicit tag override
build-tag tag:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "{{appimage_mirror_env}}"
    source "$ENV_FILE"
    set +a
    BASE="${FREECAD_BRIDGE_IMAGE%%:*}"
    docker build \
        --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY:-hub.designorder.cn/}" \
        --build-arg "APT_MIRROR=${APT_MIRROR:-http://mirrors.aliyun.com/ubuntu/}" \
        --build-arg "FREECAD_TAG=${FREECAD_TAG:-1.1.1}" \
        --build-arg "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}" \
        --build-arg "APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}" \
        --build-arg "APPIMAGE_URL=${APPIMAGE_URL:-}" \
        --build-arg "APPIMAGE_SHA256=${APPIMAGE_SHA256}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN=${APPIMAGE_DOWNLOAD_TOKEN:-}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN_TYPE=${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
        -t "${BASE}:{{tag}}" \
        -f {{dockerfile}} \
        {{project_root}}

# Push bridge image (must already be built)
publish-push:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --format json \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['services']['freecad']['image'])")
    echo "Pushing ${IMAGE} ..."
    docker push "${IMAGE}"
    echo "✓ Pushed ${IMAGE}"

# Alias
publish-push-bridge: publish-push

# Build + push :dev tag from deploy/.env
publish-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building freecad-bridge (tag from deploy/.env) ..."
    echo "Note: first build can take a long time (FreeCAD AppImage download)."
    just docker::compose-build
    just docker::publish-push

# Alias
publish-dev-bridge: publish-dev

# Build + push immutable semver tag
publish version:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    VERSION="{{version}}"
    BRIDGE_BASE=$(grep '^FREECAD_BRIDGE_IMAGE=' "$ENV_FILE" | cut -d= -f2 | sed 's/:[^:]*$//')
    export FREECAD_BRIDGE_IMAGE="${BRIDGE_BASE}:${VERSION}"
    echo "Release build: ${FREECAD_BRIDGE_IMAGE}"
    docker compose -f {{deploy_compose}} {{compose_env_files}} build freecad
    docker push "${FREECAD_BRIDGE_IMAGE}"
    echo "✓ Pushed ${FREECAD_BRIDGE_IMAGE}"

# Remove legacy local-only tags
clean-legacy-tags:
    #!/usr/bin/env bash
    set -euo pipefail
    for img in "freecad-bridge:latest" "zhuxiaohai/freecad-bridge:dev"; do
        if docker image inspect "$img" > /dev/null 2>&1; then
            echo "Removing legacy tag: $img"
            docker rmi "$img" || true
        fi
    done
    echo "Done."

# Validate multi-arch build (dry-run, no load)
build-multi: setup-buildx
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "{{appimage_mirror_env}}"
    source "$ENV_FILE"
    set +a
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY:-hub.designorder.cn/}" \
        --build-arg "APT_MIRROR=${APT_MIRROR:-http://mirrors.aliyun.com/ubuntu/}" \
        --build-arg "FREECAD_TAG=${FREECAD_TAG:-1.1.1}" \
        --build-arg "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}" \
        --build-arg "APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}" \
        --build-arg "APPIMAGE_URL=${APPIMAGE_URL:-}" \
        --build-arg "APPIMAGE_SHA256=${APPIMAGE_SHA256}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN=${APPIMAGE_DOWNLOAD_TOKEN:-}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN_TYPE=${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
        -t "${FREECAD_BRIDGE_IMAGE}" \
        -f {{dockerfile}} \
        {{project_root}}

# Build and push multi-arch image
build-push tag="dev": setup-buildx
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "{{appimage_mirror_env}}"
    source "$ENV_FILE"
    set +a
    BASE="${FREECAD_BRIDGE_IMAGE%%:*}"
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY:-hub.designorder.cn/}" \
        --build-arg "APT_MIRROR=${APT_MIRROR:-http://mirrors.aliyun.com/ubuntu/}" \
        --build-arg "FREECAD_TAG=${FREECAD_TAG:-1.1.1}" \
        --build-arg "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}" \
        --build-arg "APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}" \
        --build-arg "APPIMAGE_URL=${APPIMAGE_URL:-}" \
        --build-arg "APPIMAGE_SHA256=${APPIMAGE_SHA256}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN=${APPIMAGE_DOWNLOAD_TOKEN:-}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN_TYPE=${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
        -t "${BASE}:{{tag}}" \
        --push \
        -f {{dockerfile}} \
        {{project_root}}

# Build and load for current architecture
build-load: setup-buildx
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "{{appimage_mirror_env}}"
    source "$ENV_FILE"
    set +a
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  PLATFORM="linux/amd64" ;;
        aarch64|arm64) PLATFORM="linux/arm64" ;;
        *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    docker buildx build --platform "$PLATFORM" \
        --build-arg "DOCKER_REGISTRY=${DOCKER_REGISTRY:-hub.designorder.cn/}" \
        --build-arg "APT_MIRROR=${APT_MIRROR:-http://mirrors.aliyun.com/ubuntu/}" \
        --build-arg "FREECAD_TAG=${FREECAD_TAG:-1.1.1}" \
        --build-arg "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}" \
        --build-arg "APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}" \
        --build-arg "APPIMAGE_URL=${APPIMAGE_URL:-}" \
        --build-arg "APPIMAGE_SHA256=${APPIMAGE_SHA256}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN=${APPIMAGE_DOWNLOAD_TOKEN:-}" \
        --build-arg "APPIMAGE_DOWNLOAD_TOKEN_TYPE=${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
        -t "${FREECAD_BRIDGE_IMAGE}" \
        --load \
        -f {{dockerfile}} \
        {{project_root}}

# Show image size and layers
inspect:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --images | head -1)
    docker images "$IMAGE"
    echo ""
    docker history "$IMAGE"

# Remove local bridge image from deploy/.env
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --images 2>/dev/null | head -1 || true)
    if [ -n "$IMAGE" ]; then
        docker rmi "$IMAGE" 2>/dev/null || true
    fi

clean-all: clean
    docker builder prune -f
    @echo "Docker images and build cache cleaned."

# Scan bridge image for vulnerabilities
scan:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --images | head -1)
    IGNOREFILE="{{project_root}}/.trivyignore"
    IGNORE_FLAG=""
    if [ -f "$IGNOREFILE" ]; then
        IGNORE_FLAG="--ignorefile $IGNOREFILE"
    fi
    trivy image --severity HIGH,CRITICAL $IGNORE_FLAG "$IMAGE"
    trivy image --severity MEDIUM,LOW $IGNORE_FLAG "$IMAGE" || true

scan-strict:
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --images | head -1)
    IGNOREFILE="{{project_root}}/.trivyignore"
    IGNORE_FLAG=""
    if [ -f "$IGNOREFILE" ]; then
        IGNORE_FLAG="--ignorefile $IGNOREFILE"
    fi
    trivy image --severity HIGH,CRITICAL --exit-code 1 $IGNORE_FLAG "$IMAGE"

scan-sarif output="trivy-results.sarif":
    #!/usr/bin/env bash
    set -euo pipefail
    IMAGE=$(docker compose -f {{deploy_compose}} {{compose_env_files}} config --images | head -1)
    IGNOREFILE="{{project_root}}/.trivyignore"
    IGNORE_FLAG=""
    if [ -f "$IGNOREFILE" ]; then
        IGNORE_FLAG="--ignorefile $IGNOREFILE"
    fi
    trivy image --format sarif --output {{project_root}}/{{output}} $IGNORE_FLAG "$IMAGE"

setup-buildx:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! docker buildx inspect freecad-builder > /dev/null 2>&1; then
        docker buildx create --name freecad-builder --use --bootstrap
    else
        docker buildx use freecad-builder
    fi
    docker buildx inspect --bootstrap

# Standalone bridge smoke test: build/run container and ping XML-RPC
test:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    CONTAINER="freecad-bridge-test-$$"
    cleanup() { docker rm -f "$CONTAINER" 2>/dev/null || true; }
    trap cleanup EXIT INT TERM

    echo "Building ${FREECAD_BRIDGE_IMAGE} ..."
    just docker::build

    echo "Starting container (XML-RPC on host :9875) ..."
    docker run -d --name "$CONTAINER" -p 9875:9875 "${FREECAD_BRIDGE_IMAGE}"

    echo "Waiting for bridge (up to 120s) ..."
    for i in $(seq 1 120); do
        if curl -sf -X POST -H "Content-Type: text/xml" \
            -d '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' \
            --max-time 5 http://localhost:9875 > /dev/null 2>&1; then
            echo "✓ Bridge responded after ${i}s"
            exit 0
        fi
        sleep 1
    done
    echo "✗ Bridge did not respond within 120s"
    docker logs "$CONTAINER" | tail -30
    exit 1

# GUI test container (CI debugging)
build-gui-test:
    docker build -f {{project_root}}/tests/ci-test/Dockerfile.gui-test \
        -t {{gui_test_image}} \
        {{project_root}}

gui-test-shell:
    docker run --rm -it \
        -v {{project_root}}:/workspace \
        {{gui_test_image}} \
        /bin/bash

gui-test-run:
    docker run --rm -i \
        -v {{project_root}}:/workspace \
        {{gui_test_image}} \
        /usr/local/bin/run-gui-test.sh

gui-test-cmd *args:
    docker run --rm -it \
        -v {{project_root}}:/workspace \
        {{gui_test_image}} \
        {{args}}

gui-test: build-gui-test gui-test-run

# Create Gitee mirror repo (one-time): freecad-appimage-mirror
create-gitee-repo:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    bash "{{project_root}}/deploy/scripts/create-gitee-mirror-repo.sh"

# Split AppImage into <100MB parts and upload to Gitee Release (one-time setup).
mirror-appimage:
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="{{deploy_env}}"
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    export GITEE_OWNER="${GITEE_OWNER:-}"
    export GITEE_REPO="${GITEE_REPO:-freecad-appimage-mirror}"
    export GITEE_ACCESS_TOKEN="${GITEE_ACCESS_TOKEN:-}"
    export MIRROR_TARGET="${MIRROR_TARGET:-gitee}"
    bash "{{project_root}}/deploy/scripts/mirror-freecad-appimage.sh"
