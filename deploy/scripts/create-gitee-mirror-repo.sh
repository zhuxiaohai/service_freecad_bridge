#!/usr/bin/env bash
# Create the Gitee mirror repository and initialize it with a README commit.
#
# Requires in deploy/.env (or environment):
#   GITEE_ACCESS_TOKEN  — private token with projects permission
#   GITEE_OWNER         — optional; auto-detected from token if omitted
#
# Usage:
#   just docker::create-gitee-repo

set -euo pipefail

GITEE_REPO="${GITEE_REPO:-freecad-appimage-mirror}"
GITEE_ACCESS_TOKEN="${GITEE_ACCESS_TOKEN:-}"
GITEE_OWNER="${GITEE_OWNER:-}"
REPO_PRIVATE="${GITEE_REPO_PRIVATE:-false}"

if [[ -z "$GITEE_ACCESS_TOKEN" ]]; then
    echo "ERROR: GITEE_ACCESS_TOKEN is required"
    echo ""
    echo "1. Open https://gitee.com/profile/personal_access_tokens"
    echo "2. Create a token with 'projects' scope"
    echo "3. Add to deploy/.env:"
    echo "     GITEE_ACCESS_TOKEN=<your-token>"
    echo "     GITEE_OWNER=zhuxiaohai   # optional if token is yours"
    exit 1
fi

if [[ -z "$GITEE_OWNER" ]]; then
    echo "Detecting Gitee user from token ..."
    user_json=$(curl -sS "https://gitee.com/api/v5/user?access_token=${GITEE_ACCESS_TOKEN}")
    GITEE_OWNER=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('login',''))" <<< "$user_json")
    if [[ -z "$GITEE_OWNER" ]]; then
        echo "ERROR: Could not detect Gitee username:"
        echo "$user_json"
        exit 1
    fi
    echo "Gitee owner: ${GITEE_OWNER}"
else
    # Validate GITEE_OWNER matches token login (display name != login on Gitee).
    token_login=$(curl -sS "https://gitee.com/api/v5/user?access_token=${GITEE_ACCESS_TOKEN}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('login',''))")
    if [[ -n "$token_login" ]] && [[ "$GITEE_OWNER" != "$token_login" ]]; then
        echo "WARNING: GITEE_OWNER=${GITEE_OWNER} does not match token login ${token_login}; using ${token_login}"
        GITEE_OWNER="$token_login"
    fi
fi

repo_json=$(curl -sS "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}?access_token=${GITEE_ACCESS_TOKEN}" || true)
if python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') else 1)" <<< "$repo_json" 2>/dev/null; then
    echo "Repository already exists: https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
else
    echo "Creating repository ${GITEE_OWNER}/${GITEE_REPO} (private=${REPO_PRIVATE}) ..."
    create_json=$(curl -sS -X POST "https://gitee.com/api/v5/user/repos" \
        -d "access_token=${GITEE_ACCESS_TOKEN}" \
        -d "name=${GITEE_REPO}" \
        -d "description=FreeCAD AppImage split mirror for freecad-bridge Docker builds" \
        -d "private=${REPO_PRIVATE}" \
        -d "has_issues=false" \
        -d "has_wiki=false" \
        -d "can_comment=false")
    if ! python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('id') else 1)" <<< "$create_json" 2>/dev/null; then
        if [[ "$create_json" == *"已存在"* ]] || [[ "$create_json" == *"already exists"* ]]; then
            echo "Repository already exists: https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
        else
            echo "ERROR: Failed to create repository:"
            echo "$create_json"
            exit 1
        fi
    else
        echo "Created: https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
    fi
fi

# Initialize with README if the repo has no commits (needed for Gitee releases).
branch_json=$(curl -sS \
    "https://gitee.com/api/v5/repos/${GITEE_OWNER}/${GITEE_REPO}/branches/master?access_token=${GITEE_ACCESS_TOKEN}" || true)
if python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('name') else 1)" <<< "$branch_json" 2>/dev/null; then
    echo "Repository already has commits on master."
else
    echo "Initializing repository with README ..."
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
    cd "$workdir"
    git init -b master
    cat > README.md << EOF
# FreeCAD AppImage Mirror

Split FreeCAD AppImage parts for [\`freecad-bridge\`](https://github.com/zhuxiaohai/service_freecad_bridge) Docker builds.

- Binary assets are published via **Gitee Releases** (not stored in git history).
- Upload: \`just docker::mirror-appimage\` from the bridge repository.

Upstream: [FreeCAD on GitHub](https://github.com/FreeCAD/FreeCAD)
EOF
    git add README.md
    git -c user.name="freecad-bridge" -c user.email="freecad-bridge@localhost" \
        commit -m "docs: initialize mirror repository"
    git remote add origin "https://${GITEE_OWNER}:${GITEE_ACCESS_TOKEN}@gitee.com/${GITEE_OWNER}/${GITEE_REPO}.git"
    git push -u origin master
    echo "Pushed initial README to master."
fi

echo ""
echo "=== Gitee repository ready ==="
echo "URL: https://gitee.com/${GITEE_OWNER}/${GITEE_REPO}"
echo ""
echo "Next steps:"
echo "  1. Ensure deploy/.env has:"
echo "       GITEE_OWNER=${GITEE_OWNER}"
echo "       GITEE_ACCESS_TOKEN=<your-token>"
echo "  2. Upload AppImage parts:"
echo "       just docker::mirror-appimage"
