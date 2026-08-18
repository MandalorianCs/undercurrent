-- Undercurrent — базовая схема.
--
-- Главное свойство этой схемы описывается не тем, что в ней есть, а тем,
-- чего в ней нет: между `employee_access` (кто имеет право войти) и
-- `conversations` (что человек написал) нет ни одной колонки. Ни прямой
-- ссылки, ни общего ключа, ни пары «одинаковый uuid в двух местах».
--
-- Это не стилистическое предпочтение. Пока такая колонка существует,
-- обещание «HR не увидит, кто именно это написал» держится на том, что
-- никто не напишет соответствующий join — то есть на дисциплине. Когда
-- колонки нет, join физически не из чего собрать, и обещание держится
-- на структуре. Разница проявляется ровно в тот день, когда в компанию
-- придёт запрос «покажите переписку конкретного сотрудника»: в первом
-- случае это вопрос политики, во втором — ответ «мы не можем».
--
-- Реальных платежей на MVP нет: статус подписки живёт в базе, платёжный
-- провайдер (Kaspi Pay / CloudPayments) подключается отдельным этапом.

create extension if not exists pgcrypto;

-- ─────────────────────────────────────────────────────────────
-- Перечисления
-- ─────────────────────────────────────────────────────────────

-- Тариф — это диапазон команды, а не число сотрудников. Компания платит
-- фиксированную сумму за «до 100 человек», и подключение сто первого не
-- меняет счёт. Поштучная тарификация сломала бы анонимность с другой
-- стороны: чтобы выставить счёт за N человек, платформе пришлось бы
-- считать, сколько именно сотрудников завело переписку.
create type tariff_tier as enum (
  'small_20',      -- до 20 человек   — 30 000 ₸/мес
  'start_100',     -- до 100 человек  — 120 000 ₸/мес
  'growth_500',    -- 100–500 человек — 350 000 ₸/мес
  'corp_1000plus'  -- 1000+           — от 700 000 ₸/мес
);

create type billing_period as enum ('month', 'half_year', 'year');

create type message_role as enum ('user', 'assistant');

create type trend_direction as enum ('up', 'down', 'flat');

create type subscription_status as enum ('trial', 'active', 'expired');

-- ─────────────────────────────────────────────────────────────
-- Настройки платформы
-- Пороги вынесены в таблицу, а не зашиты в код: порог k-анонимности
-- придётся объяснять и, возможно, поднимать по требованию юристов
-- клиента — это не повод пересобирать приложение.
-- ─────────────────────────────────────────────────────────────

create table app_settings (
  key   text primary key,
  value numeric not null,
  note  text
);

insert into app_settings (key, value, note) values
  ('min_sample_size',   5,  'Минимум разных сессий в срезе, чтобы показать агрегат HR'),
  ('max_grants_per_email', 3, 'Сколько раз один сотрудник может получить билет (смена телефона, переустановка)'),
  ('risk_window_days',  14, 'Окно в днях, за которое считается риск по отделу');

create or replace function setting(p_key text)
returns numeric
language sql
stable
as $$
  select value from app_settings where key = p_key;
$$;

-- ─────────────────────────────────────────────────────────────
-- Компании
-- ─────────────────────────────────────────────────────────────

create table companies (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  -- Домен корпоративной почты — единственный признак принадлежности
  -- к компании на MVP. ID-верификация сознательно не делается: она
  -- требует хранить документ, а хранение документа рядом с продуктом
  -- про анонимность — это противоречие, которое клиент заметит первым.
  email_domain   text not null unique,
  tariff_tier    tariff_tier not null,
  billing_period billing_period not null default 'month',
  created_at     timestamptz not null default now()
);

-- Домен пишется в нижнем регистре без @: «kaspi.kz», а не «@Kaspi.KZ».
-- Иначе сотрудник с почтой в другом регистре не найдёт свою компанию,
-- а выглядеть это будет как «компания не подключена».
alter table companies
  add constraint companies_domain_normalized
  check (email_domain = lower(email_domain) and email_domain not like '@%');

-- ─────────────────────────────────────────────────────────────
-- Отделы
-- Общий справочник, а не свободный текст: агрегат по отделу имеет
-- смысл, только если «Продажи», «продажи» и «отдел продаж» — одна
-- строка. Свободный ввод превратил бы дашборд в список из сорока
-- вариантов написания с sample_size = 1 у каждого.
-- ─────────────────────────────────────────────────────────────

create table departments (
  slug       text primary key,
  title_ru   text not null,
  sort_order integer not null default 0
);

insert into departments (slug, title_ru, sort_order) values
  ('sales',       'Продажи',              10),
  ('engineering', 'Разработка',           20),
  ('support',     'Поддержка клиентов',   30),
  ('marketing',   'Маркетинг',            40),
  ('finance',     'Финансы',              50),
  ('operations',  'Операции и логистика', 60),
  ('hr',          'HR и рекрутинг',       70),
  ('management',  'Руководство',          80);

-- ─────────────────────────────────────────────────────────────
-- ГРАНИЦА. Всё, что выше, — про компанию. Всё, что ниже, — про людей,
-- и оно разрезано надвое: слева проверка права на вход, справа разговоры.
-- Эти половины не соединяются нигде, кроме company_id, — то есть на
-- уровне «сотрудник этой компании», а не «вот этот сотрудник».
-- ─────────────────────────────────────────────────────────────

-- ── Левая половина: доступ ────────────────────────────────────
--
-- Единственное назначение таблицы — ответить «да/нет» на вопрос
-- «этот адрес уже занял место в тарифе?». Она не участвует ни в одном
-- запросе, связанном с содержанием разговоров.

create table employee_access (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references companies (id) on delete cascade,
  -- Хэш, а не адрес. Важно понимать, от чего он на самом деле защищает:
  -- домен известен, а имена сотрудников угадываются словарём, поэтому
  -- перебрать хэши при доступе к базе несложно. Анонимность держится
  -- НЕ на этом хэше, а на отсутствии связи с правой половиной схемы.
  -- Хэш решает более скромную задачу: не хранить открытый список почт
  -- сотрудников клиента там, где он никому не нужен для работы.
  corporate_email_hash text not null,
  verified_at          timestamptz,
  -- Счётчик, а не ссылка на выданные билеты. Знать «этот адрес получал
  -- билет дважды» для учёта мест достаточно; знать, КАКИЕ это были
  -- билеты, — уже мост между половинами, поэтому такой колонки нет.
  grants_issued        integer not null default 0,
  unique (company_id, corporate_email_hash)
);

-- ── Мост, который сгорает: одноразовые билеты ─────────────────
--
-- Билет — единственное, что переходит из левой половины в правую, и
-- живёт он ровно один переход: сотрудник получает код, входит заново
-- анонимно, привязывает код, код гасится.
--
-- Здесь нет company_id-независимых полей, по которым билет можно было бы
-- сопоставить с конкретным сотрудником: ни адреса, ни ссылки на
-- employee_access, ни точного времени выдачи.

create table access_grants (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies (id) on delete cascade,
  -- Хранится хэш кода. Код в открытом виде существует только в ответе
  -- RPC и на экране сотрудника — в базе его нет даже на секунду.
  code_hash  text not null unique,
  -- ДАТА, а не timestamptz, и это осознанно. Если бы здесь стоял точный
  -- момент, его можно было бы сопоставить с employee_access.verified_at
  -- и восстановить связь по совпадению до миллисекунды — то есть обойти
  -- всю конструкцию. Огрубление до дня оставляет остаточный риск для
  -- компании, где за день верифицировался ровно один человек; это
  -- честно описано в DESIGN.md и лечится порогом k-анонимности.
  issued_on  date not null default current_date,
  -- Невостребованный билет не должен лежать вечно: это тихо занятое
  -- место в тарифе и живой код у того, кто передумал входить.
  expires_on date not null default current_date + 7
);

-- Погашённый билет не помечается использованным, а удаляется. Так
-- надёжнее сразу с двух сторон: повторно предъявить нечего, потому что
-- строки нет, и не остаётся поля `claimed_at`, точное время в котором
-- можно было бы сопоставлять с моментом появления анонимной сессии.
-- Учёт мест ведётся счётчиком employee_access.grants_issued, которому
-- для своей задачи достаточно числа.

-- ── Правая половина: разговоры ────────────────────────────────
--
-- anonymous_session_id — это uuid анонимной учётной записи Supabase.
-- У неё нет ни почты, ни телефона, ни пароля: она создаётся
-- signInAnonymously() и с точки зрения auth.users не знает о человеке
-- ничего. Именно поэтому она годится как идентификатор разговора:
-- случайный, стабильный для устройства, ни к чему не привязанный.

create table anonymous_sessions (
  -- Ссылка на auth.users безопасна и полезна: у анонимной учётной записи
  -- там нет ни почты, ни телефона — только случайный id, — зато удаление
  -- аккаунта уносит за собой всю переписку каскадом, без отдельной уборки.
  id         uuid primary key references auth.users (id) on delete cascade,
  -- null для B2C: личная подписка не привязана к работодателю,
  -- и её разговоры не попадают ни в один корпоративный агрегат.
  company_id uuid references companies (id) on delete set null,
  created_at timestamptz not null default now()
);

create table conversations (
  id                   uuid primary key default gen_random_uuid(),
  anonymous_session_id uuid not null references anonymous_sessions (id) on delete cascade,
  company_id           uuid references companies (id) on delete set null,
  -- Добровольный. Сотрудник указывает отдел сам при старте чата, и это
  -- не сверяется с тем, в каком отделе он числится, — сверять не с чем.
  -- Пустой тег означает «в агрегаты не попадаю», и это рабочий выбор,
  -- а не ошибка ввода: в отделе из трёх человек указать отдел значит
  -- почти назваться.
  department_tag       text references departments (slug),
  started_at           timestamptz not null default now()
);

create index conversations_session_idx on conversations (anonymous_session_id);
create index conversations_aggregate_idx on conversations (company_id, department_tag, started_at);

create table messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations (id) on delete cascade,
  role            message_role not null,
  content         text not null,
  -- Обезличенные маркеры, извлечённые моделью: {"exhaustion": 0.7,
  -- "workload": 0.4, "tags": ["переработки"]}. В агрегат уходят только
  -- они, текст не покидает эту таблицу никогда.
  stress_markers  jsonb,
  created_at      timestamptz not null default now()
);

create index messages_conversation_idx on messages (conversation_id, created_at);

-- ── Дневник состояния ─────────────────────────────────────────
--
-- Отдельная таблица, а не массив внутри personal_subscriptions, хотя
-- в ТЗ дневник описан там. Причина в самом ТЗ: экран дневника заявлен
-- как доступный всем, а расширенным — у B2C. Внутри подписки дневник
-- недостижим для того, у кого подписки нет, то есть для всей B2B-части
-- продукта. Ключ — та же сессия, что и у разговоров, поэтому дневник
-- анонимен ровно в той же степени.

create table mood_entries (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references anonymous_sessions (id) on delete cascade,
  -- 1–5, где 1 — «совсем тяжело», 5 — «хорошо». Шкала короткая
  -- намеренно: дневник, который требует усилий, не ведут.
  mood       smallint not null check (mood between 1 and 5),
  note       text,
  created_at timestamptz not null default now()
);

create index mood_entries_session_idx on mood_entries (session_id, created_at desc);

-- ─────────────────────────────────────────────────────────────
-- HR: аккаунты и агрегаты
-- ─────────────────────────────────────────────────────────────

create table hr_accounts (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  company_id uuid not null references companies (id) on delete cascade,
  full_name  text,
  created_at timestamptz not null default now()
);

-- Заранее посчитанные срезы. Считаются функцией, а не запросом из
-- дашборда, и это принципиально: дашборд, который умеет считать сам,
-- умеет и посчитать что-нибудь ещё — например, срез по одному человеку.
-- HR-клиент читает готовые строки и не имеет доступа к их источнику.
create table hr_aggregates (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references companies (id) on delete cascade,
  department_tag  text references departments (slug),
  period_start    date not null,
  period_end      date not null,
  -- 0–100. Как именно считается — см. функцию recompute_hr_aggregates
  -- в следующей миграции.
  risk_score      numeric(4, 1) not null check (risk_score between 0 and 100),
  trend_direction trend_direction not null,
  -- Сколько разных сессий попало в срез. Ниже порога срез не
  -- показывается: в отделе из двух человек «риск вырос до 80» — это
  -- сообщение о конкретном человеке, как его ни называй.
  sample_size     integer not null,
  computed_at     timestamptz not null default now(),
  unique (company_id, department_tag, period_start, period_end)
);

create index hr_aggregates_lookup_idx
  on hr_aggregates (company_id, period_start desc);

-- ─────────────────────────────────────────────────────────────
-- Личные подписки (B2C)
-- ─────────────────────────────────────────────────────────────

create table personal_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  -- Свой аккаунт, заведённый обычной регистрацией. Не имеет отношения
  -- к employee_access: B2C-подписчик может вообще нигде не работать,
  -- а может работать в подключённой компании — продукт об этом не знает
  -- и знать не должен, иначе «доступ независимо от работодателя»
  -- перестаёт быть правдой.
  user_id    uuid not null unique references auth.users (id) on delete cascade,
  plan       text not null default 'b2c_premium',
  status     subscription_status not null default 'trial',
  started_at timestamptz not null default now(),
  -- На MVP двигается вручную/скриптом. Платёжный провайдер появится
  -- здесь же: статус меняет вебхук, остальная схема не меняется.
  expires_at timestamptz
);
