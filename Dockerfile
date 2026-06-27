# FreeCAD Robust MCP Bridge Dockerfile
# Runs FreeCAD headless with the Robust MCP Bridge, exposing XML-RPC on :9875
#
# Corporate / K8s CI builds from this file at the repository root.
#
# Local workflow:
#   cp deploy/.env.example deploy/.env
#   just docker::compose-build
#   just docker::compose-up

# Prefix for base images (empty = Docker Hub). Corporate CI uses hub.designorder.cn/.
ARG DOCKER_REGISTRY=hub.designorder.cn/
# Ubuntu apt mirror for corporate networks that block archive.ubuntu.com.
# Use HTTP (not HTTPS): ca-certificates is not installed until apt-get runs.
# HTTPS mirrors fail TLS verification on a fresh ubuntu:24.04 layer.
# Override at build time: --build-arg APT_MIRROR= (empty = upstream defaults)
ARG APT_MIRROR=http://mirrors.aliyun.com/ubuntu/
FROM ${DOCKER_REGISTRY}ubuntu:24.04

ARG APT_MIRROR

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# FreeCAD version to install (must match Python 3.11 requirement; see CLAUDE.md)
ARG FREECAD_TAG=1.1.1
ENV FREECAD_TAG=${FREECAD_TAG}

# Split AppImage mirror (public Gitee — Jenkins zero-config, no token required).
# Override for GitLab/faster mirror: --build-arg APPIMAGE_PARTS_PREFIX=... (+ token).
# See deploy/appimage-mirror.env and deploy/scripts/mirror-freecad-appimage.sh.
ARG APPIMAGE_PARTS_PREFIX=https://gitee.com/xiaohaizhu/freecad-appimage-mirror/releases/download/freecad-appimage-1.1.1/part_
ENV APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}

ARG APPIMAGE_PART_COUNT=18
ENV APPIMAGE_PART_COUNT=${APPIMAGE_PART_COUNT}

# Optional single-file mirror URL (empty = GitHub, unless parts prefix is set).
ARG APPIMAGE_URL=
ENV APPIMAGE_URL=${APPIMAGE_URL}

# SHA256 of the complete AppImage (required when using APPIMAGE_PARTS_PREFIX).
ARG APPIMAGE_SHA256=e2006138400b2fa85fa2e160e872d00767eb32964e85075830f7e198a3a876e1
ENV APPIMAGE_SHA256=${APPIMAGE_SHA256}

# Deploy Token for mirror downloads (build-time only, not in runtime ENV).
ARG APPIMAGE_DOWNLOAD_TOKEN=
ARG APPIMAGE_DOWNLOAD_TOKEN_TYPE=auto

# AppImage installation directory (setup-freecad.sh respects this variable)
ENV APPIMAGE_DIR=/opt/freecad-appimage

# Install minimal runtime dependencies:
#   ca-certificates, curl  - AppImage download and verification
#   libgl1                 - OpenGL (required by FreeCAD even in headless mode)
#   libglib2.0-0           - GLib (required by Qt/FreeCAD)
#   fontconfig             - Font configuration subsystem (referenced by FreeCAD)
#   fonts-dejavu-core      - Basic fonts required by FreeCAD document rendering
# hadolint ignore=DL3008
RUN if [ -n "${APT_MIRROR}" ]; then \
      APT_MIRROR="${APT_MIRROR#https://}"; \
      APT_MIRROR="http://${APT_MIRROR#http://}"; \
      sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu/|${APT_MIRROR}|g" \
        -e "s|http://security.ubuntu.com/ubuntu/|${APT_MIRROR}|g" \
        /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || \
      sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu/|${APT_MIRROR}|g" \
        -e "s|http://security.ubuntu.com/ubuntu/|${APT_MIRROR}|g" \
        /etc/apt/sources.list; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fontconfig \
    fonts-dejavu-core \
    libglib2.0-0 \
    libgl1 \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -f

# Copy FreeCAD AppImage setup script (reused from CI infrastructure).
# The script downloads the AppImage, extracts it to avoid FUSE dependency,
# and installs freecadcmd/freecad wrapper scripts to /usr/local/bin/.
COPY tests/ci-test/setup-freecad.sh /usr/local/bin/setup-freecad.sh
RUN chmod +x /usr/local/bin/setup-freecad.sh

# Download, extract, and install FreeCAD AppImage.
# Runs as root inside Docker so the script installs wrappers without sudo.
# CI environment variables are NOT propagated into docker build, so APPIMAGE_SHA256
# is not required here (the script's CI check only triggers when CI=true is set).
# hadolint ignore=DL3001,DL3059
RUN APPIMAGE_DOWNLOAD_TOKEN="${APPIMAGE_DOWNLOAD_TOKEN}" \
    APPIMAGE_DOWNLOAD_TOKEN_TYPE="${APPIMAGE_DOWNLOAD_TOKEN_TYPE:-auto}" \
    /usr/local/bin/setup-freecad.sh

# Copy the Robust MCP Bridge addon.
# blocking_bridge.py adds its own directory to sys.path, so no package install needed.
COPY freecad/RobustMCPBridge/ /opt/RobustMCPBridge/

# Default bridge configuration (can be overridden at runtime via environment variables)
# FREECAD_BRIDGE_BIND_HOST=0.0.0.0 allows connections from other containers on the Docker
# bridge network. In local (non-Docker) use this defaults to localhost in blocking_bridge.py.
ENV FREECAD_XMLRPC_PORT=9875 \
    FREECAD_SOCKET_PORT=9876 \
    FREECAD_BRIDGE_BIND_HOST=0.0.0.0

# Expose XML-RPC port for MCP Server to connect
EXPOSE 9875

# Health check - verify the XML-RPC bridge is accepting connections.
# FreeCAD takes 30-60 seconds to initialise, so start_period is set accordingly.
# Sends a system.listMethods XML-RPC call and expects a 200 response.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
    CMD curl -sf -X POST -H "Content-Type: text/xml" -d '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName></methodCall>' --max-time 5 "http://localhost:${FREECAD_XMLRPC_PORT:-9875}" > /dev/null || exit 1

# Run FreeCAD headless with the blocking bridge.
# blocking_bridge.py blocks indefinitely (run_forever), maintaining the XML-RPC server.
# Note: GUI features (screenshots, visibility, colours) are not available in headless mode.
CMD ["freecadcmd", "/opt/RobustMCPBridge/freecad_mcp_bridge/blocking_bridge.py"]
