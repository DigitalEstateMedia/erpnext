#!/bin/bash
# Regression test for start-railway.sh's site decision logic.
#
# The bug this exists to prevent: an earlier version ran DROP DATABASE and
# rm -rf on the site directory whenever a single `SELECT 1` failed, so any
# transient MariaDB unavailability silently destroyed the ERP. Case 3 below is
# that exact scenario and must never end in a destructive call again.
#
# Run:  ./test_start_railway.sh
# No framework, no fixtures — stubs mysql/bench/supervisord on PATH and asserts
# on what the script tried to do.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/start-railway.sh"
PASS=0
FAIL=0

setup() {
    ROOT=$(mktemp -d)
    BENCH="$ROOT/bench"
    mkdir -p "$BENCH/apps/frappe" "$BENCH/sites" "$ROOT/bin"
    CALLS="$ROOT/calls.log"
    : > "$CALLS"

    # --- stubs -------------------------------------------------------------
    # mysql: MYSQL_UP controls readiness; DB_EXISTS controls SHOW DATABASES.
    cat > "$ROOT/bin/mysql" <<'STUB'
#!/bin/bash
echo "mysql $*" >> "$CALLS"
[ "${MYSQL_UP:-1}" = "1" ] || exit 1
for a in "$@"; do
  case "$a" in
    *"SHOW DATABASES"*) [ "${DB_EXISTS:-1}" = "1" ] && echo "${SITE_DB_NAME}"; exit 0 ;;
  esac
done
exit 0
STUB
    cat > "$ROOT/bin/bench" <<'STUB'
#!/bin/bash
echo "bench $*" >> "$CALLS"
exit 0
STUB
    cat > "$ROOT/bin/supervisord" <<'STUB'
#!/bin/bash
echo "supervisord $*" >> "$CALLS"
exit 0
STUB
    chmod +x "$ROOT/bin"/*
    export CALLS
    export PATH="$ROOT/bin:$PATH"
    export BENCH_DIR="$BENCH" SUPERVISORD_CONF="$ROOT/supervisord.conf"
    export SITE_NAME=test.local DB_ROOT_PASSWORD=pw ADMIN_PASSWORD=pw
    export RAILWAY_PUBLIC_DOMAIN=example.up.railway.app
    export SITE_DB_NAME=_abc123
    unset ALLOW_SITE_RECREATE
}

make_site() {
    mkdir -p "$BENCH/sites/$SITE_NAME"
    echo "{\"db_name\": \"$SITE_DB_NAME\"}" > "$BENCH/sites/$SITE_NAME/site_config.json"
}

run() { ( cd "$BENCH" && bash "$SCRIPT" >"$ROOT/out.log" 2>&1 ); echo $?; }

check() { # name, condition-result(0/1), detail
    if [ "$2" = "0" ]; then PASS=$((PASS+1)); echo "  ok   - $1"
    else FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${3:-}" ] && echo "         $3"; fi
}

no_destruction() {
    ! grep -qiE "DROP DATABASE|DROP USER" "$CALLS" && [ -d "$BENCH/sites/$SITE_NAME" ]
}

# --- case 1: fresh volume, no site -> create --------------------------------
echo "case 1: no site directory -> new-site"
setup
RC=$(BACKUP_LIMIT=7 run)
check "exits 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC"
check "runs new-site" "$(grep -q 'bench new-site' "$CALLS" && echo 0 || echo 1)"
check "does not migrate" "$(! grep -q 'bench --site test.local migrate' "$CALLS" && echo 0 || echo 1)"

# --- case 2: existing site + reachable DB -> migrate ------------------------
echo "case 2: site present, database present -> migrate"
setup; make_site
RC=$(run)
check "exits 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC"
check "runs migrate" "$(grep -q 'bench --site test.local migrate' "$CALLS" && echo 0 || echo 1)"
check "does NOT run new-site" "$(! grep -q 'bench new-site' "$CALLS" && echo 0 || echo 1)"
check "sets host_name every boot" "$(grep -q 'set-config host_name' "$CALLS" && echo 0 || echo 1)"
check "enables scheduler every boot" "$(grep -q 'scheduler enable' "$CALLS" && echo 0 || echo 1)"
check "hands off to supervisord" "$(grep -q 'supervisord' "$CALLS" && echo 0 || echo 1)"

# --- case 3: THE REGRESSION. DB unreachable -> refuse, destroy nothing ------
echo "case 3: database unreachable -> refuse, never destroy (the C1 regression)"
setup; make_site
RC=$(MYSQL_UP=0 DB_WAIT_ATTEMPTS=2 DB_WAIT_SLEEP=0 run)
check "exits non-zero" "$([ "$RC" != 0 ] && echo 0 || echo 1)" "rc=$RC"
check "NO DROP DATABASE/USER, site dir intact" "$(no_destruction && echo 0 || echo 1)" \
      "$(grep -iE 'DROP' "$CALLS" || true)"
check "does NOT run new-site" "$(! grep -q 'bench new-site' "$CALLS" && echo 0 || echo 1)"

# --- case 4: DB genuinely missing, no opt-in -> refuse ----------------------
echo "case 4: database genuinely gone, ALLOW_SITE_RECREATE unset -> refuse"
setup; make_site
RC=$(DB_EXISTS=0 run)
check "exits non-zero" "$([ "$RC" != 0 ] && echo 0 || echo 1)" "rc=$RC"
check "does NOT recreate" "$(! grep -q 'bench new-site' "$CALLS" && echo 0 || echo 1)"
check "site dir left for recovery" "$([ -d "$BENCH/sites/$SITE_NAME" ] && echo 0 || echo 1)"

# --- case 5: DB missing + explicit opt-in -> recreate -----------------------
echo "case 5: database gone, ALLOW_SITE_RECREATE=1 -> recreate"
setup; make_site
RC=$(DB_EXISTS=0 ALLOW_SITE_RECREATE=1 run)
check "exits 0" "$([ "$RC" = 0 ] && echo 0 || echo 1)" "rc=$RC"
check "runs new-site" "$(grep -q 'bench new-site' "$CALLS" && echo 0 || echo 1)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ] || exit 1
