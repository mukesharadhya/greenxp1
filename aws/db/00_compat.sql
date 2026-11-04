-- Stand-ins for the parts of Supabase the GreenXP schema relies on: the "authenticated" role used by
-- row-level security, auth.users (one row per Cognito account) and auth.uid().
-- The API runs each signed-in request as role "authenticated" with request.jwt.claim.sub set to the
-- user's id, so the policies and functions carried over from Supabase work unchanged.
create extension if not exists pgcrypto;

do $$ begin
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin noinherit; end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin noinherit; end if;
end $$;
-- Lets the API's database user switch to these roles for a request.
grant anon, authenticated to current_user;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key,              -- the profile id; for accounts moved from Supabase it is their old id
  cognito_sub text unique,          -- the Cognito user this row belongs to
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

grant usage on schema auth to anon, authenticated;
grant execute on function auth.uid() to anon, authenticated;
