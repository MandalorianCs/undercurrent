-- Вход через Telegram для личной подписки.
--
-- Только B2C. Для сотрудника компании корпоративная почта — не способ
-- связи, а доказательство права на доступ: она подтверждает, что человек
-- действительно работает в компании, которая оплатила продукт. Telegram
-- такого не доказывает, поэтому заменить им вход в B2B нельзя, не убрав
-- саму проверку.
--
-- Как это работает. Человек открывает бота, бот заводит ему учётную
-- запись и присылает одноразовую ссылку входа. Ссылка открывает
-- приложение уже авторизованным.
--
-- Учётная запись создаётся с синтетическим адресом вида
-- tg<chat_id>@telegram.local — почтой она не является и писем не
-- получает. Это осознанный размен: человек входит одним нажатием, но
-- восстановить доступ может только через тот же Telegram. Другого
-- способа у него нет, и приложение обязано сказать это прямо.

-- ─────────────────────────────────────────────────────────────
-- Заявки на вход
--
-- Отдельная таблица, а не поле в telegram_links: заявка живёт минуты и
-- удаляется, а привязка живёт, пока человек ей пользуется. Смешивать
-- сущности с разным сроком жизни в одной строке — верный способ
-- однажды удалить не то.
-- ─────────────────────────────────────────────────────────────

create table telegram_login_requests (
  nonce       text primary key,
  telegram_id bigint not null,
  -- Ссылка, которую сгенерировал бот. Хранится ровно до отправки.
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '10 minutes'
);

create index telegram_login_requests_tg_idx on telegram_login_requests (telegram_id);

alter table telegram_login_requests enable row level security;
revoke all on telegram_login_requests from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Заведение личной сессии по чату
--
-- Вызывается ботом служебным ключом после того, как учётная запись уже
-- создана через admin API. Функция делает вторую половину: строку в
-- anonymous_sessions и привязку.
--
-- Почему функцией, а не двумя вставками из бота. Порядок и условия здесь
-- существенны: привязка не должна появиться без сессии, а сессия не
-- должна быть корпоративной. В боте это выглядело бы как две независимые
-- операции, между которыми однажды вклинится третья.
-- ─────────────────────────────────────────────────────────────

create or replace function link_personal_by_telegram(
  p_user     uuid,
  p_chat_id  bigint,
  p_username text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_anon boolean;
begin
  select is_anonymous into v_anon from auth.users where id = p_user;

  if v_anon is null then
    raise exception 'UC_NO_USER: Учётная запись не найдена';
  end if;

  -- Та же граница, что и везде: анонимная сессия сотрудника не
  -- связывается с Telegram ни при каких обстоятельствах.
  if v_anon then
    raise exception 'UC_ANONYMOUS_LINK: Анонимную сессию нельзя связать с Telegram';
  end if;

  -- company_id пуст: вход через Telegram доступен только личной
  -- подписке, а она к работодателю отношения не имеет.
  insert into anonymous_sessions (id, company_id)
  values (p_user, null)
  on conflict (id) do nothing;

  -- Один чат — одна учётная запись. Старую привязку этого чата снимаем:
  -- иначе человек, сменивший аккаунт, получал бы чужие уведомления.
  delete from telegram_links where telegram_id = p_chat_id and user_id <> p_user;

  insert into telegram_links (telegram_id, user_id, kind, username)
  values (p_chat_id, p_user, 'personal', p_username)
  on conflict (telegram_id) do update
    set user_id  = excluded.user_id,
        username = excluded.username;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Кого этот чат уже представляет
--
-- Нужна боту, чтобы при повторном входе не создавать вторую учётную
-- запись, а выдать ссылку на существующую.
-- ─────────────────────────────────────────────────────────────

create or replace function user_by_telegram(p_chat_id bigint)
returns uuid
language sql
security definer
set search_path = public, extensions
as $$
  select user_id from telegram_links where telegram_id = p_chat_id;
$$;
