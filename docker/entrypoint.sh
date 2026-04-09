#!/bin/bash
set -euo pipefail

AGENTS_FILE="${1:-}"
ITERATIONS="${2:-}"
BASE_BRANCH="${3:-}"
LOGDIR="${4:-/tmp/liutaio}"

if [ -z "$AGENTS_FILE" ] || [ -z "$ITERATIONS" ] || [ -z "$BASE_BRANCH" ]; then
  echo "Usage: liutaio <agent-file> <iterations> <base-branch> [log-dir]"
  echo ""
  echo "  agent-file   Path to agent.md relative to repo root"
  echo "  iterations   Number of ralph loop iterations"
  echo "  base-branch  Name of the base branch to create from main"
  echo "  log-dir      Log directory (default: /tmp/liutaio)"
  exit 1
fi

# ─── Authenticate ───────────────────────────────────────────────────
# Priority: 1) mounted/cached credentials  2) API key  3) interactive OAuth
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"

NEED_LOGIN=true

if [ -f /credentials/credentials.json ]; then
  cp /credentials/credentials.json "$CLAUDE_DIR/.credentials.json"
  chmod 600 "$CLAUDE_DIR/.credentials.json"
  echo "Auth: credentials loaded from mount/cache"
  NEED_LOGIN=false
elif [ -f "$CLAUDE_DIR/.credentials.json" ]; then
  if jq -e '.claudeAiOauth.accessToken' "$CLAUDE_DIR/.credentials.json" >/dev/null 2>&1; then
    echo "Auth: existing credentials found"
    NEED_LOGIN=false
  fi
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Auth: using ANTHROPIC_API_KEY"
  NEED_LOGIN=false
fi

# ─── Interactive OAuth PKCE flow (fallback) ─────────────────────────
if $NEED_LOGIN; then
  echo ""
  echo "============================================"
  echo "  Claude OAuth Login"
  echo "============================================"
  echo ""

  OAUTH_CLIENT_ID="${LIUTAIO_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
  OAUTH_AUTHORIZE="https://claude.com/cai/oauth/authorize"
  OAUTH_TOKEN="https://platform.claude.com/v1/oauth/token"
  OAUTH_REDIRECT="https://platform.claude.com/oauth/code/callback"
  OAUTH_SCOPE="org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  # Generate PKCE code_verifier (43-128 chars from [A-Za-z0-9])
  # tr -d '\n' removes newlines that base64 inserts every 76 chars
  CODE_VERIFIER=$(head -c 96 /dev/urandom | base64 | tr -d '\n=+/' | head -c 128)

  # code_challenge = base64url(sha256(code_verifier))
  CODE_CHALLENGE=$(printf '%s' "$CODE_VERIFIER" \
    | openssl dgst -sha256 -binary \
    | base64 \
    | tr -d '\n' \
    | tr '+/' '-_' \
    | tr -d '=')

  STATE=$(head -c 32 /dev/urandom | base64 | tr -d '\n=+/' | head -c 43)

  ENCODED_SCOPE=$(printf '%s' "$OAUTH_SCOPE" | sed 's/ /%20/g')
  ENCODED_REDIRECT=$(printf '%s' "$OAUTH_REDIRECT" | jq -sRr @uri)
  AUTH_URL="${OAUTH_AUTHORIZE}?code=true&client_id=${OAUTH_CLIENT_ID}&response_type=code&redirect_uri=${ENCODED_REDIRECT}&scope=${ENCODED_SCOPE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&state=${STATE}"

  echo "  Open this URL in your browser and authorise:"
  echo ""
  echo "  $AUTH_URL"
  echo ""
  echo "  After authorising, you'll see a page with a code."
  echo "  Copy the ENTIRE code (including any # in the middle)"
  echo "  and paste it below."
  echo ""
  printf "  Code: "
  read -r AUTH_CODE </dev/tty

  if [ -z "$AUTH_CODE" ]; then
    echo "Error: No code entered."
    exit 1
  fi

  # Pasted code format: "{authorization_code}#{state}"
  OAUTH_CODE="${AUTH_CODE%%#*}"
  OAUTH_STATE="${AUTH_CODE#*#}"

  if [ -z "$OAUTH_CODE" ] || [ "$OAUTH_CODE" = "$AUTH_CODE" ]; then
    echo "Error: Invalid code format. Expected {code}#{state}."
    exit 1
  fi

  echo ""
  echo "  Exchanging code for tokens..."

  TOKEN_BODY=$(jq -n \
    --arg grant_type "authorization_code" \
    --arg code "$OAUTH_CODE" \
    --arg redirect_uri "$OAUTH_REDIRECT" \
    --arg client_id "$OAUTH_CLIENT_ID" \
    --arg code_verifier "$CODE_VERIFIER" \
    --arg state "$OAUTH_STATE" \
    '{grant_type: $grant_type, code: $code, redirect_uri: $redirect_uri, client_id: $client_id, code_verifier: $code_verifier, state: $state}')

  TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$OAUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code" \
    -d "$TOKEN_BODY" \
    2>&1)

  HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
  RESPONSE_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')

  ACCESS_TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.access_token // empty')
  REFRESH_TOKEN=$(echo "$RESPONSE_BODY" | jq -r '.refresh_token // empty')
  EXPIRES_IN=$(echo "$RESPONSE_BODY" | jq -r '.expires_in // empty')

  if [ -z "$ACCESS_TOKEN" ]; then
    echo "  Error: Token exchange failed (HTTP $HTTP_CODE):"
    echo "  $RESPONSE_BODY"
    exit 1
  fi

  # expiresAt must be Unix epoch in MILLISECONDS
  EXPIRES_AT_MS=0
  if [ -n "$EXPIRES_IN" ] && [ "$EXPIRES_IN" != "null" ]; then
    EXPIRES_AT_MS=$(( $(date +%s) * 1000 + EXPIRES_IN * 1000 ))
  fi

  # Build credentials.json in the exact format Claude Code expects
  CREDS_JSON=$(jq -n \
    --arg at "$ACCESS_TOKEN" \
    --arg rt "${REFRESH_TOKEN:-}" \
    --argjson ea "$EXPIRES_AT_MS" \
    '{
      claudeAiOauth: {
        accessToken: $at,
        refreshToken: $rt,
        expiresAt: $ea,
        scopes: [
          "org:create_api_key",
          "user:file_upload",
          "user:inference",
          "user:mcp_servers",
          "user:profile",
          "user:sessions:claude_code"
        ]
      }
    }')

  echo "$CREDS_JSON" > "$CLAUDE_DIR/.credentials.json"
  chmod 600 "$CLAUDE_DIR/.credentials.json"

  echo "  Login successful."

  # Persist credentials to mounted volume so they survive container restarts
  if [ -d /credentials ] && [ -w /credentials ]; then
    cp "$CLAUDE_DIR/.credentials.json" /credentials/credentials.json
    chmod 600 /credentials/credentials.json
    echo "  Credentials cached (will persist across restarts)."
  fi

  echo ""
fi

AGENTS_DIR=$(dirname "$AGENTS_FILE")

echo ""
echo "============================================"
echo "  Liutaio"
echo "============================================"
echo "  Agent file  : $AGENTS_FILE"
echo "  Iterations  : $ITERATIONS"
echo "  Base branch : $BASE_BRANCH"
echo "  Log dir     : $LOGDIR"
echo "============================================"

# ─── Clone from mounted source repo ──────────────────────────────────
echo ""
echo "[1/7] Cloning repository from /repo..."
git clone /repo /workspace 2>&1 | tail -1
cd /workspace

# Repoint origin from local /repo mount to the real remote
REAL_REMOTE=$(git -C /repo remote get-url origin 2>/dev/null || echo "")
if [ -n "$REAL_REMOTE" ]; then
  git remote set-url origin "$REAL_REMOTE"
  echo "  Remote set to: $REAL_REMOTE"
fi

# Copy agent file (and its directory) from host if not on main
if [ ! -f "/workspace/$AGENTS_FILE" ] && [ -f "/repo/$AGENTS_FILE" ]; then
  echo "  Agent file not on main — copying from host repo..."
  mkdir -p "/workspace/$AGENTS_DIR"
  cp -r "/repo/$AGENTS_DIR/." "/workspace/$AGENTS_DIR/"
  echo "  Copied: $AGENTS_DIR/"
fi

# Copy liutaio.setup.sh from host if not in git
if [ ! -f "/workspace/liutaio.setup.sh" ] && [ -f "/repo/liutaio.setup.sh" ]; then
  cp "/repo/liutaio.setup.sh" "/workspace/liutaio.setup.sh"
  chmod +x "/workspace/liutaio.setup.sh"
  echo "  Copied: liutaio.setup.sh"
fi

# ─── Checkout main and create/reuse base branch ─────────────────────
if [ "${LIUTAIO_REUSE_BRANCH:-}" = "true" ]; then
  echo "[2/7] Reusing existing branch '$BASE_BRANCH'..."
  git checkout "$BASE_BRANCH" --quiet
else
  echo "[2/7] Creating base branch '$BASE_BRANCH' from main..."
  git checkout main --quiet
  git checkout -b "$BASE_BRANCH" --quiet
fi

# ─── Git config ──────────────────────────────────────────────────────
git config user.name "${GIT_USER_NAME:-Liutaio Agent}"
git config user.email "${GIT_USER_EMAIL:-liutaio@users.noreply.github.com}"

# ─── SSH setup ───────────────────────────────────────────────────────
echo "[3/7] Setting up SSH..."
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ -d /ssh-keys ]; then
  cp /ssh-keys/id_* "$SSH_DIR/" 2>/dev/null || true
  chmod 600 "$SSH_DIR"/id_* 2>/dev/null || true
  if [ -f /ssh-keys/config ]; then
    cp /ssh-keys/config "$SSH_DIR/config"
    chmod 600 "$SSH_DIR/config"
  fi
fi

if [ -n "${LIUTAIO_SSH_HOSTS:-}" ]; then
  IFS=',' read -ra HOSTS <<< "$LIUTAIO_SSH_HOSTS"
  for host in "${HOSTS[@]}"; do
    timeout 5 ssh-keyscan "$(echo "$host" | xargs)" >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  done
elif [ -n "$REAL_REMOTE" ]; then
  SSH_HOST=$(echo "$REAL_REMOTE" | sed -n 's|.*@\([^:]*\):.*|\1|p; s|.*://\([^/]*\)/.*|\1|p' | head -1)
  if [ -n "$SSH_HOST" ]; then
    if [ -f "$SSH_DIR/config" ]; then
      REAL_HOST=$(awk -v host="$SSH_HOST" '
        tolower($1) == "host" && $2 == host { found=1; next }
        tolower($1) == "host" { found=0 }
        found && tolower($1) == "hostname" { print $2; exit }
      ' "$SSH_DIR/config")
      if [ -n "$REAL_HOST" ]; then
        echo "  Resolved SSH alias '$SSH_HOST' -> '$REAL_HOST'"
        SSH_HOST="$REAL_HOST"
      fi
    fi
    timeout 5 ssh-keyscan "$SSH_HOST" >> "$SSH_DIR/known_hosts" 2>/dev/null || true
    echo "  SSH host: $SSH_HOST"
  fi
else
  timeout 5 ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  echo "  SSH host: github.com (default)"
fi

# ─── Install dependencies ────────────────────────────────────────────
echo "[4/7] Installing dependencies..."

install_deps() {
  if [ -x "./liutaio.setup.sh" ]; then
    echo "  Running liutaio.setup.sh..."
    bash ./liutaio.setup.sh
    return
  fi

  if [ -f "pnpm-lock.yaml" ]; then
    echo "  Detected pnpm project"
    npm install -g pnpm 2>&1 | tail -1
    pnpm install 2>&1 | tail -3
  elif [ -f "bun.lock" ] || [ -f "bun.lockb" ]; then
    echo "  Detected Bun project"
    npm install -g bun 2>&1 | tail -1
    bun install 2>&1 | tail -3
  elif [ -f "yarn.lock" ]; then
    echo "  Detected Yarn project"
    yarn install 2>&1 | tail -3
  elif [ -f "package-lock.json" ] || [ -f "package.json" ]; then
    echo "  Detected npm project"
    npm install 2>&1 | tail -3
  elif [ -f "requirements.txt" ]; then
    echo "  Detected Python project (requirements.txt)"
    pip install -r requirements.txt 2>&1 | tail -3
  elif [ -f "pyproject.toml" ]; then
    echo "  Detected Python project (pyproject.toml)"
    pip install -e . 2>&1 | tail -3
  elif [ -f "Pipfile" ]; then
    echo "  Detected Pipenv project"
    pip install pipenv 2>&1 | tail -1
    pipenv install 2>&1 | tail -3
  elif [ -f "go.sum" ]; then
    echo "  Detected Go project"
    go mod download 2>&1 | tail -3
  elif [ -f "Cargo.lock" ] || [ -f "Cargo.toml" ]; then
    echo "  Detected Rust project"
    cargo fetch 2>&1 | tail -3
  elif [ -f "Gemfile.lock" ]; then
    echo "  Detected Ruby project"
    bundle install 2>&1 | tail -3
  elif [ -f "composer.json" ]; then
    echo "  Detected PHP project"
    composer install 2>&1 | tail -3
  else
    echo "  No recognised project type — skipping dependency install"
    echo "  Create a liutaio.setup.sh for custom setup"
  fi
}

install_deps

# ─── Post-checkout hook (auto reinstall on dependency file changes) ───
echo "[5/7] Setting up git hooks..."
mkdir -p .git/hooks
cat > .git/hooks/post-checkout << 'HOOK'
#!/bin/bash
OLD_HEAD="$1"
NEW_HEAD="$2"
IS_BRANCH_CHECKOUT="$3"

[ "$IS_BRANCH_CHECKOUT" = "1" ] || exit 0

CHANGED=$(git diff --name-only "$OLD_HEAD" "$NEW_HEAD" -- \
  '**/package.json' '**/package-lock.json' \
  '**/yarn.lock' '**/pnpm-lock.yaml' '**/bun.lock' \
  '**/requirements.txt' '**/Pipfile.lock' '**/pyproject.toml' \
  '**/go.sum' '**/Cargo.lock' \
  '**/Gemfile.lock' '**/composer.lock' \
  2>/dev/null | head -1)

if [ -n "$CHANGED" ]; then
  echo "post-checkout: dependency files changed, reinstalling..."
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "$REPO_ROOT"
  if [ -x "./liutaio.setup.sh" ]; then
    bash ./liutaio.setup.sh
  elif [ -f "pnpm-lock.yaml" ]; then pnpm install
  elif [ -f "bun.lock" ] || [ -f "bun.lockb" ]; then bun install
  elif [ -f "yarn.lock" ]; then yarn install
  elif [ -f "package-lock.json" ] || [ -f "package.json" ]; then npm install
  elif [ -f "requirements.txt" ]; then pip install -r requirements.txt
  elif [ -f "pyproject.toml" ]; then pip install -e .
  elif [ -f "go.sum" ]; then go mod download
  elif [ -f "Cargo.lock" ]; then cargo fetch
  elif [ -f "Gemfile.lock" ]; then bundle install
  elif [ -f "composer.json" ]; then composer install
  fi
fi
HOOK
chmod +x .git/hooks/post-checkout

git config core.hooksPath .git/hooks

# ─── Output directory ─────────────────────────────────────────────────
echo "[6/7] Checking output directory..."
if [ -d /output ]; then
  echo "  /output mounted — progress.md will be copied after each iteration"
else
  echo "  Warning: /output not mounted — progress.md will only exist inside container"
fi

echo "[7/7] Ready."

echo ""
echo "============================================"
echo "  Liutaio ready. Starting loop..."
echo "============================================"
echo ""

# ─── Token refresh helper ─────────────────────────────────────────────
OAUTH_CLIENT_ID="${LIUTAIO_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
TOKEN_ENDPOINT="https://platform.claude.com/v1/oauth/token"

refresh_oauth_token() {
  # Skip refresh for host credentials — refreshing invalidates the host's token
  local auth_method="${LIUTAIO_AUTH_METHOD:-}"
  if [ "$auth_method" = "keychain" ] || [ "$auth_method" = "credentials-file" ]; then
    return 0
  fi

  local creds_file="$HOME/.claude/.credentials.json"
  [ -f "$creds_file" ] || return 0

  local refresh_token
  refresh_token=$(jq -r '.claudeAiOauth.refreshToken // empty' "$creds_file" 2>/dev/null)
  [ -n "$refresh_token" ] || return 0

  echo "  Refreshing OAuth token..."
  local response
  local refresh_scope="user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  local refresh_body
  refresh_body=$(jq -n \
    --arg grant_type "refresh_token" \
    --arg refresh_token "$refresh_token" \
    --arg client_id "$OAUTH_CLIENT_ID" \
    --arg scope "$refresh_scope" \
    '{grant_type: $grant_type, refresh_token: $refresh_token, client_id: $client_id, scope: $scope}')
  response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code" \
    -d "$refresh_body" \
    2>/dev/null)

  local new_access_token new_refresh_token
  new_access_token=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
  new_refresh_token=$(echo "$response" | jq -r '.refresh_token // empty' 2>/dev/null)

  if [ -n "$new_access_token" ]; then
    local new_expires_in
    new_expires_in=$(echo "$response" | jq -r '.expires_in // empty' 2>/dev/null)
    local new_expires_at=0
    if [ -n "$new_expires_in" ] && [ "$new_expires_in" != "null" ]; then
      new_expires_at=$(( $(date +%s) * 1000 + new_expires_in * 1000 ))
    fi

    local updated
    updated=$(jq \
      --arg at "$new_access_token" \
      --arg rt "${new_refresh_token:-$refresh_token}" \
      --argjson ea "$new_expires_at" \
      '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $ea' "$creds_file")
    echo "$updated" > "$creds_file"
    chmod 600 "$creds_file"
    echo "  Token refreshed successfully."

    # Persist refreshed credentials to mounted volume
    if [ -d /credentials ] && [ -w /credentials ]; then
      cp "$creds_file" /credentials/credentials.json
      chmod 600 /credentials/credentials.json
    fi
  else
    echo "  Warning: token refresh failed (will retry next iteration)"
    echo "  Response: $(echo "$response" | head -c 200)"
  fi
}

# ─── Push helper ─────────────────────────────────────────────────────
push_base_branch() {
  local current_branch
  current_branch=$(git branch --show-current)

  if [ "$current_branch" != "$BASE_BRANCH" ]; then
    git stash --quiet 2>/dev/null || true
    git checkout "$BASE_BRANCH" --quiet 2>/dev/null || true
  fi

  local commit_count
  commit_count=$(git rev-list --count main.."$BASE_BRANCH" 2>/dev/null || echo "0")
  if [ "$commit_count" -gt 0 ]; then
    echo "Pushing $commit_count commit(s) on '$BASE_BRANCH' to origin..."
    git push origin "$BASE_BRANCH" 2>&1 || echo "Warning: push failed"
  fi

  if [ "$current_branch" != "$BASE_BRANCH" ]; then
    git checkout "$current_branch" --quiet 2>/dev/null || true
    git stash pop --quiet 2>/dev/null || true
  fi
}

# ─── Trap: push on exit (safety net for crashes/stops) ───────────────
trap 'echo ""; echo "Container stopping — pushing base branch..."; push_base_branch' EXIT

# ─── Run the loop ────────────────────────────────────────────────────
mkdir -p "$LOGDIR"

START_TIME=$SECONDS

elapsed() {
  local total=$(( SECONDS - START_TIME ))
  local h=$(( total / 3600 ))
  local m=$(( (total % 3600) / 60 ))
  local s=$(( total % 60 ))
  printf "%dh %dm %ds" "$h" "$m" "$s"
}

for ((i=1; i<=$ITERATIONS; i++)); do
  LOGFILE="$LOGDIR/iteration-${i}.log"

  # Copy progress.md to host before each iteration (safety net for crashes)
  if [ -d /output ] && [ -f "/workspace/$AGENTS_DIR/progress.md" ]; then
    cp "/workspace/$AGENTS_DIR/progress.md" /output/progress.md 2>/dev/null || true
  fi

  # Refresh OAuth token before each iteration
  refresh_oauth_token

  echo "============================================"
  echo "Iteration $i / $ITERATIONS — $(date)"
  echo "Logging to: $LOGFILE"
  echo "============================================"

  # Show which ticket is next
  NEXT_TICKET=""
  PROGRESS_FILE="/workspace/$AGENTS_DIR/progress.md"
  TICKETS_DIR="/workspace/$AGENTS_DIR/tickets"

  if [ -f "$PROGRESS_FILE" ]; then
    # Try "## Next Steps" section first
    NEXT_TICKET=$(awk '/^## Next Steps/{found=1; next} /^## /{found=0} found && /[^ \t]/{print; exit}' "$PROGRESS_FILE" | sed 's/^[[:space:]-]*//; s/^\*\{0,2\}[Nn]ext [Tt]icket\*\{0,2\}:[[:space:]]*//' || true)

    # Fallback: first ticket in the table NOT marked DONE
    if [ -z "$NEXT_TICKET" ]; then
      NEXT_ID=$(awk -F'|' '/\|.*\|.*\|/ && !/DONE/ && !/Status/' '{gsub(/[ \t]/, "", $2); if ($2 != "" && $2 != "---") print $2; }' "$PROGRESS_FILE" | head -1 || true)
      if [ -n "$NEXT_ID" ] && [ -d "$TICKETS_DIR" ]; then
        # Read the title (first line) from the ticket file
        TICKET_FILE=$(ls "$TICKETS_DIR"/${NEXT_ID}* 2>/dev/null | head -1)
        if [ -n "$TICKET_FILE" ]; then
          NEXT_TICKET=$(head -1 "$TICKET_FILE" | sed 's/^#* *//')
        else
          NEXT_TICKET="$NEXT_ID"
        fi
      elif [ -n "$NEXT_ID" ]; then
        NEXT_TICKET="$NEXT_ID"
      fi
    fi
  fi

  if [ -n "$NEXT_TICKET" ]; then
    echo "Current Ticket: $NEXT_TICKET"
    echo "============================================"
  fi

  claude --dangerously-skip-permissions --output-format stream-json --verbose \
    -p "You are running in AFK (unattended) mode inside a Docker container (Liutaio). Follow the instructions in @${AGENTS_FILE}. IMPORTANT: Since no human is present, whenever a step says to ask the human for confirmation (e.g. merge confirmation, manual steps), auto-approve and proceed automatically. Answer 'yes' to your own merge prompts. For human-assisted tickets that require manual operations, skip them, note it in progress.md, and continue to the next ticket. IMPORTANT: Do NOT commit progress.md — it is tracked outside of git. IMPORTANT: Work on exactly ONE ticket per session. After completing one ticket (code committed, progress.md updated, branch merged and verified), STOP. Do not start the next ticket — the next iteration will handle it." \
    2>"$LOGFILE.stderr" \
    | grep --line-buffered '^{' \
    | tee "$LOGFILE" \
    | jq --unbuffered -rj '
      if .type == "assistant" then
        .message.content[]? |
        if .type == "tool_use" then
          "  " + .name + ": " + (.input | tostring | .[0:200]) + "\n"
        elif .type == "text" then
          .text // empty
        else empty end
      elif .type == "result" then
        "\nSession complete (" + (.total_cost_usd // 0 | tostring) + " USD)\n"
      else empty end'

  echo ""

  # Push base branch after each iteration
  echo "Pushing after iteration $i..."
  push_base_branch

  # Copy progress.md back to host
  if [ -d /output ]; then
    cp "/workspace/$AGENTS_DIR/progress.md" /output/progress.md 2>/dev/null || true
  fi

  # Check for completion token
  if grep -q '<promise>.*COMPLETE.*</promise>' "$LOGFILE"; then
    echo ""
    echo "All tickets complete after $i iterations. Total time: $(elapsed)"
    exit 0
  fi

  echo "Iteration $i finished. Completion token not found, continuing..."
  echo ""
done

echo "Reached max iterations ($ITERATIONS) without completion token. Total time: $(elapsed)"
exit 1
