# ADR 0005: Application roles and databases are provisioned by Jobs, and the platform names no application

## Status

Accepted (2026-10-18). Implements [ADR 0002](0002-application-delivery-boundary.md)
D4 (phase 4) and decides the mechanism that ADR left open. Ends consequence 4
of [ADR 0004](0004-one-application-registry.md), the platform's reading of
application passwords by literal key.

## Context

Two platform files name every application:

- The Postgres release runs `templates/init-databases.sql.tftpl` through
  `primary.initdb.scripts`. It creates each application's role and database
  with the generated password in the script.
- PgBouncer lists every OLTP database in `[databases]` and every role and
  password in `userlist.txt`.

This has four costs, all seen on this cluster:

1. **initdb runs once, on an empty volume.** A new application needs
   hand-written `CREATE ROLE` and `CREATE DATABASE` on the live database
   (`README.md`, the `add-or-change-a-service` skill), and forgetting it
   crash-loops the pod with `password authentication failed`.
2. **Postgres keeps old passwords.** A plan that replaces a generated
   password (an older checkout, a refactor) updates the Secret but not the
   role, so every login fails. ADR 0004 records this as a hazard of any apply
   from a stale checkout.
3. **The platform cannot be planned without the applications.** Postgres and
   PgBouncer read 28 passwords from `module.application`, which ADR 0002 D6
   names as the reason the state split cannot happen yet.
4. **Passwords are printed in the Postgres release diff.**

ADR 0002 D4 says role and database creation moves "to the application layer"
and leaves the mechanism to this ADR.

## Decision

1. **A Kubernetes Job runs the SQL inside the cluster.** `modules/database`
   creates one role and, optionally, the database it owns:
   - It runs `psql` from the Postgres image as the superuser. The password
     comes from the chart's Secret through `secretKeyRef`.
   - The SQL (`modules/database/provision.sql`) is idempotent. It creates what
     is missing and converges what exists: the role has the password Terraform
     holds, the database belongs to the role, and `PUBLIC` cannot connect to
     it. Inputs arrive through environment variables (`\getenv`), so no
     password is on a command line.
   - The SQL and the role's password sit in one Secret in the data namespace,
     mounted into the Job. They do not go in `command` or `env`, because the
     kubelet expands `$(VAR)` and turns `$$` into `$` in both, which breaks
     dollar-quoted function bodies.
   - Terraform waits for the Job (`wait_for_completion`). The Job is replaced
     whenever its Secret changes (`replace_triggered_by`), so a new password
     re-runs the script.
2. **The application layer calls it.** `modules/application` runs the module
   once for the OLTP role and once for the analytics role, with the password
   it already generates, and the `Application` waits for both. A fresh
   cluster no longer starts pods before their role exists.
3. **The platform publishes one object.** `local.postgres` holds the host,
   port, namespace, the superuser Secret's name and key, and the image. It
   replaces every platform-to-application reference. Under ADR 0003 it
   becomes an output of `10-platform` read through `terraform_remote_state`.
4. **PgBouncer authenticates through `auth_query`.**
   - `[databases]` has one `*` fallback entry; `userlist.txt` holds the
     superuser and the lookup role `pgbouncer_auth`, nothing else.
   - `pgbouncer_auth` is created by the same module (role only). It may run
     one function, `pgbouncer.get_auth()` in the `postgres` database
     (`templates/pgbouncer-auth.sql`), which reads `pg_shadow` with the
     definer's rights. `auth_dbname = postgres` points the query there.
   - The `*` entry lets a client name any database. Postgres' `CONNECT`
     privilege is still the access control, as it is for a direct connection:
     each application database is closed to every role but its owner.
5. **Removing an application does not drop its data.** Destroying the module
   removes the Job and the Secret, not the role or the database. Dropping
   them is an operator action.
6. **The Postgres release loses its initdb scripts.** The first apply
   restarts the Postgres pod once, because the init-scripts volume leaves the
   StatefulSet. The data is on the PVC.

The mechanism was tried before it was written into the repo: on a throwaway
Postgres and PgBouncer, the script created a role and database, a second run
changed nothing, a changed password reached Postgres and the old one stopped
working, and a client authenticated through PgBouncer with no entry for it.
A first version that updated the Job in place left the old password active;
`replace_triggered_by` fixed it.

## Consequences

Positive:

- Registering an application is one registry entry and one values file. No
  SQL, on an empty cluster or a populated one.
- The platform (`postgres.tf`, `pgbouncer.tf`) references no application.
  ADR 0002 D6 can split `10-platform` from `20-apps`.
- Postgres can no longer hold a password other than the one Terraform holds.
  The lock-out hazard from a stale checkout ends: the same apply that
  replaces a password sets it on the role.
- Passwords leave the Postgres release diff and the PgBouncer userlist.

Negative:

- 29 more Jobs and Secrets in the data namespace (14 OLTP roles, 14 analytics
  roles, one lookup role). Completed Jobs stay, because Terraform tracks them.
- Application pods that already run keep the old password until they
  restart, as before; only the role is now in step.
- A failed Job fails the apply after six retries. That is visible, and it
  replaces a silent crash loop.
- PgBouncer reads Postgres for each new client's credentials. A pooled
  connection needed Postgres anyway.
- The first apply on the live cluster restarts Postgres and PgBouncer once.

## Alternatives considered

- **The `postgresql` Terraform provider through a host port.** It needs a
  Postgres port on the host: a kind `extraPortMappings` entry (a cluster
  recreate) or a `kubectl port-forward` the apply must start. The provider
  connects during plan, so a plan fails while Postgres is down, and it is
  configured from a resource in the same state, which is the pattern
  ADR 0002 moves away from. It would also make `20-apps` depend on a host
  port.
- **CloudNativePG now.** It declares roles (`Cluster.spec.managed.roles`,
  and a `DatabaseRole` resource merged upstream in
  [cloudnative-pg#6155](https://github.com/cloudnative-pg/cloudnative-pg/commit/17311c2b135b69a4d56405d04c678a6d6489d7c3))
  and databases (`Database`). It is the better long-term home and also
  retires the `bitnamilegacy` Postgres image. It replaces the database
  engine, which is a separate change; whether `DatabaseRole` is in a release
  must be checked when it is adopted. Then `modules/database` changes to
  render those objects, with the same inputs, and no caller changes.
- **Jobs or hooks rendered by each chart.** The superuser credential would
  have to reach the application namespace, and every chart in every repo
  would change. Roles and passwords are the platform contract (ADR 0002 D1),
  and the password is Terraform's.
- **`null_resource` with `kubectl exec psql`.** Imperative, and it reruns
  only when its triggers change: the failure mode ADR 0002 gives for
  `local-exec`.
- **Keep initdb and the manual SQL.** The status quo, and the four costs
  above.
