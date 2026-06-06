# pgAudit

Custom DollarDeploy service that enables PostgreSQL auditing with
[pgAudit](https://github.com/pgaudit/pgaudit).

`prepare.sh` is run by the host's main `scripts/prepare.sh` via the `PREPARE_URL`
mechanism. It runs as a standalone script, so it is fully self-contained.

What it does:

1. Detects the PostgreSQL major version already installed on the host
   (`pg_lsclusters`).
2. Installs build dependencies and compiles pgAudit **from source** for that
   major version (`REL_<major>_STABLE`), then `make install`.
3. Adds `pgaudit` to `shared_preload_libraries` (preserving existing entries),
   applies the audit settings and restarts the matching cluster(s).
4. Runs `CREATE EXTENSION IF NOT EXISTS pgaudit` in the configured databases.

It is idempotent: if `pgaudit.so` is already installed the build is skipped
unless `POSTGRES_AUDIT_FORCE_INSTALL=1`.

## Settings (override via host/service env vars)

| Env var                      | Default                            | Description                                                           |
| ---------------------------- | ---------------------------------- | --------------------------------------------------------------------- |
| `POSTGRES_AUDIT_LOG`                | `ddl, write`                       | Audit classes: `read,write,function,role,ddl,misc,misc_set,all,none`. |
| `POSTGRES_AUDIT_LOG_CATALOG`        | `off`                              | Log statements against the system catalog.                            |
| `POSTGRES_AUDIT_LOG_PARAMETER`      | `off`                              | Include statement parameters in the log.                              |
| `POSTGRES_AUDIT_LOG_RELATION`       | `off`                              | Separate log entry per relation in a statement.                       |
| `POSTGRES_AUDIT_LOG_STATEMENT_ONCE` | `off`                              | Log statement text only once per session.                             |
| `POSTGRES_AUDIT_LOG_LEVEL`          | `log`                              | Log level for audit entries.                                          |
| `POSTGRES_AUDIT_DATABASES`          | `POSTGRES_DATABASES` or `postgres` | Databases to create the extension in.                                 |
| `POSTGRES_AUDIT_REF`                | `REL_<major>_STABLE`               | Pin a specific pgAudit branch/tag.                                    |
| `POSTGRES_AUDIT_FORCE_INSTALL`      | `0`                                | Force rebuild/reconfigure.                                            |

## Required app changes

This service relies on the new `custom` service type (`Service.customUrl`). For
it to work end-to-end the app must:

1. **Set `PREPARE_URL` from the custom service's `customUrl`** when building the
   prepare env in `lib/queue/prepareHost.ts` (so the main script downloads and
   runs this script). Today `PREPARE_URL` is never populated.
2. **Skip `install_/remove_` for `custom` services** in `scripts/prepare.sh`
   (the loops at the bottom call `install_$service`, which would `exit 1` for
   `custom`). Either exclude `custom` from `USER_SERVICES` when building it in
   `prepareHost.ts`, or add no-op `install_custom`/`remove_custom` functions.
3. **Support more than one custom service** if needed — `PREPARE_URL` is a single
   value, so multiple custom services would need a list (e.g. run each
   `customUrl` in turn).
