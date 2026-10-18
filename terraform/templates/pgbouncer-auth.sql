-- PgBouncer's credential lookup (ADR 0005). PgBouncer authenticates every
-- client by running auth_query as the pgbouncer_auth role, so no application
-- role or password is listed in its configuration. The function is the only
-- thing that role may run; it reads pg_shadow with the definer's rights.
CREATE SCHEMA IF NOT EXISTS pgbouncer;
REVOKE ALL ON SCHEMA pgbouncer FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
RETURNS TABLE (usename name, passwd text)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS
$$ SELECT usename, passwd FROM pg_catalog.pg_shadow WHERE usename = p_usename $$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer_auth;
GRANT CONNECT ON DATABASE postgres TO pgbouncer_auth;
