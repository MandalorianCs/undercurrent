-- Заглушка платформенных объектов Supabase для локального Postgres.
--
-- Это НЕ часть продакшн-схемы: на реальном проекте всё, что здесь
-- создаётся, уже существует до того, как вы открываете SQL Editor. Файл
-- нужен затем, чтобы миграции можно было прогнать на голом postgres:16
-- и увидеть настоящие ошибки в своих политиках, а не в отсутствии
-- auth.uid().
--
-- Что подделываем:
--   • схема auth + таблица auth.users
--   • auth.uid() / auth.role() / auth.jwt() — дословно как у Supabase
--   • auth.email() — его читает issue_access_grant
--   • роли anon/authenticated/service_role и default privileges
--
-- Чего заглушка НЕ проверяет (только живой проект):
--   • реальную выдачу JWT и claim is_anonymous от Supabase Auth
--   • PostgREST, rate limits, доставку письма с кодом подтверждения

-- ── Роли ──────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;

-- Supabase настраивает это при создании проекта. Без этих строк тесты RLS
-- падают на «permission denied for table», и легко решить, что виноваты
-- политики, хотя виноваты гранты.
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- ── Схема auth ────────────────────────────────────────────────

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text unique,
  email_confirmed_at timestamptz,
  -- Ключевое поле для этого продукта: анонимный вход Supabase помечает
  -- пользователя именно так, и от этого признака зависит, пустят ли
  -- сессию привязывать билет.
  is_anonymous       boolean not null default false,
  raw_user_meta_data jsonb not null default '{}',
  created_at         timestamptz not null default now()
);

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;

-- У Supabase auth.email() читает claim, а не таблицу. Повторяем это
-- буквально: если бы заглушка ходила в auth.users, тест проходил бы там,
-- где на живом проекте функция вернула бы null.
create or replace function auth.email() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.email', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
  )::text
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt(), auth.email()
  to anon, authenticated, service_role;
