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
| `backup` | `/usr/local/bin/backup.sh` → daily `bench backup --with-files` |

`PORT` is pinned to 8080 on the erpnext service. nginx listens on 8080 hardcoded
in the upstream nginx-template.conf — leaving it to chance is how this stack
silently 502s.

`FRAPPE_SITE_NAME_HEADER` is set to the literal site name, not the default `$host`.
This means the Railway domain AND any custom domain added later both resolve to the
one site, with no site rename. This is the single most common way ERPNext-on-PaaS
deploys break.

## The boot script never destroys data

`start-railway.sh` waits for MariaDB to be genuinely ready — it polls `SELECT 1`
rather than probing the TCP port, because MariaDB accepts connections on 3306
before InnoDB recovery finishes. Every decision after that depends on being able
to trust a failed query.

With that established, the rules are:

- site directory absent → create the site
- site directory present → `bench migrate`, every boot, so bumping the image tag
  never runs new code against an old schema
- site present but its database genuinely missing → **exit non-zero and stop**

That last case used to `DROP DATABASE` and recreate a blank site whenever a single
`SELECT 1` failed, which turned any transient MariaDB hiccup into silent, total loss
of the ERP. Destroying business data is now a human decision: set
`ALLOW_SITE_RECREATE=1` on the service to opt in, and unset it afterwards.

## Inspecting a running container

```bash
railway ssh -s erpnext
supervisorctl -c /home/frappe/supervisord.conf status
supervisorctl -c /home/frappe/supervisord.conf restart scheduler
```

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
- **Backups are on-volume only.** The `backup` program takes a daily
  `bench backup --with-files`, retained per the site's `backup_limit` (default 7).
  That covers a bad migration or an accidental delete. It does **not** cover loss of
  the volume itself — for that the archive has to leave the box. `restic` is already
  in the base image for that leg; it needs object-storage credentials to enable.
- **Fork app code doesn't run.** The container is the official image; edits to the
  fork's Python/JS ship only after switching to a full `frappe_docker` build. The
  fork is the home for Railway config and the record of the deploy.
