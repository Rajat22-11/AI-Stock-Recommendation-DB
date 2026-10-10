-- Public roles read the tracker; only privileged roles (Supabase MCP / postgres) write it.
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate on tables from anon, authenticated;;
