# valentinvera-reviewer

GitHub App para revisar pull requests.

## Stack

Bun · `Bun.serve()` · SQLite (`bun:sqlite`) · `@octokit/app` · `@octokit/webhooks` · Vercel AI SDK Core · OpenCode Go (`deepseek-v4.1-flash`).

## Env

```bash
PORT=3000
HOST=0.0.0.0
PUBLIC_URL=https://api.valentinvera.dev
DATABASE_PATH=./data/reviewer.db
LOG_LEVEL=info

GITHUB_APP_ID=
GITHUB_PRIVATE_KEY_PATH=./secrets/valentinvera-reviewer.pem
GITHUB_WEBHOOK_SECRET=
# GITHUB_TOKEN= # solo para review:dry-run

OPENCODE_API_KEY=
AI_MODEL=deepseek-v4.1-flash
AI_REASONING_MODE=off

REVIEW_LANGUAGE=es
REVIEW_MAX_DIFF_CHARS=240000
REVIEW_MAX_FINDINGS=12
REVIEW_CHUNK_CHARS=16000

QUEUE_POLL_MS=1000
JOB_MAX_ATTEMPTS=3
WORKER_CONCURRENCY=1
WORKER_ENABLED=true # false en instancias web-only
```

Defaults: `GITHUB_API_URL=https://api.github.com` y
`AI_BASE_URL=https://opencode.ai/inference/go/openai/v1`.

## Comandos

```bash
bun run dev         # watch
bun run start       # producción
bun run check       # typecheck + lint + format
bun run test        # tests
bun run queue:demo  # encola un job de prueba
bun run backup:db   # snapshot en ./backups (BACKUP_DIR, BACKUP_KEEP)
bun run review:dry-run <owner/repo> <pr> # review sin publicar
```

- Hooks: `bun install` instala lefthook (pre-commit + commit-msg).
- Migraciones: `src/db/migrations/*.sql` se aplican al bootear.
- Backups: retiene 7 por defecto.
- Multi-instancia: SQLite en el mismo host; para varios hosts, DB compartida.

## Deploy

Push a `main` (directo o merge de un PR) o `workflow_dispatch`
(`.github/workflows/deploy.yml`):

1. `bun run check` y `bun test`.
2. Imagen `linux/amd64` en GHCR: `ghcr.io/valentinvera/valentinvera-reviewer:<sha>` y `:latest`.
3. Tailscale efímero (`tag:ci`) y `ssh deploy@$DEPLOY_HOST "valentinvera-reviewer <sha>"`.
4. El server hace pull, `docker compose up -d --wait` y vuelve al tag anterior si el healthcheck falla.

```bash
# secrets
DEPLOY_SSH_KEY=       # ed25519 del usuario deploy
TS_OAUTH_CLIENT_ID=   # OAuth de Tailscale, nodos efímeros con tag:ci
TS_OAUTH_SECRET=

# variables
DEPLOY_HOST=valen-ubuntu-server
DEPLOY_KNOWN_HOSTS=   # línea de known_hosts, StrictHostKeyChecking=yes
```

- Environment del job: `production`.
- El tag es el SHA completo del commit.
