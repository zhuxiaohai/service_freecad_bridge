#!/usr/bin/env bash
# Download FreeCAD AppImage from GitHub, split into <100MB parts, upload to a mirror.
#
# Default mirror: Gitee Release attachments (personal repo, not company GitLab).
# Optional: MIRROR_TARGET=gitlab for GitLab Generic Packages.
#
# Usage:
#   just docker::mirror-appimage
#   GITEE_OWNER=yourname GITEE_ACCESS_TOKEN=xxx ./deploy/scripts/mirror-freecad-appimage.sh

set -euo pipefail

MIRROR_TARGET="${MIRROR_TARGET:-gitee}"
FREECAD_TAG="${FREECAD_TAG:-1.1.1}"
PART_SIZE="${APPIMAGE_PART_SIZE:-45M}"
ARCH_SUFFIX="${ARCH_SUFFIX:-x86_64}"
WORKDIR="${TMPDIR:-/tmp}/freecad-appimage-mirror-${FREECAD_TAG}"
PART_PREFIX="part_"
RELEASE_TAG="freecad-appimage-${FREECAD_TAG}"

# Gitee settings (default mirror)
GITEE_OWNER="${GITEE_OWNER:-}"
GITEE_REPO="${GITEE_REPO:-freecad-appimage-mirror}"
GITEE_ACCESS_TOKEN="${GITEE_ACCESS_TOKEN:-}"

# GitLab settings (optional fallback)
GITLAB_HOST="${GITLAB_HOST:-git.designorder.cn}"
GITLAB_PROJECT_ID="${GITLAB_PROJECT_ID:-1031}"
PACKAGE_NAME="${APPIMAGE_PACKAGE_NAME:-freecad-appimage}"

if [[ "$FREECAD_TAG" == 1.0.* ]]; then
    APPIMAGE_NAME="FreeCAD_${FREECAD_TAG}-conda-Linux-${ARCH_SUFFIX}-py311.AppImage"
else
    APPIMAGE_NAME="FreeCAD_${FREECAD_TAG}-Linux-${ARCH_SUFFIX}-py311.AppImage"
fi

GITHUB_URL="https://github.com/FreeCAD/FreeCAD/releases/download/${FREECAD_TAG}/${APPIMAGE_NAME}"
APPIMAGE_PATH="${WORKDIR}/${APPIMAGE_NAME}"

gitee_api() {
    local method="$1"
    local path="$2"
    shift 2
    curl -sS -X "$method" "https://gitee.com/api/v5${path}" \
        --get \
        --data-urlencode "access_token=${GITEE_ACCESS_TOKEN}" \
        "$@"
}

gitee_api_post_multipart() {
    local path="$1"
    local part_file="$2"
    curl -sS -X POST "https://gitee.com/api/v5${path}" \
        -F "access_token=${GITEE_ACCESS_TOKEN}" \
        -F "file=@${part_file}"
}

get_or_create_gitee_release_id() {
    local release_json release_id
    release_json=$(curl -sS \
        "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/tags/${RELEASE_TAG}?access_token=${GITEE_ACCESS_TOKEN}" || true)
    release_id=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" <<< "$release_json" 2>/dev/null || true)

    if [[ -n "$release_id" ]] && [[ "$release_id" != "None" ]]; then
        echo "$release_id"
        return
    fi

    echo "Creating Gitee release ${RELEASE_TAG} ..." >&2
    release_json=$(curl -sS -X POST "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/releases" \
        -d "access_token=${GITEE_ACCESS_TOKEN}" \
        -d "tag_name=${RELEASE_TAG}" \
        -d "name=FreeCAD AppImage ${FREECAD_TAG}" \
        -d "target_commitish=master" \
        -d "body=Mirrored FreeCAD AppImage parts for Docker builds. Upstream: ${GITHUB_URL}")
    release_id=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','')); err=d.get('message',''); sys.exit(0 if d.get('id') else 1)" <<< "$release_json" 2>/dev/null) || {
        echo "ERROR: Failed to create Gitee release:"
        echo "$release_json"
        exit 1
    }
    echo "$release_id"
}

upload_part_gitee() {
    local part_file="$1"
    local part_name release_id
    part_name=$(basename "$part_file")
    release_id="${GITEE_RELEASE_ID:?Gitee release id not set}"
    echo "  Uploading ${part_name} ..."
    local response
    response=$(gitee_api_post_multipart \
        "/repos/${GITEE_OWNER}/${GITEE_REPO}/releases/${release_id}/attach_files" \
        "$part_file")
    if ! python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') or d.get('browser_download_url') else 1)" <<< "$response" 2>/dev/null; then
        echo "ERROR: Gitee upload failed for ${part_name}:"
        echo "$response"
        exit 1
    fi
}

run_glab_api() {
    if command -v glab >/dev/null 2>&1; then
        glab api --hostname "$GITLAB_HOST" "$@"
        return
    fi
    if command -v mise >/dev/null 2>&1; then
        mise x glab -- glab api --hostname "$GITLAB_HOST" "$@"
        return
    fi
    echo "ERROR: glab not found. Install via: mise install glab"
    exit 1
}

upload_part_gitlab() {
    local part_file="$1"
    local part_name
    part_name=$(basename "$part_file")
    echo "  Uploading ${part_name} ..."
    run_glab_api --method PUT \
        "projects/${GITLAB_PROJECT_ID}/packages/generic/${PACKAGE_NAME}/${FREECAD_TAG}/${part_name}" \
        --input "$part_file"
}

if [[ "$MIRROR_TARGET" == "gitee" ]]; then
    if [[ -z "$GITEE_ACCESS_TOKEN" ]]; then
        echo "ERROR: GITEE_ACCESS_TOKEN is required (private token with projects permission)"
        echo "Set it in deploy/.env or export before running."
        exit 1
    fi
    if [[ -z "$GITEE_OWNER" ]]; then
        GITEE_OWNER=$(curl -sS "https://gitee.com/api/v5/user?access_token=${GITEE_ACCESS_TOKEN}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))")
    else
        token_login=$(curl -sS "https://gitee.com/api/v5/user?access_token=${GITEE_ACCESS_TOKEN}" \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))")
        if [[ -n "$token_login" ]] && [[ "$GITEE_OWNER" != "$token_login" ]]; then
            echo "WARNING: GITEE_OWNER=${GITEE_OWNER} != token login ${token_login}; using ${token_login}" >&2
            GITEE_OWNER="$token_login"
        fi
    fi
    if [[ -z "$GITEE_OWNER" ]]; then
        echo "ERROR: GITEE_OWNER is required (your Gitee username or org)"
        exit 1
    fi
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [[ ! -f "$APPIMAGE_PATH" ]]; then
    echo "Downloading ${APPIMAGE_NAME} from GitHub ..."
    curl -L --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 7200 \
        -f -o "$APPIMAGE_PATH" \
        "$GITHUB_URL"
else
    echo "Using cached ${APPIMAGE_PATH}"
fi

APPIMAGE_SHA256=$(sha256sum "$APPIMAGE_PATH" | awk '{print $1}')
FILE_SIZE=$(du -h "$APPIMAGE_PATH" | awk '{print $1}')
echo "File size: ${FILE_SIZE}"
echo "SHA256: ${APPIMAGE_SHA256}"

echo "Splitting into ${PART_SIZE} parts ..."
rm -f "${PART_PREFIX}"*
split -b "$PART_SIZE" -d -a 2 "$APPIMAGE_PATH" "$PART_PREFIX"

mapfile -t PART_FILES < <(ls -1 "${PART_PREFIX}"* | sort)
PART_COUNT=${#PART_FILES[@]}
echo "Created ${PART_COUNT} parts:"
for part in "${PART_FILES[@]}"; do
    du -h "$part"
done

if [[ "$MIRROR_TARGET" == "gitee" ]]; then
    echo "Uploading ${PART_COUNT} parts to Gitee Release ${RELEASE_TAG} ..."
    GITEE_RELEASE_ID=$(get_or_create_gitee_release_id)
    for part in "${PART_FILES[@]}"; do
        upload_part_gitee "$part"
    done
    APPIMAGE_PARTS_PREFIX="https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}/releases/download/${RELEASE_TAG}/${PART_PREFIX}"
    TOKEN_HINT="APPIMAGE_DOWNLOAD_TOKEN=<gitee-private-token if repo is private>"
    TOKEN_TYPE_HINT="APPIMAGE_DOWNLOAD_TOKEN_TYPE=gitee"
else
    echo "Uploading ${PART_COUNT} parts to GitLab Generic Packages ..."
    for part in "${PART_FILES[@]}"; do
        upload_part_gitlab "$part"
    done
    APPIMAGE_PARTS_PREFIX="https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT_ID}/packages/generic/${PACKAGE_NAME}/${FREECAD_TAG}/${PART_PREFIX}"
    TOKEN_HINT="APPIMAGE_DOWNLOAD_TOKEN=<gitlab-project-access-token>"
    TOKEN_TYPE_HINT="APPIMAGE_DOWNLOAD_TOKEN_TYPE=private"
fi

echo ""
echo "=== Mirror complete (${MIRROR_TARGET}) ==="
echo ""
echo "Add to deploy/.env:"
echo ""
echo "APPIMAGE_PARTS_PREFIX=${APPIMAGE_PARTS_PREFIX}"
echo "APPIMAGE_PART_COUNT=${PART_COUNT}"
echo "APPIMAGE_SHA256=${APPIMAGE_SHA256}"
echo "${TOKEN_HINT}"
echo "${TOKEN_TYPE_HINT}"
echo ""
echo "Public Gitee repo: leave APPIMAGE_DOWNLOAD_TOKEN empty."
echo ""
echo "Then rebuild:"
echo "  just docker::compose-build"
