# pgAudit

Custom DollarDeploy service that enables PostgreSQL auditing with
[pgAudit](https://github.com/pgaudit/pgaudit).

DollarDeploy clones this repo to `$APPDIR/services/<name>` and runs its
`prepare.sh` during the host's prepare run. The script is self-contained.

## Install

1. Open the app and go to your **Host**.
2. Open the **Services** tab.
3. Click **Add service** and choose **Custom**.
4. Paste the repo URL: `https://github.com/dollardeploy/service-pgaudit/`
5. Save, then **Prepare** the host. DollarDeploy clones the repo and runs
   `prepare.sh`, which builds and enables pgAudit on the host's PostgreSQL.

> Requires a PostgreSQL service already on the host — pgAudit attaches to the
> existing cluster. Tweak behaviour with the env vars below (set them as host or
> service env vars).

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

| Env var                             | Default                            | Description                                                           |
| ----------------------------------- | ---------------------------------- | --------------------------------------------------------------------- |
| `POSTGRES_AUDIT_LOG`                | `ddl, write`                       | Audit classes: `read,write,function,role,ddl,misc,misc_set,all,none`. |
| `POSTGRES_AUDIT_LOG_CATALOG`        | `off`                              | Log statements against the system catalog.                            |
| `POSTGRES_AUDIT_LOG_PARAMETER`      | `off`                              | Include statement parameters in the log.                              |
| `POSTGRES_AUDIT_LOG_RELATION`       | `off`                              | Separate log entry per relation in a statement.                       |
| `POSTGRES_AUDIT_LOG_STATEMENT_ONCE` | `off`                              | Log statement text only once per session.                             |
| `POSTGRES_AUDIT_LOG_LEVEL`          | `log`                              | Log level for audit entries (only applies when `log_client` is on).   |
| `POSTGRES_AUDIT_LOG_CLIENT`         | `off`                              | Also send audit records to the connected client (e.g. psql).          |
| `POSTGRES_AUDIT_LOG_LINE_PREFIX`    | `%m %u %d [%p]: `                  | Postgres `log_line_prefix`; set empty to keep the cluster default.    |
| `POSTGRES_AUDIT_DATABASES`          | `POSTGRES_DATABASES` or `postgres` | Databases to create the extension in.                                 |
| `POSTGRES_AUDIT_REF`                | `REL_<major>_STABLE`               | Pin a specific pgAudit branch/tag.                                    |
| `POSTGRES_AUDIT_FORCE_INSTALL`      | `0`                                | Force rebuild/reconfigure.                                            |

## Where do the audit logs go?

pgAudit does **not** write its own files — it emits records to PostgreSQL's
standard logging facility, so they follow Postgres's `log_destination` /
`logging_collector` / `log_line_prefix` settings. On the Debian/Ubuntu clusters
DollarDeploy provisions, `pg_ctlcluster` redirects stderr to
`/var/log/postgresql/postgresql-<ver>-<cluster>.log`, so audit entries land there
out of the box (the script prints the exact path it detects). To collect them
elsewhere, configure Postgres logging (e.g. `logging_collector`, `csvlog`/
`jsonlog`) or ship that log file with your log agent.
