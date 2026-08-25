-- Связка с Telegram.
--
-- ═══════════════════════════════════════════════════════════════
-- ГЛАВНОЕ ОГРАНИЧЕНИЕ ЭТОЙ МИГРАЦИИ
-- ═══════════════════════════════════════════════════════════════
--
-- Telegram знает, кто человек. Бот обязан помнить собеседника, иначе не
-- сможет продолжить разговор. Значит связка «чат ↔ данные» существует по
-- определению, и вопрос только в том, к каким данным она ведёт.
--
-- Здесь она ведёт ТОЛЬКО к именным учётным записям: HR-аккаунт и личная
-- подписка B2C. К анонимной сессии сотрудника она не ведёт никогда —
-- это проверяется триггером, а не соглашением.
--
-- Почему так, а не «прикрутим бота ко всему». Обещание B2B звучит как
-- «связать переписку с человеком невозможно». Стоит появиться строке
-- telegram_id рядом с анонимной сессией — и обещание превращается в
-- «связать можно, но мы не будем». Для сотрудника, который решает,
-- писать ли правду, это совершенно разные продукты.
--
-- Сотруднику бот тоже полезен: он выдаёт ссылку в приложение. Разговор
-- при этом происходит там, где для него есть анонимность.

-- ─────────────────────────────────────────────────────────────
-- Кому принадлежит привязка
-- ─────────────────────────────────────────────────────────────

create type telegram_link_kind as enum ('hr', 'personal');

create table telegram_links (
  -- Первичным ключом — идентификатор чата, а не суррогат: одна привязка
  -- на чат по построению, без отдельного уникального индекса.
  telegram_id bigint primary key,

  -- unique обязателен и здесь: без него один человек привяжет два чата
  -- и будет получать одно уведомление дважды, а отвязав один, решит,
  -- что бот сломался.
  user_id     uuid not null unique references auth.users (id) on delete cascade,

  kind        telegram_link_kind not null,
  username    text,
  linked_at   timestamptz not null default now()
);

comment on table telegram_links is
  'Связь чата Telegram с ИМЕНной учётной записью. Анонимные сессии сюда '
  'не попадают — см. триггер telegram_link_guard.';

-- ─────────────────────────────────────────────────────────────
-- Страж
--
-- Проверка живёт в базе, а не в боте. Бот ходит служебным ключом, то
-- есть мимо всех политик, и единственное, что его остановит, — правило
-- внутри самого Postgres. Если завтра появится второй бот, скрипт или
-- «временная админка», правило продолжит работать без их участия.
-- ─────────────────────────────────────────────────────────────

create or replace function telegram_link_guard()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_anon boolean;
begin
  select is_anonymous into v_anon from auth.users where id = new.user_id;

  if v_anon is null then
    raise exception 'UC_NO_USER: Учётная запись не найдена';
  end if;

  -- Вот эта строка и есть всё ограничение.
  if v_anon then
    raise exception
      'UC_ANONYMOUS_LINK: Анонимную сессию нельзя связать с Telegram. '
      'Это сделало бы переписку сотрудника привязанной к его аккаунту '
      'Telegram, то есть к номеру телефона.';
  end if;

  -- Вид привязки должен соответствовать действительности, иначе HR
  -- получит уведомления B2C-подписчика и наоборот.
  if new.kind = 'hr' and not exists (select 1 from hr_accounts where user_id = new.user_id) then
    raise exception 'UC_NOT_HR: Учётная запись не является HR-аккаунтом';
  end if;

  if new.kind = 'personal' and not exists (
    select 1 from anonymous_sessions where id = new.user_id and company_id is null
  ) then
    raise exception 'UC_NOT_PERSONAL: Личная сессия не найдена';
  end if;

  return new;
end;
$$;

create trigger telegram_links_guard
  before insert or update on telegram_links
  for each row execute function telegram_link_guard();

-- ─────────────────────────────────────────────────────────────
-- Одноразовые коды привязки
--
-- Тот же приём, что с билетами доступа: человек берёт код в приложении
-- и предъявляет его боту. Никаких номеров телефона — их в схеме нет и
-- заводить их ради привязки значило бы собирать данные, которые
-- продукту не нужны.
--
-- Код уходит в ссылку вида t.me/бот?start=КОД, поэтому привязка — это
-- одно нажатие, а не набор символов руками.
-- ─────────────────────────────────────────────────────────────

create table telegram_link_codes (
  code       text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  kind       telegram_link_kind not null,
  -- Дата, а не точное время: точное время выдачи кода — это отпечаток
  -- сеанса работы человека в приложении. Здесь оно не нужно ни для чего.
  issued_on  date not null default current_date,
  expires_at timestamptz not null default now() + interval '15 minutes'
);

create index telegram_link_codes_user_idx on telegram_link_codes (user_id);

-- ─────────────────────────────────────────────────────────────
-- Уведомления
--
-- Строки создаёт база, разносит бот. Приложение и Telegram становятся
-- двумя окнами в одни данные, а не двумя источниками правды.
-- ─────────────────────────────────────────────────────────────

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text,
  -- Отметка доставки. Пустая — бот ещё не отправил.
  sent_at    timestamptz,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_pending_idx on notifications (user_id) where sent_at is null;

-- ─────────────────────────────────────────────────────────────
-- Выдача кода привязки
-- ─────────────────────────────────────────────────────────────

create or replace function issue_telegram_link_code()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user uuid := auth.uid();
  v_anon boolean;
  v_kind telegram_link_kind;
  v_code text;
begin
  if v_user is null then
    raise exception 'UC_NOT_AUTHENTICATED: Сначала войдите';
  end if;

  select is_anonymous into v_anon from auth.users where id = v_user;

  if v_anon then
    raise exception
      'UC_ANONYMOUS: Анонимной сессии Telegram не привязывается. '
      'Это связало бы вашу переписку с номером телефона.';
  end if;

  if exists (select 1 from hr_accounts where user_id = v_user) then
    v_kind := 'hr';
  elsif exists (select 1 from anonymous_sessions where id = v_user and company_id is null) then
    v_kind := 'personal';
  else
    raise exception 'UC_NO_ACCOUNT: Не найдено ни HR-аккаунта, ни личной подписки';
  end if;

  -- Старые коды этого человека выбрасываем: два действующих кода
  -- означают два чата, а привязка одна.
  delete from telegram_link_codes where user_id = v_user;

  -- Формат без дефисов и в нижнем регистре: код едет в URL как
  -- ?start=..., а Telegram разрешает там только буквы, цифры, _ и -.
  v_code := lower(replace(gen_random_uuid()::text, '-', ''));

  insert into telegram_link_codes (code, user_id, kind) values (v_code, v_user, v_kind);
  return v_code;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Уведомления HR по свежим агрегатам
--
-- Вызывается после пересчёта. Шлём только то, что и так видно на
-- дашборде: отдел, направление, величину. Ни цитат, ни имён.
-- ─────────────────────────────────────────────────────────────

create or replace function notify_hr_on_risk(p_company uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_rows integer := 0;
begin
  insert into notifications (user_id, kind, title, body)
  select h.user_id,
         'risk_up',
         'Риск вырос: ' || coalesce(d.title_ru, 'компания целиком'),
         'Уровень ' || a.risk_score ||
           coalesce(' (' || (case when a.risk_delta_pct > 0 then '+' else '' end)
                          || a.risk_delta_pct || ' %)', '') ||
           '. Выборка: ' || a.sample_size || ' чел.'
    from hr_aggregates a
    join hr_accounts h on h.company_id = a.company_id
    left join departments d on d.slug = a.department_tag
   where a.company_id      = p_company
     and a.trend_direction = 'up'
     -- Порог обязателен и здесь. Без него уведомление стало бы дырой в
     -- обход политики: срез, скрытый на дашборде, приезжал бы в
     -- Telegram открытым текстом.
     and a.sample_size    >= setting('min_sample_size')::integer
     and a.period_end      = current_date
     -- Не дублируем: за один период одно уведомление на отдел.
     and not exists (
       select 1 from notifications n
        where n.user_id = h.user_id
          and n.kind    = 'risk_up'
          and n.title   = 'Риск вырос: ' || coalesce(d.title_ru, 'компания целиком')
          and n.created_at::date = current_date
     );

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Права и политики
-- ─────────────────────────────────────────────────────────────

alter table telegram_links      enable row level security;
alter table telegram_link_codes enable row level security;
alter table notifications       enable row level security;

-- Привязки и коды не читает никто, кроме служебного ключа. Политик нет
-- вовсе — при включённом RLS это означает «доступ закрыт», а отобранные
-- гранты закрывают и путь в обход политик.
revoke all on telegram_links      from anon, authenticated;
revoke all on telegram_link_codes from anon, authenticated;

-- Свои уведомления человек читает и отмечает прочитанными.
create policy notifications_own_read on notifications
  for select to authenticated using (user_id = auth.uid());

create policy notifications_own_update on notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant execute on function issue_telegram_link_code() to authenticated;
