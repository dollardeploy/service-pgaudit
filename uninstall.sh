#!/bin/bash
# pgAudit custom service for DollarDeploy - uninstall
#
# Reverses prepare.sh: drops the extension from the databases, removes pgaudit
# from shared_preload_libraries and the pgaudit.* settings, restarts the
# cluster(s) and removes the installed extension files.
#
# DollarDeploy runs this (when present) as the app user when the custom service
# is removed from the host. It is best-effort: it keeps going on errors so a
# single failing step does not leave the rest of the cleanup undone.

set -uo pipefail

# Which databases the extension was created in (mirror prepare.sh defaults).
POSTGRES_AUDIT_DATABASES="${POSTGRES_AUDIT_DATABASES:-${POSTGRES_DATABASES:-postgres}}"
# Also remove the compiled extension files from disk (pgaudit.so + control/sql).
POSTGRES_AUDIT_REMOVE_FILES="${POSTGRES_AUDIT_REMOVE_FILES:-1}"

# Privilege escalation, mirrors prepare.sh.
run="sudo"
runaspostgres="sudo -u postgres"
if [ "$(id -u)" -eq 0 ]; then
  run=""
  runaspostgres="su -s /bin/bash postgres -c"
fi

echo "pgAudit: starting uninstall"

if ! command -v pg_lsclusters >/dev/null 2>&1; then
  echo "pgAudit: pg_lsclusters not found, nothing to uninstall"
  exit 0
fi

PG_MAJOR="$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | sort -V | tail -n1)"
if [ -z "${PG_MAJOR}" ]; then
  echo "pgAudit: no PostgreSQL cluster detected, nothing to uninstall"
  exit 0
fi
PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"

# Remove a value from a comma separated postgresql.conf list, keeping the rest.
function remove_preload_library() {
  local conf="$1" lib="$2" current new
  current="$(grep -E "^[[:space:]]*shared_preload_libraries[[:space:]]*=" "${conf}" 2>/dev/null \
    | tail -n1 | sed -E "s/^[^=]*=[[:space:]]*//; s/#.*$//; s/['\"]//g; s/[[:space:]]//g" || true)"
  [ -z "${current}" ] && return
  new="$(printf '%s' "${current}" | tr ',' '\n' | grep -vx "${lib}" | paste -sd, -)"
  $run sed -i "s|^[[:space:]]*shared_preload_libraries[[:space:]]*=.*|shared_preload_libraries = '${new}'|" "${conf}"
  echo "pgAudit: shared_preload_libraries is now '${new}' in ${conf}"
}

pg_lsclusters -h 2>/dev/null | while read -r ver cluster port status _owner _datadir _logfile; do
  [ "${ver}" = "${PG_MAJOR}" ] || continue
  conf="/etc/postgresql/${ver}/${cluster}/postgresql.conf"
  [ -f "${conf}" ] || continue

  echo "pgAudit: cleaning cluster ${ver}/${cluster} (port ${port})"

  # Drop the extension from each database while the library is still loaded.
  IFS=', ' read -ra databases <<< "${POSTGRES_AUDIT_DATABASES}"
  for db in "${databases[@]}"; do
    [ -n "${db}" ] || continue
    echo "pgAudit: dropping extension in database '${db}'"
    if [ "$(id -u)" -eq 0 ]; then
      su -s /bin/bash postgres -c "psql -p ${port} -d ${db} -c 'DROP EXTENSION IF EXISTS pgaudit;'" || true
    else
      $runaspostgres psql -p "${port}" -d "${db}" -c "DROP EXTENSION IF EXISTS pgaudit;" || true
    fi
  done

  # Remove pgaudit from the preload list and delete all pgaudit.* settings.
  remove_preload_library "${conf}" "pgaudit"
  $run sed -i "/^[[:space:]]*pgaudit\./d" "${conf}"
  echo "pgAudit: removed pgaudit.* settings from ${conf}"

  echo "pgAudit: restarting cluster ${ver}/${cluster}"
  $run pg_ctlcluster --skip-systemctl-redirect "${ver}" "${cluster}" restart \
    || $run pg_ctlcluster "${ver}" "${cluster}" restart \
    || $run systemctl restart "postgresql@${ver}-${cluster}" \
    || echo "pgAudit: failed to restart cluster ${ver}/${cluster}, continuing"
done

# Remove the compiled extension files so it cannot be re-created accidentally.
if [ "${POSTGRES_AUDIT_REMOVE_FILES}" == "1" ] && [ -x "${PG_CONFIG}" ]; then
  PKGLIBDIR="$(${PG_CONFIG} --pkglibdir)"
  SHAREDIR="$(${PG_CONFIG} --sharedir)"
  echo "pgAudit: removing extension files"
  $run rm -f "${PKGLIBDIR}/pgaudit.so"
  $run rm -f "${SHAREDIR}/extension/pgaudit".control
  $run rm -f "${SHAREDIR}/extension/pgaudit"--*.sql
fi

echo "pgAudit: uninstall done"
