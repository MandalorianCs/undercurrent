-- Сценарий 2 — изоляция.
--
-- Этот файл существует, чтобы на вопрос «а докажите, что HR не увидит
-- переписку» можно было ответить не словами, а прогоном. Всё остальное
-- в проекте можно переписать; если станет красным что-то отсюда —
-- продукт больше не тот, который продавали.
--
-- Данные для сценария создал файл 20: у сотрудника есть разговор с
-- сообщениями, у компании NomadTech есть HR-аккаунт.

do $$ begin raise notice 'Сценарий 2 — изоляция: что видит HR и чего нет в схеме'; end $$;

-- ── Часть 1. HR за своим рабочим местом ───────────────────────

select t_as('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz', false);
set role authenticated;

-- Ноль строк, а не отказ. Разница принципиальна: отказ означал бы, что
-- таблица существует и защищена запретом, который кто-то однажды может
-- ослабить. Ноль строк означает, что политика доступа к переписке
-- вообще не предусматривает такого читателя, как HR.
select t_eq((select count(*)::int from conversations), 0, 'HR не видит ни одного разговора');
select t_eq((select count(*)::int from messages),      0, 'HR не видит ни одного сообщения');
select t_eq((select count(*)::int from mood_entries),  0, 'HR не видит записей дневника');
select t_eq((select count(*)::int from anonymous_sessions), 0, 'HR не видит список анонимных сессий');

-- А вот здесь именно отказ: до таблиц левой половины у клиентских ролей
-- нет даже прав, не то что политик.
select t_denied('select * from employee_access', 'permission denied', 'HR читает список сотрудников');
select t_denied('select * from access_grants',   'permission denied', 'HR читает выданные билеты');

-- HR не может сочинить себе агрегат в обход порога выборки.
select t_denied(
  $q$insert into hr_aggregates (company_id, department_tag, period_start, period_end, risk_score, trend_direction, sample_size)
     values ('33333333-0000-0000-0000-000000000001', 'sales', current_date - 14, current_date, 90, 'up', 999)$q$,
  'row-level security',
  'HR пишет агрегат руками');

reset role;

-- ── Часть 2. Сотрудник тоже не имеет лишнего ──────────────────
--
-- Изоляция симметрична. Сотрудник не должен видеть список коллег,
-- подтвердивших доступ, — по нему восстанавливается штат компании.

select t_as('22222222-0000-0000-0000-000000000001', null, true);
set role authenticated;

select t_denied('select * from employee_access', 'permission denied', 'сотрудник читает список сотрудников');
select t_denied('select * from access_grants',   'permission denied', 'сотрудник читает чужие билеты');
select t_eq((select count(*)::int from hr_accounts), 0, 'сотрудник не видит HR-аккаунты');

reset role;

-- ── Часть 3. Структурная проверка ─────────────────────────────
--
-- Проверки выше говорят «сейчас не видно». Проверки ниже говорят
-- «связать нечем в принципе» — и именно они переживут будущие правки
-- политик. Если кто-то однажды добавит в conversations колонку со
-- ссылкой на employee_access «просто чтобы было удобнее считать», тест
-- станет красным в тот же прогон, до того как это уедет в продакшн.

do $$
declare
  v_links int;
  v_suspicious int;
begin
  select count(*) into v_links
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_class f on f.oid = c.confrelid
   where c.contype = 'f'
     and (
       (t.relname in ('conversations', 'messages', 'mood_entries', 'anonymous_sessions')
        and f.relname in ('employee_access', 'access_grants'))
       or
       (t.relname in ('employee_access', 'access_grants')
        and f.relname in ('conversations', 'messages', 'mood_entries', 'anonymous_sessions'))
     );

  perform t_eq(v_links, 0, 'между половинами схемы нет ни одного внешнего ключа');

  -- Вторая линия: даже без внешнего ключа связь можно протащить
  -- «случайно» — колонкой с адресом, именем или чужим id, положенным
  -- туда руками. Ловим по названию.
  select count(*) into v_suspicious
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('conversations', 'messages', 'mood_entries', 'anonymous_sessions')
     and column_name ~* '(email|phone|employee|access|full_name|user_id)';

  perform t_eq(v_suspicious, 0, 'в таблицах переписки нет колонок, пахнущих личностью');
end $$;

-- ── Часть 4. Что осталось возможным — честно ──────────────────
--
-- Тест обязан фиксировать не только то, что защищено, но и границу
-- защиты. Иначе через полгода кто-нибудь прочитает файл выше и решит,
-- что гарантий больше, чем есть.
--
-- Остаточный риск: employee_access.verified_at хранит точный момент,
-- access_grants.issued_on — только дату. В компании, где за сутки
-- верифицировался ровно один человек, «единственная верификация 18-го»
-- и «единственный билет от 18-го» сходятся однозначно.
--
-- Проверяем не отсутствие риска, а то, что огрубление на месте: если
-- кто-то заменит issued_on на timestamptz ради удобной сортировки,
-- корреляция станет точной до миллисекунды, и об этом надо узнать здесь,
-- а не от клиентского юриста.

do $$
declare
  v_type text;
begin
  select data_type into v_type
    from information_schema.columns
   where table_schema = 'public' and table_name = 'access_grants' and column_name = 'issued_on';

  perform t_eq(v_type, 'date', 'время выдачи билета огрублено до даты');
end $$;

do $$ begin raise notice 'Сценарий 2 пройден — изоляция подтверждена структурно, а не на словах'; end $$;
