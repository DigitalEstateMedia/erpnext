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

cd /home/frappe/frappe-bench

# 1. Wait for MariaDB
wait-for-it mariadb.railway.internal:3306 -t 120

# 2. App list consumed by Frappe during site creation
ls -1 apps > sites/apps.txt

# 2b. Ensure common_site_config.json exists (fresh volume has none)
if [ ! -f sites/common_site_config.json ]; then
    echo '{}' > sites/common_site_config.json
fi

# 3. Global bench config (db + redis wiring via Railway private DNS)
bench set-config -g db_host mariadb.railway.internal
bench set-config -g db_port 3306
bench set-config -g redis_cache redis://redis-cache.railway.internal:6379
bench set-config -g redis_queue redis://redis-queue.railway.internal:6379
bench set-config -g redis_socketio redis://redis-queue.railway.internal:6379
bench set-config -gp socketio_port 9000

# 4. Create or recover the site.
#    On a fresh volume, create it. On a subsequent boot, verify the DB
#    connection works — if it doesn't (e.g. MariaDB volume was wiped),
#    drop the stale site directory and recreate.
if [ ! -d "sites/$SITE_NAME" ]; then
    echo "Site $SITE_NAME does not exist — creating."
    CREATE_SITE=1
else
    # Read db_name directly from site_config.json (bench get-config needs DB access)
    SITE_CONFIG="sites/$SITE_NAME/site_config.json"
    SITE_DB=$(python3 -c "import json; print(json.load(open('$SITE_CONFIG')).get('db_name',''))" 2>/dev/null || echo "")
    if [ -n "$SITE_DB" ]; then
        if mysql -h mariadb.railway.internal -P 3306 -u root -p"$DB_ROOT_PASSWORD" \
            -e "USE \`$SITE_DB\`; SELECT 1;" 2>/dev/null; then
            echo "Site $SITE_NAME DB connection OK — skipping recreation."
            CREATE_SITE=0
        else
            echo "Site $SITE_NAME DB connection failed — recreating site."
            rm -rf "sites/$SITE_NAME"
            CREATE_SITE=1
        fi
    else
        echo "Could not read site config — recreating site."
        rm -rf "sites/$SITE_NAME"
        CREATE_SITE=1
    fi
fi

if [ "$CREATE_SITE" = "1" ]; then
    # Drop any stale database from a previous incarnation
    SITE_DB="_$(echo -n "$SITE_NAME" | md5sum | cut -c1-15)"
    mysql -h mariadb.railway.internal -P 3306 -u root -p"$DB_ROOT_PASSWORD" \
        -e "DROP DATABASE IF EXISTS \`$SITE_DB\`;" 2>/dev/null || true

    bench new-site "$SITE_NAME" \
        --db-root-username root \
        --db-root-password "$DB_ROOT_PASSWORD" \
        --admin-password "$ADMIN_PASSWORD" \
        --install-app erpnext \
        --set-default

    # 5. Public host name (emailed links and portal URLs are absolute-correct)
    bench --site "$SITE_NAME" set-config host_name "https://$RAILWAY_PUBLIC_DOMAIN"

    # 6. Enable scheduler
    bench --site "$SITE_NAME" scheduler enable
fi

# 7. Hand off to supervisord (runs all six processes)
exec supervisord -c /home/frappe/supervisord.conf
