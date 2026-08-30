# ERPNext on Railway

Self-hosted [ERPNext](https://erpnext.com) v16.33.0 for internal use.

This directory holds the only Railway-specific code in the repo. Everything under
`erpnext/` is untouched upstream source, so version bumps rebase cleanly.

## Why this directory exists

ERPNext is not one process. Upstream's stack is six containers — backend (gunicorn),
frontend (nginx), websocket (socket.io), queue-short, queue-long, scheduler — and
all six mount the same `sites` volume. That volume holds `common_site_config.json`,
the site database credentials, uploaded files, and the built assets nginx serves.

Railway volumes cannot be shared between services. So instead of the one-service-per-
container layout, all six Frappe processes run in ONE Railway service under supervisord,
with one volume. MariaDB and Redis stay separate services (they don't touch the sites
volume). This is also what Railway's own community ERPNext template does.

## Service map

| Service | Source | Port | Volume | Notes |
|---|---|---|---|---|
| `mariadb` | `mariadb:11.8` | 3306 | `/var/lib/mysql` | charset utf8mb4 |
| `redis-cache` | `redis:8-alpine` | 6379 | — | unauthenticated, private network |
| `redis-queue` | `redis:8-alpine` | 6379 | — | unauthenticated, private network |
| `erpnext` | this repo, root `railway/` | **8080** | `/home/frappe/frappe-bench/sites` | **the only public service** |

Inside `erpnext`, supervisord runs six programs:

| Program | Command |
|---|---|
| `nginx` | `/usr/local/bin/nginx-entrypoint.sh` → listens **8080** |
| `gunicorn` | `/usr/local/bin/start.sh` → `0.0.0.0:8000` |
| `socketio` | `node apps/frappe/socketio.js` → `127.0.0.1:9000` |
| `scheduler` | `bench schedule` |
| `worker-short` | `bench worker --queue short,default` |
| `worker-long` | `bench worker --queue long,default,short` |

`PORT` is pinned to 8080 on the erpnext service. nginx listens on 8080 hardcoded
in the upstream nginx-template.conf — leaving it to chance is how this stack
silently 502s.

`FRAPPE_SITE_NAME_HEADER` is set to the literal site name, not the default `$host`.
This means the Railway domain AND any custom domain added later both resolve to the
one site, with no site rename. This is the single most common way ERPNext-on-PaaS
deploys break.

## Deviations from upstream

- **Single container, not six.** Upstream runs six containers sharing one sites
  volume via Docker Compose. Railway volumes can't be shared between services, so
  all six processes run under supervisord in one service with one volume.
- **No `configurator` or `create-site` services.** Railway has no one-shot primitive,
  so these fold into `start-railway.sh` — the boot script creates the site on first
  boot and migrates on subsequent boots.
- **MariaDB is a plain image, not managed.** Railway has no managed MariaDB. The
  image runs with three charset flags required by Frappe.

## Rebuilding from scratch

`provision.py` is the record of how this deployment was built, and the way to
rebuild it (new project, new environment, disaster recovery). It creates services,
so point it at a NEW project — it is not a repeated sync.

```bash
railway init -n erpnext
python3 railway/provision.py
```

Secrets are generated into `railway/.env.local` (gitignored, mode 600) on first run
and reused after. They also live in Railway; this file is just the local copy.

The script works around three Railway quirks, all documented in its docstring:
`railway volume add -s` panics (link the service first), the CLI's GitHub repo list
is cached so a freshly created repo reads as "not found" (the API sees it), and
start commands and root directories are API-only — there is no `DOCKERFILE` builder
enum, Railway auto-detects a Dockerfile inside `rootDirectory`.

## First run

The first boot takes **3–5 minutes**: `bench new-site` creates the database and
installs ERPNext before supervisord starts, so the service isn't listening until it
finishes. No Railway healthcheck is configured, deliberately — one would kill the
deploy mid-install.

After the stack is up:

1. Visit `https://<domain>/app`
2. Log in as `Administrator` with the generated password (in `railway/.env.local`)
3. Complete the setup wizard

## Upgrading

```bash
git fetch upstream --tags
git rebase v16.x.y          # or whichever release
```

Then bump the image tag in `railway/Dockerfile` from `v16.33.0` to the new tag,
and redeploy. The boot script's `migrate` branch handles schema updates automatically.
Check upstream's release notes for new required env vars before doing so.

## Known gaps

- **No SMTP.** Password reset and invite emails won't send until mail settings are
  added in-app. Admin login works without it.
- **No automated backups.** The MariaDB volume is the only copy. Worth adding
  upstream's `compose.backup-cron.yaml` equivalent before this holds real business data.
- **Fork app code doesn't run.** The container is the official image; edits to the
  fork's Python/JS ship only after switching to a full `frappe_docker` build. The
  fork is the home for Railway config and the record of the deploy.
