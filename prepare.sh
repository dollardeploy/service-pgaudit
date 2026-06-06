#!/bin/bash
# pgAudit custom service for DollarDeploy
# https://github.com/pgaudit/pgaudit
#
# Installs the pgAudit extension *from source* for the PostgreSQL that the main
# host preparation already installed (see scripts/prepare.sh -> install_postgres),
# enables it through shared_preload_libraries, applies (overridable) audit
# settings and creates the extension in the configured databases.
#
# It is fetched and executed by the main scripts/prepare.sh through the
# PREPARE_URL mechanism:
#
#   if [ -n "$PREPARE_URL" ]; then
#     curl -fsSL -o "$PREPARE_SCRIPT" "$PREPARE_URL"
#     bash "$PREPARE_SCRIPT"
#   fi
#
# Because it runs as a standalone `bash` process it does NOT share the helper
# functions ($run, conf_upsert, install_missing, ...) of the parent script, so
# everything it needs is (re)defined here. Environment variables exported by the
# parent script (the host/service env injected via #DEPLOYENV#) are inherited and
# used to override defaults below.

set -euo pipefail

# --- Overridable settings (set as host/service env vars) --------------------
# Audit classes to log, comma separated. Valid: read, write, function, role,
# ddl, misc, misc_set, all, none. See the pgAudit README for details.
POSTGRES_AUDIT_LOG="${POSTGRES_AUDIT_LOG:-ddl, write}"
POSTGRES_AUDIT_LOG_CATALOG="${POSTGRES_AUDIT_LOG_CATALOG:-off}"
POSTGRES_AUDIT_LOG_PARAMETER="${POSTGRES_AUDIT_LOG_PARAMETER:-off}"
POSTGRES_AUDIT_LOG_RELATION="${POSTGRES_AUDIT_LOG_RELATION:-off}"
POSTGRES_AUDIT_LOG_STATEMENT_ONCE="${POSTGRES_AUDIT_LOG_STATEMENT_ONCE:-off}"
POSTGRES_AUDIT_LOG_LEVEL="${POSTGRES_AUDIT_LOG_LEVEL:-log}"
# Databases to CREATE EXTENSION pgaudit in. Defaults to the databases the
# postgres service was configured with, falling back to "postgres".
POSTGRES_AUDIT_DATABASES="${POSTGRES_AUDIT_DATABASES:-${POSTGRES_DATABASES:-postgres}}"
# Pin a specific pgAudit git ref (branch or tag). Auto-detected per PostgreSQL
# major version when empty (REL_<major>_STABLE).
POSTGRES_AUDIT_REF="${POSTGRES_AUDIT_REF:-}"
# Rebuild / reconfigure even if pgAudit is already installed.
POSTGRES_AUDIT_FORCE_INSTALL="${POSTGRES_AUDIT_FORCE_INSTALL:-0}"
# ---------------------------------------------------------------------------

# Privilege escalation, mirrors the parent script.
run="sudo"
runaspostgres="sudo -u postgres"
if [ "$(id -u)" -eq 0 ]; then
  run=""
  runaspostgres="su -s /bin/bash postgres -c"
fi

echo "pgAudit: starting custom service preparation"

# --- Detect the installed PostgreSQL ---------------------------------------
if ! command -v pg_lsclusters >/dev/null 2>&1; then
  echo "pgAudit: pg_lsclusters not found, is the Postgres service enabled on this host?"
  exit 1
fi

# pg_lsclusters -h prints one cluster per line (no header):
#   Ver Cluster Port Status Owner Data-directory Log-file
# Pick the newest major version present.
PG_MAJOR="$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | sort -V | tail -n1)"
if [ -z "${PG_MAJOR}" ]; then
  echo "pgAudit: no PostgreSQL cluster detected, nothing to do"
  exit 1
fi
echo "pgAudit: detected PostgreSQL major version ${PG_MAJOR}"

PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"

# Default the pgAudit ref to the stable branch matching the server major.
if [ -z "${POSTGRES_AUDIT_REF}" ]; then
  POSTGRES_AUDIT_REF="REL_${PG_MAJOR}_STABLE"
fi

# --- Build & install pgAudit from source -----------------------------------
PKGLIBDIR=""
if [ -x "${PG_CONFIG}" ]; then
  PKGLIBDIR="$(${PG_CONFIG} --pkglibdir)"
fi

if [ "${POSTGRES_AUDIT_FORCE_INSTALL}" != "1" ] && [ -n "${PKGLIBDIR}" ] && [ -f "${PKGLIBDIR}/pgaudit.so" ]; then
  echo "pgAudit: pgaudit.so already installed in ${PKGLIBDIR}, skipping build"
else
  echo "pgAudit: installing build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  $run apt-get -o DPkg::Lock::Timeout=60 install -y \
    "postgresql-server-dev-${PG_MAJOR}" \
    build-essential git make gcc libssl-dev libkrb5-dev

  if [ ! -x "${PG_CONFIG}" ]; then
    # Fall back to whatever pg_config the dev package provided on PATH.
    PG_CONFIG="$(command -v pg_config)"
  fi
  if [ ! -x "${PG_CONFIG}" ]; then
    echo "pgAudit: pg_config not found after installing postgresql-server-dev-${PG_MAJOR}"
    exit 1
  fi

  BUILD_DIR="$(mktemp -d /tmp/pgaudit-XXXXXX)"
  trap 'rm -rf "${BUILD_DIR}"' EXIT
  echo "pgAudit: cloning pgaudit ${POSTGRES_AUDIT_REF}"
  git clone --depth 1 --branch "${POSTGRES_AUDIT_REF}" https://github.com/pgaudit/pgaudit.git "${BUILD_DIR}/pgaudit"

  echo "pgAudit: building against ${PG_CONFIG}"
  make -C "${BUILD_DIR}/pgaudit" USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"
  $run make -C "${BUILD_DIR}/pgaudit" install USE_PGXS=1 PG_CONFIG="${PG_CONFIG}"
  echo "pgAudit: installed pgaudit.so"
fi

# --- Enable & configure pgAudit in matching clusters -----------------------
# Append a value to a comma separated postgresql.conf list (e.g.
# shared_preload_libraries) without dropping libraries already configured.
function append_preload_library() {
  local conf="$1"
  local lib="$2"
  local current new

  current="$(grep -E "^[[:space:]]*shared_preload_libraries[[:space:]]*=" "${conf}" 2>/dev/null \
    | tail -n1 | sed -E "s/^[^=]*=[[:space:]]*//; s/#.*$//; s/['\"]//g; s/[[:space:]]//g" || true)"

  if [ -z "${current}" ]; then
    new="${lib}"
  elif printf ',%s,' "${current}" | grep -q ",${lib},"; then
    echo "pgAudit: ${lib} already present in shared_preload_libraries"
    return
  else
    new="${current},${lib}"
  fi
  conf_upsert "${conf}" "shared_preload_libraries" "'${new}'"
}

# Insert or update a "key = value" line in a postgresql.conf file.
function conf_upsert() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    $run sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  elif grep -qE "^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    $run sed -i "s|^[[:space:]]*#[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}"
  else
    echo "${key} = ${value}" | $run tee -a "${file}" >/dev/null
  fi
  echo "pgAudit: set ${key} = ${value} in ${file}"
}

# Only configure clusters whose major version matches the library we built.
pg_lsclusters -h 2>/dev/null | while read -r ver cluster port status _owner _datadir _rest; do
  [ "${ver}" = "${PG_MAJOR}" ] || continue
  conf="/etc/postgresql/${ver}/${cluster}/postgresql.conf"
  if [ ! -f "${conf}" ]; then
    echo "pgAudit: ${conf} not found, skipping cluster ${ver}/${cluster}"
    continue
  fi

  echo "pgAudit: configuring cluster ${ver}/${cluster} (port ${port})"
  append_preload_library "${conf}" "pgaudit"
  conf_upsert "${conf}" "pgaudit.log" "'${POSTGRES_AUDIT_LOG}'"
  conf_upsert "${conf}" "pgaudit.log_catalog" "${POSTGRES_AUDIT_LOG_CATALOG}"
  conf_upsert "${conf}" "pgaudit.log_parameter" "${POSTGRES_AUDIT_LOG_PARAMETER}"
  conf_upsert "${conf}" "pgaudit.log_relation" "${POSTGRES_AUDIT_LOG_RELATION}"
  conf_upsert "${conf}" "pgaudit.log_statement_once" "${POSTGRES_AUDIT_LOG_STATEMENT_ONCE}"
  conf_upsert "${conf}" "pgaudit.log_level" "${POSTGRES_AUDIT_LOG_LEVEL}"

  # shared_preload_libraries only takes effect after a restart.
  echo "pgAudit: restarting cluster ${ver}/${cluster}"
  $run pg_ctlcluster --skip-systemctl-redirect "${ver}" "${cluster}" restart \
    || $run pg_ctlcluster "${ver}" "${cluster}" restart \
    || $run systemctl restart "postgresql@${ver}-${cluster}"

  # Create the extension in each configured database.
  IFS=', ' read -ra databases <<< "${POSTGRES_AUDIT_DATABASES}"
  for db in "${databases[@]}"; do
    [ -n "${db}" ] || continue
    echo "pgAudit: creating extension in database '${db}'"
    if [ "$(id -u)" -eq 0 ]; then
      su -s /bin/bash postgres -c "psql -p ${port} -d ${db} -c 'CREATE EXTENSION IF NOT EXISTS pgaudit;'" || true
    else
      $runaspostgres psql -p "${port}" -d "${db}" -c "CREATE EXTENSION IF NOT EXISTS pgaudit;" || true
    fi
  done
done

# Record the installed pgAudit ref back into the service env and turn the force
# flag off so subsequent prepares are idempotent. These lines are picked up by
# the host output listener (see lib/queue/outputListener.ts).
echo "{{env:SERVICE_CUSTOM_POSTGRES_AUDIT_REF:${POSTGRES_AUDIT_REF}}}"
if [ "${POSTGRES_AUDIT_FORCE_INSTALL}" == "1" ]; then
  echo "{{env:POSTGRES_AUDIT_FORCE_INSTALL:0}}"
fi

echo "pgAudit: done"
