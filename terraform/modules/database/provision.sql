-- Idempotent role and database provisioning, run by modules/database as the
-- Postgres superuser against the `postgres` database. Re-running it converges:
-- the role exists, its password is the one Terraform holds, the database
-- exists and belongs to the role, and no other role can connect to it.
-- Inputs arrive through the environment (psql \getenv), so no password ever
-- appears on a command line.
\set ON_ERROR_STOP on
\getenv role DB_ROLE
\getenv db DB_NAME
\getenv pw DB_PASSWORD

SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw';

-- An empty DB_NAME provisions a role only (the PgBouncer lookup role).
SELECT :'db' <> '' AS has_db \gset
\if :has_db
SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L', :'db', :'role', 'UTF8')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
ALTER DATABASE :"db" OWNER TO :"role";
-- Strip the implicit PUBLIC grant so no other role can connect.
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db" TO :"role";
\endif
