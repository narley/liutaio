# Liutaio

Let AI agents work through your tickets while you grab a coffee. Liutaio runs Claude Code in a Docker container, clones your repo, works through tasks one by one, and pushes the results. When it's done, you come back to completed work on your branch.

It works with any project — Node.js, Python, Go, Rust, Ruby, PHP — and handles authentication automatically so you can get started with zero setup. (The container ships with Node.js because Claude Code itself is a Node CLI tool, but your project can use any language.)

## Why "Liutaio"?

*Liutaio* (pronounced lee-oo-TY-oh) is the Italian word for a luthier — a craftsman who builds and repairs string instruments like violins. A liutaio works methodically in a workshop, shaping raw materials into precise, finely tuned instruments through patience and skill.

That's the metaphor here: Liutaio is the workshop where AI agents craft code, working through tickets methodically in an isolated environment, producing something refined at the end.

The name was chosen to be tool-agnostic — while Liutaio currently works with Claude Code, the architecture is designed to support other AI coding agents in the future.

## Install

```bash
npm install -g liutaio
```

## Getting Started

You need three things:

1. **Docker** installed and running
2. **SSH keys** in `~/.ssh/` that can push to your repo
3. An **agent.md** file in your repo describing the work to do (see [Writing Your agent.md](#writing-your-agentmd))

Then just run:

```bash
liutaio agent.md 10 my-feature-branch
```

That's it. Liutaio figures out authentication, builds the container, clones your repo, installs dependencies, and starts working.

## Authentication

Liutaio tries to authenticate automatically — you don't need to configure anything upfront. It checks these in order and uses the first one that works:

| Method | How to set it up |
|--------|-----------------|
| **macOS Keychain** | Run `claude auth login` on your Mac once. Liutaio picks it up. |
| **Credentials file** | Have `~/.claude/.credentials.json` on your machine (common on Linux/CI). |
| **API key** | Set `export ANTHROPIC_API_KEY=sk-ant-...` in your shell. |
| **Interactive OAuth** | No setup needed! Liutaio shows a URL, you open it, paste the code back. |

If you've ever used Claude Code on your machine, you're already set. If not, Liutaio will walk you through a one-time OAuth login right in the terminal.

### Using OAuth (recommended for shared machines)

If you don't want to touch your host credentials, or you're on a machine where Claude Code isn't installed, use `--oauth`:

```bash
liutaio agent.md 10 my-branch --oauth
```

Liutaio will show you a URL to open in your browser. After authorising, you'll see a code on the page — paste it back into the terminal. Your credentials are then cached in a Docker volume, so you only need to do this once.

To re-authenticate later (e.g. switching accounts):

```bash
liutaio agent.md 10 my-branch --fresh-login
```

### Cached OAuth credentials

When you log in via OAuth, your credentials are saved in a Docker volume (`liutaio-creds`). This means:

- They survive container removal — you won't be asked to log in again
- Token refresh happens automatically between iterations
- Use `--fresh-login` to clear the cache and start fresh
- To delete them entirely: `docker volume rm liutaio-creds`

## How It Works

Here's what happens when you run Liutaio:

```
Your machine                       Docker container
────────────                       ────────────────
1. Detect auth method               5. Load credentials
2. Build Docker image               6. Clone your repo
3. Mount repo (read-only)           7. Create base branch from main
4. Start container                  8. Install dependencies
                                    9. Loop:
                                       a. Refresh auth token
                                       b. Run Claude Code on one ticket
                                       c. Push to remote
                                       d. Copy progress.md to host
                                       e. Stop when all done
```

Each iteration works on exactly one ticket. After completing it (code committed, tests passing, branch merged), Liutaio moves to the next one. When all tickets are done, the container exits.

If the container crashes or you stop it (`docker stop`), it pushes whatever work is on the base branch before shutting down — you never lose progress.

## Writing Your agent.md

The `agent.md` file tells Claude Code what to do. Put it anywhere in your repo (you pass the path as the first argument). Here's a minimal example:

```markdown
# My Feature

## Tickets

Work through these tickets in order. Each ticket has a detailed spec
in the `tickets/` folder.

### Execution Order

1. **TICKET-001** — Add user validation
2. **TICKET-002** — Update API endpoints
3. **TICKET-003** — Write integration tests

## Branch Workflow

- Create a feature branch from the base branch for each ticket
- Run lint and tests before committing
- Merge back into the base branch when done

## Verification

Run these commands to verify your work:
- `npm run lint`
- `npm run test`

## Progress Tracking

Maintain a `progress.md` file tracking what's been done.
When all tickets are complete, output: <promise>COMPLETE</promise>
```

See `agent-template.md` for a more complete template.

### Key conventions

- **One ticket per iteration**: Claude works on exactly one ticket, then stops. The next iteration picks up the next ticket.
- **Completion signal**: When all work is done, Claude outputs `<promise>COMPLETE</promise>` and the loop ends.
- **progress.md**: Claude updates this file after each ticket. It's copied to your host after every iteration so you can check progress without entering the container.
- **progress.md is not committed**: It stays outside of git — tracked via the `/output` mount instead.

## Custom Dependency Installation

Liutaio auto-detects your project type and installs dependencies:

| What it finds | What it runs |
|--------------|-------------|
| `pnpm-lock.yaml` | `pnpm install` |
| `yarn.lock` | `yarn install` |
| `bun.lock` | `bun install` |
| `package-lock.json` | `npm install` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `pyproject.toml` | `pip install -e .` |
| `go.sum` | `go mod download` |
| `Cargo.lock` | `cargo fetch` |
| `Gemfile.lock` | `bundle install` |
| `composer.json` | `composer install` |

For monorepos or projects with private registries, create a `liutaio.setup.sh` at your repo root. If this file exists, Liutaio runs it instead of auto-detection:

```bash
#!/bin/bash
# Example: monorepo with specific install order and private registry
cat > packages/api/.npmrc << EOF
@myorg:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${MY_NPM_TOKEN}
EOF

npm install --prefix packages/shared
npm install --prefix packages/api
npm install --prefix packages/client
```

Pass private tokens with `--env`:

```bash
liutaio agent.md 10 my-branch --env MY_NPM_TOKEN=ghp_xxxx
```

## CLI Reference

```
liutaio <agent-file> <iterations> <base-branch> [options]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `agent-file` | Path to your agent.md relative to repo root |
| `iterations` | Maximum number of loop iterations (one ticket per iteration) |
| `base-branch` | Name of the branch to create from main |

### Options

| Option | Description |
|--------|-------------|
| `--interactive` | Run in foreground with attached terminal |
| `--oauth` | Force interactive OAuth login (skip host credentials) |
| `--fresh-login` | Clear cached OAuth and re-authenticate |
| `--rebuild` | Force rebuild the Docker image |
| `--dry-run` | Print the docker command without running it (secrets masked) |
| `--name NAME` | Custom container name (default: `liutaio-<base-branch>`) |
| `--node-version V` | Node.js version (default: 22) |
| `--repo PATH` | Path to git repo (default: auto-detect from current directory) |
| `--env KEY=VALUE` | Pass environment variable into the container (repeatable) |

### Environment variables

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | API key for authentication (alternative to OAuth) |
| `LIUTAIO_NODE_VERSION` | Default Node.js version (overridden by `--node-version`) |
| `LIUTAIO_SSH_HOSTS` | Comma-separated SSH hosts for known_hosts (e.g. `gitlab.com,github.com`) |
| `LIUTAIO_OAUTH_CLIENT_ID` | Override Claude Code's OAuth client ID (only if Anthropic rotates it) |
| `GIT_USER_NAME` | Git committer name (default: your host's git config) |
| `GIT_USER_EMAIL` | Git committer email (default: your host's git config) |

## Monitoring a Run

```bash
# Tail the logs (Ctrl+C to detach — container keeps running)
docker logs -f liutaio-my-branch

# Shell into the running container
docker exec -it liutaio-my-branch bash

# Check progress on your host (updated after each ticket)
cat path/to/agent-dir/progress.md

# Stop gracefully (pushes work before exiting)
docker stop liutaio-my-branch

# Force remove
docker rm -f liutaio-my-branch
```

## Troubleshooting

### "Not logged in" after container starts

Your access token expired during dependency installation. This usually resolves itself — the token refresh runs before each iteration. If it persists, try `--oauth` for an independent OAuth session that doesn't share tokens with your host.

### Container gets killed mid-session

Likely an out-of-memory kill. Check with:

```bash
docker inspect liutaio-my-branch --format='{{.State.OOMKilled}}'
```

The default memory limit is 16GB. If your test suite needs more, edit `--memory=16g` in `run.sh`.

### SSH push failures

Make sure your SSH keys are in `~/.ssh/` and can push to your remote. If you use SSH host aliases (e.g. `github-work` instead of `github.com`), Liutaio copies your `~/.ssh/config` into the container and resolves them automatically.

### OAuth login shows "Invalid OAuth Request"

Check that you're copying the entire code from the callback page (including any `#` in the middle). The format is `{code}#{state}` — both parts are needed.

### OAuth login suddenly stops working

Liutaio uses Claude Code's public OAuth client ID to authenticate. If Anthropic rotates this ID in a future update, OAuth login will fail. You can override it by passing the new client ID:

```bash
liutaio agent.md 10 my-branch --env LIUTAIO_OAUTH_CLIENT_ID=new-client-id-here
```

You can find the current client ID by running `claude auth login` on your host and inspecting the authorization URL it generates.

### Loop doesn't stop after all work is done

The loop looks for `<promise>COMPLETE</promise>` in the session output. Make sure your agent.md instructs Claude to output this exact string when finished.

## License

MIT
