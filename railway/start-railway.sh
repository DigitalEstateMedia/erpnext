#!/bin/bash
set -e

# If running as root, fix volume ownership and re-exec as frappe.
# Railway mounts volumes as root; the image ENTRYPOINT (main-entrypoint.sh)
# creates the assets symlink as root (which works), then execs this script.
# We chown the sites volume and drop to frappe for all bench operations.
if [ "$(id -u)" = "0" ]; then
    chown -R frappe:frappe /home/frappe/frappe-bench/sites
    exec su -s /bin/bash frappe -p -c "exec /usr/local/bin/start-railway.sh"
fi

# --- now running as frappe ------------------------------------------------
: "${SITE_NAME:?SITE_NAME is required}"
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
: "${RAILWAY_PUBLIC_DOMAIN:?RAILWAY_PUBLIC_DOMAIN is required}"

# BENCH_DIR is overridable so the boot logic can be exercised by tests.
BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
cd "$BENCH_DIR"

DB_HOST=mariadb.railway.internal
DB_PORT=3306

mysql_root() {
    mysql -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" "$@"
}

# 1. Wait for MariaDB to be genuinely READY, not merely listening.
#
#    A TCP port check (wait-for-it) is not enough: MariaDB accepts connections
#    on 3306 before InnoDB recovery finishes, so a port probe returns success
#    while queries still fail. Upstream frappe_docker uses a healthcheck of
#    `--connect --innodb_initialized` for exactly this reason. Every decision
#    below depends on being able to trust a failed query, so this loop must
#    exhaust before anything reads the database.
DB_WAIT_ATTEMPTS="${DB_WAIT_ATTEMPTS:-60}"
DB_WAIT_SLEEP="${DB_WAIT_SLEEP:-3}"
echo "Waiting for MariaDB at $DB_HOST:$DB_PORT ..."
DB_READY=0
for i in $(seq 1 "$DB_WAIT_ATTEMPTS"); do
    if mysql_root -e "SELECT 1;" >/dev/null 2>&1; then
        DB_READY=1
        echo "MariaDB ready after ${i} attempt(s)."
        break
    fi
    sleep "$DB_WAIT_SLEEP"
done

if [ "$DB_READY" != "1" ]; then
    echo "FATAL: MariaDB not ready after $((DB_WAIT_ATTEMPTS * DB_WAIT_SLEEP))s. Refusing to continue." >&2
    echo "       Not creating or modifying any site — check the mariadb service." >&2
    exit 1
fi

# 2. App list consumed by Frappe during site creation
ls -1 apps > sites/apps.txt

# 2b. Ensure common_site_config.json exists (fresh volume has none)
if [ ! -f sites/common_site_config.json ]; then
    echo '{}' > sites/common_site_config.json
fi

# 3. Global bench config (db + redis wiring via Railway private DNS)
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-config -g redis_cache redis://redis-cache.railway.internal:6379
bench set-config -g redis_queue redis://redis-queue.railway.internal:6379
bench set-config -g redis_socketio redis://redis-queue.railway.internal:6379
bench set-config -gp socketio_port 9000

# 4. Create the site, or migrate the existing one.
#
#    This script NEVER drops a database. An earlier version recreated the site
#    whenever a single `SELECT 1` failed, which turned any transient MariaDB
#    hiccup (restart race, connection limit, network blip) into silent, total
#    loss of the ERP. Destroying business data must be a human decision, so a
#    missing database is a hard failure here, gated behind ALLOW_SITE_RECREATE.
if [ ! -d "sites/$SITE_NAME" ]; then
    echo "Site $SITE_NAME does not exist — creating."

    bench new-site "$SITE_NAME" \
        --db-root-username root \
        --db-root-password "$DB_ROOT_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --mariadb-user-host-login-scope=% \
        --install-app erpnext \
        --set-default
else
    SITE_CONFIG="sites/$SITE_NAME/site_config.json"
    SITE_DB=$(python3 -c "import json;print(json.load(open('$SITE_CONFIG')).get('db_name',''))" 2>/dev/null || echo "")

    if [ -z "$SITE_DB" ]; then
        echo "FATAL: $SITE_CONFIG is missing or has no db_name." >&2
        echo "       The site directory exists but is unusable. Refusing to guess." >&2
        exit 1
    fi

    # MariaDB is confirmed ready, so an absent database here is real, not a race.
    if ! mysql_root -N -e "SHOW DATABASES LIKE '$SITE_DB';" | grep -q "$SITE_DB"; then
        if [ "${ALLOW_SITE_RECREATE:-}" = "1" ]; then
            echo "WARNING: database $SITE_DB is gone and ALLOW_SITE_RECREATE=1 — recreating blank site."
            rm -rf "sites/$SITE_NAME"
            bench new-site "$SITE_NAME" \
                --db-root-username root \
                --db-root-password "$DB_ROOT_PASSWORD" \
                --admin-password "$ADMIN_PASSWORD" \
                --mariadb-user-host-login-scope=% \
                --install-app erpnext \
                --set-default
        else
            echo "FATAL: site $SITE_NAME exists but its database ($SITE_DB) does not." >&2
            echo "       Refusing to silently recreate and destroy any chance of recovery." >&2
            echo "       Restore from a backup, or set ALLOW_SITE_RECREATE=1 to start fresh." >&2
            exit 1
        fi
    else
        # Schema must catch up with the image's code on every boot, otherwise
        # bumping the frappe/erpnext tag runs new code against an old schema.
        echo "Site $SITE_NAME present — running migrate."
        bench --site "$SITE_NAME" migrate
    fi
fi

# 5. Idempotent per-boot settings. These run every time, not only at creation,
#    so attaching a custom domain updates host_name, and a scheduler that
#    Frappe auto-disabled after failures gets re-enabled.
bench --site "$SITE_NAME" set-config host_name "https://$RAILWAY_PUBLIC_DOMAIN"
bench --site "$SITE_NAME" scheduler enable

# Keep a bounded number of local backups (see backup.sh, run by supervisord).
bench --site "$SITE_NAME" set-config backup_limit "${BACKUP_LIMIT:-7}"

# 6. Hand off to supervisord (runs all seven programs)
exec supervisord -c "${SUPERVISORD_CONF:-/home/frappe/supervisord.conf}"
