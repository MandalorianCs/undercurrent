-- Помощники для сценариев и общий посев данных.
--
-- Всё, что здесь создаётся, живёт только в тестовом контейнере: на
-- продакшн эти функции не попадают, они не в supabase/migrations.

-- ─────────────────────────────────────────────────────────────
-- «Войти как»
--
-- Подделываем ровно то, что видит база от PostgREST: claims в
-- request.jwt.claims. Роль переключается отдельной командой `set role
-- authenticated` в самих сценариях — из функции этого делать нельзя,
-- переключение не переживёт выход из неё.
-- ─────────────────────────────────────────────────────────────

create or replace function t_as(
  p_uid   uuid,
  p_email text    default null,
  p_anon  boolean default false
)
returns void
language plpgsql
as $$
begin
  perform set_config(
    'request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object(
      'sub',          p_uid::text,
      'role',         'authenticated',
      'email',        p_email,
      'is_anonymous', p_anon
    ))::text,
    false
  );
end
$$;

-- Выйти совсем: ни сессии, ни claims.
create or replace function t_logout() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', false);
end
$$;

-- ─────────────────────────────────────────────────────────────
-- Проверки
-- ─────────────────────────────────────────────────────────────

create or replace function t_ok(p_condition boolean, p_label text)
returns void
language plpgsql
as $$
begin
  if p_condition then
    raise notice '  ok — %', p_label;
  else
    raise exception 'ПРОВАЛ: %', p_label;
  end if;
end
$$;

create or replace function t_eq(p_actual anyelement, p_expected anyelement, p_label text)
returns void
language plpgsql
as $$
begin
  if p_actual is not distinct from p_expected then
    raise notice '  ok — % (%)', p_label, p_actual;
  else
    raise exception 'ПРОВАЛ: % — ожидалось %, получено %', p_label, p_expected, p_actual;
  end if;
end
$$;

-- Проверка, что запрос ОТКЛОНЁН, и отклонён по ожидаемой причине.
--
-- Отдельная функция нужна, потому что «запрос упал» и «запрос упал
-- правильно» — разные вещи. Тест, который радуется любой ошибке, зелёный
-- и когда политика работает, и когда в запросе опечатка.
create or replace function t_denied(p_sql text, p_expect text, p_label text)
returns void
language plpgsql
as $$
declare
  v_denied boolean := false;
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_expect in SQLERRM) > 0 then
      v_denied := true;
    else
      raise exception 'ПРОВАЛ: % — ожидалось «%», получено: %', p_label, p_expect, SQLERRM;
    end if;
  end;

  if not v_denied then
    raise exception 'ПРОВАЛ: % — ожидался отказ «%», но запрос прошёл', p_label, p_expect;
  end if;

  raise notice '  ok — % (отказ: %)', p_label, p_expect;
end
$$;

-- ─────────────────────────────────────────────────────────────
-- Посев
-- ─────────────────────────────────────────────────────────────

-- Фиксированные id, чтобы сценарии могли ссылаться на них по имени,
-- а не таскать значения между файлами через временные таблицы.
insert into auth.users (id, email, email_confirmed_at, is_anonymous) values
  ('11111111-0000-0000-0000-000000000001', 'aliya@nomadtech.kz',  now(), false),
  ('11111111-0000-0000-0000-000000000002', 'daulet@nomadtech.kz', now(), false),
  ('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz',     now(), false),
  ('11111111-0000-0000-0000-000000000004', 'personal@gmail.com',  now(), false);

-- Анонимные учётные записи: без почты, is_anonymous = true. Это ровно то,
-- что заводит signInAnonymously().
insert into auth.users (id, email, is_anonymous)
select ('22222222-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, null, true
  from generate_series(1, 12) as i;

insert into companies (id, name, email_domain, tariff_tier, billing_period) values
  ('33333333-0000-0000-0000-000000000001', 'NomadTech', 'nomadtech.kz', 'start_100', 'month');

insert into hr_accounts (user_id, company_id, full_name) values
  ('11111111-0000-0000-0000-000000000003',
   '33333333-0000-0000-0000-000000000001',
   'Асем, HR-директор');

do $$ begin raise notice 'Посев готов: компания NomadTech, 4 именных аккаунта, 12 анонимных'; end $$;
