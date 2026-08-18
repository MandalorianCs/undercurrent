-- Сценарий 1 — путь сотрудника: корпоративная почта → билет → анонимный чат.
--
-- Роль переключается командами верхнего уровня, а не внутри DO-блоков:
-- `set role` внутри plpgsql ведёт себя по-разному в зависимости от того,
-- как объявлена функция, и тест, который на самом деле выполняется от
-- имени postgres, покажет зелёный свет при полностью сломанном RLS —
-- суперпользователь политики не проверяет.

do $$ begin raise notice 'Сценарий 1 — от корпоративной почты до анонимного чата'; end $$;

-- ── Шаг 1. Вход по корпоративной почте и получение билета ─────

select t_as('11111111-0000-0000-0000-000000000001', 'aliya@nomadtech.kz', false);
set role authenticated;

select issue_access_grant() as code \gset

reset role;

select t_ok(:'code' ~ '^UC-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$', 'билет выдан в читаемом формате');

-- Смотрим на результат от имени postgres, минуя RLS: нас интересует, что
-- реально легло в таблицы, а не что видно клиенту.
do $$
begin
  perform t_eq(
    (select count(*)::int from employee_access
      where corporate_email_hash = hash_corporate_email('aliya@nomadtech.kz')),
    1, 'адрес отмечен как занявший место');

  perform t_eq((select count(*)::int from access_grants), 1, 'билет лежит в базе');

  -- Самая содержательная проверка шага: в базе нет открытого адреса.
  perform t_eq(
    (select count(*)::int from employee_access
      where corporate_email_hash like '%@%'),
    0, 'адрес хранится хэшем, а не текстом');
end $$;

-- ── Шаг 2. Билет нельзя привязать к аккаунту с почтой ─────────
--
-- Это центральная проверка всей архитектуры. Если она когда-нибудь
-- станет красной, продукт перестал быть анонимным — независимо от того,
-- что показывает интерфейс.

select t_as('11111111-0000-0000-0000-000000000001', 'aliya@nomadtech.kz', false);
set role authenticated;

select t_denied(
  format('select bind_access_grant(%L)', :'code'),
  'UC_NOT_ANONYMOUS',
  'привязка билета к корпоративному аккаунту');

reset role;

-- ── Шаг 3. Анонимный вход и погашение билета ──────────────────

select t_as('22222222-0000-0000-0000-000000000001', null, true);
set role authenticated;

select bind_access_grant(:'code') as company_id \gset

-- Повторно тот же код не пройдёт: строка удалена, а не помечена.
select t_denied(
  format('select bind_access_grant(%L)', :'code'),
  'UC_BAD_GRANT',
  'повторное использование билета');

reset role;

do $$
begin
  perform t_eq((select count(*)::int from access_grants), 0, 'погашенный билет удалён из базы');
  perform t_eq(
    (select company_id from anonymous_sessions where id = '22222222-0000-0000-0000-000000000001'),
    '33333333-0000-0000-0000-000000000001'::uuid,
    'анонимная сессия привязана к компании');
end $$;

-- ── Шаг 4. Разговор ───────────────────────────────────────────

select t_as('22222222-0000-0000-0000-000000000001', null, true);
set role authenticated;

insert into conversations (anonymous_session_id, company_id, department_tag)
values ('22222222-0000-0000-0000-000000000001',
        '33333333-0000-0000-0000-000000000001',
        'sales')
returning id as conv_id \gset

insert into messages (conversation_id, role, content, stress_markers) values
  (:'conv_id', 'user', 'Третью неделю закрываю чужие задачи, сплю по пять часов',
   '{"exhaustion": 0.8, "workload": 0.9, "hopelessness": 0.3, "conflict": 0.1}'),
  (:'conv_id', 'assistant', 'Давайте разберём, что из этого можно снять с вас на этой неделе.', null);

select t_eq((select count(*)::int from conversations), 1, 'свой разговор виден');
select t_eq((select count(*)::int from messages), 2, 'свои сообщения видны');

reset role;

-- ── Шаг 5. Чужая анонимная сессия не видит ничего ─────────────
--
-- Анонимность бесполезна, если анонимы видят друг друга.

select t_as('22222222-0000-0000-0000-000000000002', null, true);
set role authenticated;

select t_eq((select count(*)::int from conversations), 0, 'чужой разговор не виден другому анониму');
select t_eq((select count(*)::int from messages), 0, 'чужие сообщения не видны другому анониму');

reset role;

-- ── Шаг 6. Лимит билетов на один адрес ────────────────────────

select t_as('11111111-0000-0000-0000-000000000001', 'aliya@nomadtech.kz', false);
set role authenticated;

select issue_access_grant() as code2 \gset
select issue_access_grant() as code3 \gset

select t_denied(
  'select issue_access_grant()',
  'UC_GRANT_LIMIT',
  'четвёртый билет на тот же адрес');

reset role;

-- ── Шаг 7. Незнакомый домен ───────────────────────────────────

select t_as('11111111-0000-0000-0000-000000000004', 'personal@gmail.com', false);
set role authenticated;

select t_denied(
  'select issue_access_grant()',
  'UC_UNKNOWN_DOMAIN',
  'почта неподключённой компании');

reset role;

do $$ begin raise notice 'Сценарий 1 пройден'; end $$;
