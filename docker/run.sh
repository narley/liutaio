#!/bin/bash
set -euo pipefail

# ─── Liutaio — run Claude Code loops with auto-detecting auth ───
#
# Usage:
#   liutaio <agent-file> <iterations> <base-branch> [options]
#
# Authentication (checked in this order):
#   1. Cached OAuth credentials (Docker volume from a previous --oauth run)
#   2. Host credentials (macOS Keychain or ~/.claude/.credentials.json)
#   3. ANTHROPIC_API_KEY env var
#   4. Interactive OAuth login (prompts user to authorise in browser)
#
# Options:
#   --interactive     Run in foreground (default: detached with log tailing)
#   --oauth           Force interactive OAuth login (skip host credentials)
#   --fresh-login     Clear cached OAuth and re-authenticate
#   --rebuild         Force rebuild the Docker image
#   --dry-run         Print the docker run command without executing
#   --name NAME       Container name (default: liutaio-<base-branch>)
#   --node-version V  Node.js version for the Docker image (default: 22)
#   --repo PATH       Path to the git repository (default: auto-detect)
#   --env KEY=VALUE   Pass env var into the container (repeatable)
# ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IMAGE_NAME="liutaio"
CREDS_VOLUME="liutaio-creds"

# ─── Parse arguments ─────────────────────────────────────────────────
AGENTS_FILE=""
ITERATIONS=""
BASE_BRANCH=""
INTERACTIVE=false
REBUILD=false
DRY_RUN=false
CONTAINER_NAME=""
NODE_VERSION="${LIUTAIO_NODE_VERSION:-22}"
REPO_ROOT=""
EXTRA_ENVS=()
FORCE_OAUTH=false
FRESH_LOGIN=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --interactive)    INTERACTIVE=true; shift ;;
    --oauth)          FORCE_OAUTH=true; shift ;;
    --fresh-login)    FRESH_LOGIN=true; FORCE_OAUTH=true; shift ;;
    --rebuild)        REBUILD=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --help|-h)        AGENTS_FILE=""; ITERATIONS=""; BASE_BRANCH=""; SHOW_HELP=true; break ;;
    --name)           CONTAINER_NAME="$2"; shift 2 ;;
    --node-version)   NODE_VERSION="$2"; shift 2 ;;
    --repo)           REPO_ROOT="$2"; shift 2 ;;
    --env)            EXTRA_ENVS+=("$2"); shift 2 ;;
    -*)               echo "Unknown option: $1"; exit 1 ;;
    *)
      if [ -z "$AGENTS_FILE" ]; then AGENTS_FILE="$1"
      elif [ -z "$ITERATIONS" ]; then ITERATIONS="$1"
      elif [ -z "$BASE_BRANCH" ]; then BASE_BRANCH="$1"
      fi
      shift ;;
  esac
done

if [ -z "$AGENTS_FILE" ] || [ -z "$ITERATIONS" ] || [ -z "$BASE_BRANCH" ]; then
  echo "Liutaio — run Claude Code loops with auto-detecting auth"
  echo ""
  echo "Usage:"
  echo "  liutaio <agent-file> <iterations> <base-branch> [options]"
  echo ""
  echo "Arguments:"
  echo "  agent-file    Path to agent.md relative to repo root"
  echo "  iterations    Number of loop iterations"
  echo "  base-branch   Name of the base branch to create from main"
  echo ""
  echo "Options:"
  echo "  --interactive     Run in foreground with attached TTY"
  echo "  --oauth           Force interactive OAuth login (skip host credentials)"
  echo "  --fresh-login     Clear cached OAuth and re-authenticate"
  echo "  --rebuild         Force rebuild the Docker image"
  echo "  --dry-run         Print docker command without executing"
  echo "  --name NAME       Container name (default: liutaio-<base-branch>)"
  echo "  --node-version V  Node.js version (default: 22, or LIUTAIO_NODE_VERSION)"
  echo "  --repo PATH       Path to git repo (default: auto-detect from cwd)"
  echo "  --env KEY=VALUE   Pass env var into the container (repeatable)"
  echo "  --agent-template  Print the agent.md template to stdout"
  echo "  --version, -v     Show version number"
  echo ""
  echo "Authentication (checked in this order):"
  echo "  1. Cached OAuth credentials (Docker volume from a previous --oauth run)"
  echo "  2. Host credentials (macOS Keychain or ~/.claude/.credentials.json)"
  echo "  3. ANTHROPIC_API_KEY env var"
  echo "  4. Interactive OAuth login (prompts in the terminal)"
  echo ""
  echo "Examples:"
  echo "  liutaio agent.md 10 my-branch              # auto-detect auth"
  echo "  liutaio agent.md 10 my-branch --oauth       # force OAuth login"
  echo "  liutaio agent.md 10 my-branch --fresh-login # re-authenticate"
  if $SHOW_HELP; then exit 0; else exit 1; fi
fi

# ─── Detect repo root ───────────────────────────────────────────────
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -z "$REPO_ROOT" ]; then
    echo "Error: not inside a git repository. Use --repo to specify the path."
    exit 1
  fi
fi

CONTAINER_NAME="${CONTAINER_NAME:-liutaio-${BASE_BRANCH}}"

# ─── Validate agent file exists ──────────────────────────────────────
if [ ! -f "$REPO_ROOT/$AGENTS_FILE" ]; then
  echo "Error: agent file not found: $REPO_ROOT/$AGENTS_FILE"
  exit 1
fi

# ─── Build image ─────────────────────────────────────────────────────
if $REBUILD || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
  echo "Building Liutaio image (Node $NODE_VERSION)..."
  docker build --build-arg NODE_VERSION="$NODE_VERSION" -t "$IMAGE_NAME" "$SCRIPT_DIR"
  echo ""
fi

# ─── Ensure credentials volume exists ───────────────────────────────
docker volume create "$CREDS_VOLUME" &>/dev/null || true

if $FRESH_LOGIN; then
  echo "Clearing cached credentials (--fresh-login)..."
  docker run --rm -v "$CREDS_VOLUME:/credentials" alpine sh -c "rm -f /credentials/credentials.json"
fi

# ─── Resolve authentication method ──────────────────────────────────
# Determines: AUTH_METHOD, CREDS_FILE, USE_API_KEY, NEEDS_TTY

AUTH_METHOD=""
CREDS_FILE=""
USE_API_KEY=false
NEEDS_TTY=false

cleanup_creds() {
  if [ -n "$CREDS_FILE" ] && [ -f "$CREDS_FILE" ]; then
    rm -f "$CREDS_FILE"
  fi
}
trap cleanup_creds EXIT

resolve_auth() {
  # --oauth skips host credentials, goes straight to cached OAuth or interactive
  if ! $FORCE_OAUTH; then

    # 1. Host credentials: macOS Keychain
    if [ "$(uname)" = "Darwin" ]; then
      local keychain_data
      keychain_data=$(security find-generic-password -s "Claude Code-credentials" -a "$(whoami)" -w 2>/dev/null || true)
      if [ -n "$keychain_data" ]; then
        CREDS_FILE=$(mktemp "${TMPDIR:-/tmp}/liutaio-creds-XXXXXX")
        chmod 600 "$CREDS_FILE"
        echo "$keychain_data" > "$CREDS_FILE"
        if jq -e '.claudeAiOauth.accessToken and .claudeAiOauth.refreshToken' "$CREDS_FILE" >/dev/null 2>&1; then
          AUTH_METHOD="keychain"
          return 0
        fi
        rm -f "$CREDS_FILE"
        CREDS_FILE=""
      fi
    fi

    # 2. Host credentials: ~/.claude/.credentials.json
    if [ -f "$HOME/.claude/.credentials.json" ]; then
      CREDS_FILE=$(mktemp "${TMPDIR:-/tmp}/liutaio-creds-XXXXXX")
      chmod 600 "$CREDS_FILE"
      cp "$HOME/.claude/.credentials.json" "$CREDS_FILE"
      if jq -e '.claudeAiOauth.accessToken' "$CREDS_FILE" >/dev/null 2>&1; then
        AUTH_METHOD="credentials-file"
        return 0
      fi
      rm -f "$CREDS_FILE"
      CREDS_FILE=""
    fi

    # 3. API key
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
      AUTH_METHOD="api-key"
      USE_API_KEY=true
      return 0
    fi

  fi

  # 4. Cached OAuth (Docker volume)
  local has_cached
  has_cached=$(docker run --rm -v "$CREDS_VOLUME:/credentials" alpine sh -c \
    "test -f /credentials/credentials.json && echo yes || echo no")
  if [ "$has_cached" = "yes" ]; then
    AUTH_METHOD="cached-oauth"
    return 0
  fi

  # 5. Interactive OAuth (fallback) — needs TTY
  AUTH_METHOD="interactive-oauth"
  NEEDS_TTY=true
  return 0
}

resolve_auth

# ─── Read git user from host ─────────────────────────────────────────
GIT_USER_NAME=$(git config user.name 2>/dev/null || echo "Liutaio Agent")
GIT_USER_EMAIL=$(git config user.email 2>/dev/null || echo "liutaio@users.noreply.github.com")

# ─── Resolve SSH key path ────────────────────────────────────────────
SSH_DIR="$HOME/.ssh"
if [ ! -d "$SSH_DIR" ]; then
  echo "Warning: ~/.ssh not found — git push from container will not work"
fi

# ─── Remove existing container with same name ────────────────────────
if docker container inspect "$CONTAINER_NAME" &>/dev/null; then
  echo "Removing existing container '$CONTAINER_NAME'..."
  docker rm -f "$CONTAINER_NAME" &>/dev/null
fi

# ─── Resolve output directory ────────────────────────────────────────
AGENTS_DIR=$(dirname "$AGENTS_FILE")
OUTPUT_DIR="$REPO_ROOT/$AGENTS_DIR"
mkdir -p "$OUTPUT_DIR"

# ─── Assemble docker run command ─────────────────────────────────────
DOCKER_CMD=(
  docker run
  --name "$CONTAINER_NAME"
  --hostname liutaio
  --init

  # Repo mounted read-only as clone source
  -v "$REPO_ROOT:/repo:ro"

  # SSH keys
  -v "$SSH_DIR:/ssh-keys:ro"

  # Output directory
  -v "$OUTPUT_DIR:/output"

  # Git identity
  -e "GIT_USER_NAME=$GIT_USER_NAME"
  -e "GIT_USER_EMAIL=$GIT_USER_EMAIL"

  # Memory limit
  --memory=16g
)

# Tell the entrypoint which auth method is in use (controls token refresh behaviour)
DOCKER_CMD+=(-e "LIUTAIO_AUTH_METHOD=$AUTH_METHOD")

# Credentials: mount host file (read-only) OR Docker volume (read-write for OAuth caching)
if [ -n "$CREDS_FILE" ]; then
  # Host credentials — mount as read-only file, no volume needed
  DOCKER_CMD+=(-v "$CREDS_FILE:/credentials/credentials.json:ro")
else
  # OAuth or no-creds — mount the volume so the entrypoint can cache credentials
  DOCKER_CMD+=(-v "$CREDS_VOLUME:/credentials")
fi

# Pass API key if using that method
if $USE_API_KEY; then
  DOCKER_CMD+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# SSH hosts override
if [ -n "${LIUTAIO_SSH_HOSTS:-}" ]; then
  DOCKER_CMD+=(-e "LIUTAIO_SSH_HOSTS=$LIUTAIO_SSH_HOSTS")
fi

# Pass ANTHROPIC_API_KEY as fallback even for OAuth modes
if ! $USE_API_KEY && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  DOCKER_CMD+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# User-provided env vars
if [ ${#EXTRA_ENVS[@]} -gt 0 ]; then
  for env_pair in "${EXTRA_ENVS[@]}"; do
    DOCKER_CMD+=(-e "$env_pair")
  done
fi

# Image and arguments
DOCKER_CMD+=(
  "$IMAGE_NAME"
  "$AGENTS_FILE" "$ITERATIONS" "$BASE_BRANCH"
)

# Determine run mode: interactive OAuth needs -it, otherwise respect --interactive
if $NEEDS_TTY || $INTERACTIVE; then
  DOCKER_CMD=("${DOCKER_CMD[@]:0:2}" -it "${DOCKER_CMD[@]:2}")
else
  DOCKER_CMD=("${DOCKER_CMD[@]:0:2}" -d "${DOCKER_CMD[@]:2}")
fi

# ─── Dry run ─────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "Dry run — would execute:"
  echo ""
  PREV_WAS_ENV=false
  for arg in "${DOCKER_CMD[@]}"; do
    if $PREV_WAS_ENV; then
      KEY="${arg%%=*}"
      if echo "$KEY" | grep -qiE '(TOKEN|CREDENTIAL|SECRET|KEY|PASSWORD)'; then
        printf '  %s=***MASKED*** \\\n' "$KEY"
      else
        printf '  %s \\\n' "$arg"
      fi
      PREV_WAS_ENV=false
    elif [ "$arg" = "-e" ]; then
      printf '  %s' "$arg "
      PREV_WAS_ENV=true
    elif [[ "$arg" == *credentials* ]]; then
      printf '  %s \\\n' "***CREDENTIALS_FILE***"
    else
      printf '  %s \\\n' "$arg"
    fi
  done
  exit 0
fi

# ─── Display auth method ────────────────────────────────────────────
AUTH_DISPLAY=""
case "$AUTH_METHOD" in
  keychain)          AUTH_DISPLAY="macOS Keychain" ;;
  credentials-file)  AUTH_DISPLAY="~/.claude/.credentials.json" ;;
  api-key)           AUTH_DISPLAY="ANTHROPIC_API_KEY" ;;
  cached-oauth)      AUTH_DISPLAY="cached OAuth (use --fresh-login to re-auth)" ;;
  interactive-oauth) AUTH_DISPLAY="interactive OAuth (will prompt)" ;;
esac

# ─── Run ─────────────────────────────────────────────────────────────
echo "============================================"
echo "  Liutaio"
echo "============================================"
echo "  Container  : $CONTAINER_NAME"
echo "  Agent      : $AGENTS_FILE"
echo "  Iterations : $ITERATIONS"
echo "  Base branch: $BASE_BRANCH"
echo "  Node       : $NODE_VERSION"
echo "  Output     : $OUTPUT_DIR"
echo "  Auth       : $AUTH_DISPLAY"
echo "  Mode       : $(if $NEEDS_TTY || $INTERACTIVE; then echo 'interactive'; else echo 'detached'; fi)"
echo "============================================"
echo ""

"${DOCKER_CMD[@]}"

# If detached, tail logs
if ! $NEEDS_TTY && ! $INTERACTIVE; then
  echo "Container started. Useful commands:"
  echo ""
  echo "  docker logs -f $CONTAINER_NAME          # tail logs"
  echo "  docker exec -it $CONTAINER_NAME bash     # shell into container"
  echo "  docker stop $CONTAINER_NAME              # stop gracefully"
  echo "  docker rm -f $CONTAINER_NAME             # force remove"
  echo ""
  echo "Tailing logs now (Ctrl+C to detach, container keeps running)..."
  echo ""
  docker logs -f "$CONTAINER_NAME"
fi
