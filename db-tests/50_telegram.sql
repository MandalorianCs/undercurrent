-- Сценарий 4 — связка с Telegram.
--
-- Проверяем главное: Telegram нельзя привязать к анонимной сессии. Это
-- единственное место в продукте, где внешняя система знает имя человека,
-- и если она дотянется до переписки, обещание B2B перестанет быть
-- правдой — причём незаметно, потому что снаружи всё будет работать.

do $$ begin raise notice 'Сценарий 4 — Telegram: к чему привязка ведёт, а к чему нет'; end $$;

-- ── Посев ─────────────────────────────────────────────────────
--
-- Три учётные записи: HR, личная подписка B2C и анонимная сессия
-- сотрудника. Первым двум привязка положена, третьей — нет.

insert into auth.users (id, email, is_anonymous) values
  ('55555555-0000-0000-0000-000000000001', 'personal@example.com', false);

insert into anonymous_sessions (id, company_id)
values ('55555555-0000-0000-0000-000000000001', null);

-- ── Кому привязка положена ────────────────────────────────────

select t_as('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz', false);
set role authenticated;

select t_ok(length(issue_telegram_link_code()) = 32, 'HR получил код привязки');

-- Прочитать собственный код через таблицу человек не может, и это не
-- недосмотр: код нужен только боту, который ходит служебным ключом.
-- Функция вернула значение прямо в ответ — этого достаточно.
select t_denied(
  'select count(*) from telegram_link_codes',
  'permission denied',
  'таблица кодов закрыта даже тому, кто код только что взял');

reset role;

select t_eq(
  (select kind from telegram_link_codes where user_id = '11111111-0000-0000-0000-000000000003'),
  'hr'::telegram_link_kind,
  'вид привязки определён как HR автоматически');

select t_as('55555555-0000-0000-0000-000000000001', 'personal@example.com', false);
set role authenticated;
select issue_telegram_link_code();
reset role;

select t_eq(
  (select kind from telegram_link_codes where user_id = '55555555-0000-0000-0000-000000000001'),
  'personal'::telegram_link_kind,
  'подписчик B2C получил код своего вида');

-- ── Кому не положена ──────────────────────────────────────────
--
-- Анонимная сессия сотрудника. Отказ должен приходить из базы, а не из
-- интерфейса: интерфейс можно обойти, политику — нет.

reset role;
select t_as('22222222-0000-0000-0000-000000000001', null, true);
set role authenticated;

select t_denied(
  'select issue_telegram_link_code()',
  'UC_ANONYMOUS',
  'анонимная сессия не может взять код привязки');

-- ── Прямая попытка мимо кодов ─────────────────────────────────
--
-- Служебный ключ ходит мимо RLS, поэтому запрет обязан жить в триггере.
-- Ниже — ровно то, что сделал бы бот, если бы его однажды научили
-- «поддерживать и сотрудников тоже».

reset role;

select t_denied(
  $$insert into telegram_links (telegram_id, user_id, kind)
    values (777001, '22222222-0000-0000-0000-000000000001', 'personal')$$,
  'UC_ANONYMOUS_LINK',
  'анонимную сессию нельзя связать с чатом даже служебным ключом');

select t_denied(
  $$insert into telegram_links (telegram_id, user_id, kind)
    values (777002, '11111111-0000-0000-0000-000000000003', 'personal')$$,
  'UC_NOT_PERSONAL',
  'HR-аккаунт нельзя выдать за личную подписку');

-- Успешная привязка — чтобы убедиться, что страж не запрещает вообще всё.
insert into telegram_links (telegram_id, user_id, kind)
values (777003, '11111111-0000-0000-0000-000000000003', 'hr');

select t_eq(
  (select kind from telegram_links where telegram_id = 777003),
  'hr'::telegram_link_kind,
  'HR-аккаунт привязывается нормально');

-- ── Уведомления не обходят порог ──────────────────────────────
--
-- Дашборд скрывает срез с малой выборкой. Если уведомление о том же
-- срезе уйдёт в Telegram, порог окажется декоративным: HR прочитает в
-- телефоне то, чего ему не показали на экране.

select t_ok(
  notify_hr_on_risk('33333333-0000-0000-0000-000000000001') > 0,
  'уведомления по растущим срезам созданы');

select t_eq(
  (select count(*)::int
     from notifications
    where title like '%Финансы%'),
  0,
  'срез ниже порога в уведомления не попал');

-- ── Что видит сам человек ─────────────────────────────────────

select t_as('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz', false);
set role authenticated;

select t_ok(
  (select count(*) from notifications) > 0,
  'HR видит свои уведомления');

-- Отказ, а не ноль строк. Разница существенная: ноль означал бы
-- «читать можно, просто нечего», и однажды там что-то появилось бы.
select t_denied(
  'select count(*) from telegram_links',
  'permission denied',
  'таблица привязок закрыта даже своему владельцу');

reset role;
select t_logout();

do $$ begin raise notice 'Сценарий 4 пройден'; end $$;
