-- Undercurrent — переходы: выдача билета, вход в анонимный чат, агрегаты.
--
-- Схема из 0001 описывает, чего в базе нет. Этот файл описывает, как
-- человек проходит через отсутствующую связь: два входа, между ними
-- одноразовый код, и ни одного запроса, который видит обе стороны сразу.

-- ─────────────────────────────────────────────────────────────
-- Помощники
-- ─────────────────────────────────────────────────────────────

-- Хэш адреса. Стоит проговорить, чего он НЕ делает: он не защищает от
-- того, кто получил базу целиком. Домен известен, имена сотрудников
-- перебираются словарём, и восстановить соответствие «хэш → адрес» для
-- компании из ста человек — работа на минуты. Поэтому анонимность здесь
-- ни на грамм не зависит от стойкости хэша: она обеспечена тем, что от
-- этой таблицы некуда идти дальше. Задача хэша скромнее — не держать
-- открытый список почт клиента в базе, где он для работы не нужен.
create or replace function hash_corporate_email(p_email text)
returns text
language sql
immutable
set search_path = public, extensions
as $$
  select encode(digest(lower(trim(p_email)), 'sha256'), 'hex');
$$;

-- Код билета: три группы по четыре знака, UC-XXXX-XXXX-XXXX.
create or replace function generate_grant_code()
returns text
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  -- Алфавит без 0/O и 1/I/L. Код читают с экрана телефона и набирают
  -- на ноутбуке; «ноль это или буква О» — самая частая причина, по
  -- которой верный код выглядит неверным.
  alphabet constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  bytes    bytea;
  raw      text := '';
  i        integer;
begin
  -- gen_random_bytes, а не random(): это одноразовый ключ доступа, и
  -- предсказуемый генератор здесь означал бы «подобрать чужой билет».
  -- Остаток от деления на 31 даёт крошечный перекос в сторону первых
  -- букв алфавита — на 31^12 вариантов он неощутим.
  bytes := gen_random_bytes(12);
  for i in 0..11 loop
    raw := raw || substr(alphabet, 1 + (get_byte(bytes, i) % length(alphabet)), 1);
  end loop;

  return 'UC-' || substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4);
end;
$$;

-- Человек перепишет код руками: с пробелами, строчными буквами,
-- иногда без дефисов. Приводим к канону, иначе верный код не найдётся.
create or replace function normalize_grant_code(p_code text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g'));
$$;

-- ─────────────────────────────────────────────────────────────
-- Шаг 1. Сотрудник подтвердил корпоративную почту и берёт билет.
--
-- Вызывается из сессии, где auth.email() — корпоративный адрес. Это
-- единственная функция во всей системе, которая вообще видит адрес.
-- Всё, что она оставляет после себя: строка в employee_access («этот
-- адрес занял место») и строка в access_grants («выдан такой-то код
-- такого-то числа»). Соединить их между собой нечем.
-- ─────────────────────────────────────────────────────────────

create or replace function issue_access_grant()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_email   text := lower(trim(coalesce(auth.email(), '')));
  v_domain  text;
  v_company companies;
  v_hash    text;
  v_issued  integer;
  v_code    text;
begin
  if v_email = '' then
    raise exception 'UC_NOT_AUTHENTICATED: Сначала подтвердите корпоративную почту';
  end if;

  v_domain := split_part(v_email, '@', 2);

  select * into v_company from companies where email_domain = v_domain;
  if not found then
    raise exception 'UC_UNKNOWN_DOMAIN: Компания с доменом % ещё не подключена к Undercurrent', v_domain;
  end if;

  v_hash := hash_corporate_email(v_email);

  -- Проверяем лимит ДО увеличения счётчика. Если сначала увеличить, а
  -- потом бросить исключение, откатится и увеличение — счётчик никогда
  -- не дорастёт до лимита, и «не больше трёх билетов» превратится в
  -- «сколько угодно билетов».
  select grants_issued into v_issued
    from employee_access
   where company_id = v_company.id and corporate_email_hash = v_hash;

  if coalesce(v_issued, 0) >= setting('max_grants_per_email') then
    raise exception 'UC_GRANT_LIMIT: Для этого адреса уже выдано % билетов. Напишите в поддержку, если потеряли доступ', v_issued;
  end if;

  insert into employee_access (company_id, corporate_email_hash, verified_at, grants_issued)
       values (v_company.id, v_hash, now(), 1)
  on conflict (company_id, corporate_email_hash) do update
     set verified_at   = now(),
         grants_issued = employee_access.grants_issued + 1;

  v_code := generate_grant_code();

  insert into access_grants (company_id, code_hash)
       values (v_company.id, hash_corporate_email(normalize_grant_code(v_code)));

  -- Код возвращается ровно один раз и нигде не сохраняется в открытом
  -- виде. Потерявший его получает новый (в пределах лимита), а не
  -- «восстановленный» — восстанавливать не из чего.
  return v_code;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Шаг 2. Сотрудник вышел, зашёл заново анонимно и гасит билет.
--
-- Здесь стоит главная проверка всей конструкции. Если разрешить
-- привязку билета к аккаунту с почтой, то anonymous_session_id станет
-- идентификатором аккаунта, у которого есть адрес, — и разделение
-- половин схемы, ради которого всё затевалось, исчезнет за одну строку
-- клиентского кода. Поэтому проверка живёт в базе, а не в приложении:
-- клиент можно переписать, и его пишут люди, которые могут не знать,
-- почему выход из аккаунта здесь обязателен.
-- ─────────────────────────────────────────────────────────────

create or replace function bind_access_grant(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid   uuid := auth.uid();
  v_grant access_grants;
begin
  if v_uid is null then
    raise exception 'UC_NOT_AUTHENTICATED: Нет сессии';
  end if;

  -- Две независимые проверки одного и того же, намеренно. Первая —
  -- признак анонимного входа в токене. Вторая — отсутствие адреса.
  -- Если Supabase однажды поменяет форму claim, останется вторая;
  -- если появится анонимный аккаунт с почтой — останется первая.
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
    raise exception 'UC_NOT_ANONYMOUS: Билет привязывается только к анонимному входу — выйдите из корпоративного аккаунта';
  end if;

  if coalesce(auth.email(), '') <> '' then
    raise exception 'UC_NOT_ANONYMOUS: У этой сессии есть почтовый адрес — привязка билета к ней запрещена';
  end if;

  -- Билет не помечается использованным, а удаляется: предъявить
  -- повторно нечего, и не остаётся поля с точным временем погашения,
  -- которое можно было бы сопоставлять с появлением сессии.
  delete from access_grants
   where code_hash  = hash_corporate_email(normalize_grant_code(p_code))
     and expires_on >= current_date
  returning * into v_grant;

  if not found then
    raise exception 'UC_BAD_GRANT: Код не найден, уже использован или истёк';
  end if;

  insert into anonymous_sessions (id, company_id)
       values (v_uid, v_grant.company_id)
  on conflict (id) do update set company_id = excluded.company_id;

  return v_grant.company_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- B2C: личный аккаунт заводит себе сессию сам.
--
-- Здесь анонимность устроена иначе, и это не недосмотр. B2C-подписчик
-- хочет обратного: чтобы история сохранялась между устройствами, чтобы
-- её можно было выгрузить и удалить по своей воле. Анонимность, которую
-- он покупает, — это анонимность от работодателя, а работодатель в этом
-- сценарии просто не участвует: company_id пуст, ни в один агрегат такие
-- разговоры не попадают.
-- ─────────────────────────────────────────────────────────────

create or replace function start_personal_session()
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'UC_NOT_AUTHENTICATED: Нет сессии';
  end if;

  -- Анонимный вход сюда не пускаем: у анонимной сессии путь один — через
  -- билет. Иначе достаточно было бы нажать «войти анонимно», чтобы
  -- пользоваться корпоративным продуктом, не будучи ничьим сотрудником.
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'UC_ANONYMOUS: Анонимная сессия создаётся билетом компании, а не этой функцией';
  end if;

  insert into anonymous_sessions (id, company_id)
       values (v_uid, null)
  on conflict (id) do nothing;

  return v_uid;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Риск по одному сообщению.
--
-- Вход — обезличенные маркеры, которые извлёк ИИ-слой:
--   {"exhaustion": 0.7, "workload": 0.4, "conflict": 0.1,
--    "hopelessness": 0.2, "tags": ["переработки"]}
-- Выход — 0…100.
--
-- Веса ниже — рабочая заготовка, а не истина: соотношение осей должен
-- утверждать человек с психологической экспертизой, и менять его можно
-- без выката приложения, потому что считает базу, а не клиент.
-- ─────────────────────────────────────────────────────────────

create or replace function message_risk(p_markers jsonb)
returns numeric
language sql
immutable
as $$
  select round(
    least(100, greatest(0,
      100 * (
          0.35 * coalesce((p_markers ->> 'exhaustion')::numeric,   0)
        + 0.25 * coalesce((p_markers ->> 'workload')::numeric,     0)
        + 0.20 * coalesce((p_markers ->> 'hopelessness')::numeric, 0)
        + 0.20 * coalesce((p_markers ->> 'conflict')::numeric,     0)
      )
    )), 1);
$$;

-- ─────────────────────────────────────────────────────────────
-- Пересчёт агрегатов.
--
-- Это единственное место в системе, где сообщения и компания
-- встречаются в одном запросе. Функция ничего не возвращает наружу,
-- кроме числа записанных строк: она пишет в hr_aggregates и на этом
-- заканчивается. Дашборд HR читает результат и не имеет доступа к
-- источнику — если бы он умел считать сам, он умел бы посчитать и срез
-- по одному человеку.
-- ─────────────────────────────────────────────────────────────

create or replace function recompute_hr_aggregates(
  p_company    uuid,
  p_period_end date default current_date
)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_days       integer := setting('risk_window_days')::integer;
  v_start      date    := p_period_end - v_days;
  v_prev_start date    := p_period_end - (v_days * 2);
  v_rows       integer;
begin
  with base as (
    select c.department_tag       as dep,
           c.anonymous_session_id as session_id,
           m.stress_markers       as markers,
           m.created_at           as at
      from conversations c
      join messages m on m.conversation_id = c.id
     where c.company_id     = p_company
       -- Только реплики человека. Ответы модели тоже проходят через
       -- разметку, и если их учитывать, риск отдела начнёт зависеть от
       -- того, насколько сочувственно сформулирован ответ бота.
       and m.role           = 'user'
       and m.stress_markers is not null
       and m.created_at    >= v_prev_start
       and m.created_at     < p_period_end + 1
  ),
  -- Два набора строк: по отделам и одна общая, с пустым department_tag.
  --
  -- Общая нужна затем, что отдел, не набравший порог, просто исчезает с
  -- дашборда, и HR читает это как «там спокойно». На деле там может быть
  -- что угодно — данных лишь недостаточно, чтобы показать их безопасно.
  -- Общая строка показывает охват целиком, не давая разложить остаток по
  -- отделам.
  --
  -- В общую попадают и те, кто отдел не указал: на охват это влияет, а
  -- на анонимность нет — в срезе по всей компании никого не выделить по
  -- определению. В разбивку по отделам они по-прежнему не идут, и это
  -- соблюдение их выбора: не указав отдел, человек сказал «не считайте
  -- меня в срезе».
  cur as (
    select dep,
           avg(message_risk(markers))  as risk,
           count(distinct session_id)  as n
      from base
     where at >= v_start and dep is not null
     group by dep
    union all
    select null::text,
           avg(message_risk(markers)),
           count(distinct session_id)
      from base
     where at >= v_start
  ),
  prev as (
    select dep, avg(message_risk(markers)) as risk
      from base
     where at < v_start and dep is not null
     group by dep
    union all
    select null::text, avg(message_risk(markers))
      from base
     where at < v_start
  )
  insert into hr_aggregates (
    company_id, department_tag, period_start, period_end,
    risk_score, trend_direction, sample_size
  )
  select p_company,
         cur.dep,
         v_start,
         p_period_end,
         round(cur.risk, 1),
         case
           when prev.risk is null              then 'flat'
           -- Полоса нечувствительности в 5 пунктов. Без неё стрелка
           -- «вырос» загорается от разницы в полпункта, HR приходит с
           -- вопросом, а объяснить нечего — это шум. Стрелка должна
           -- означать «есть о чём говорить», иначе ей перестают верить.
           when cur.risk - prev.risk >  5      then 'up'
           when prev.risk - cur.risk >  5      then 'down'
           else                                    'flat'
         end::trend_direction,
         cur.n
    -- is not distinct from, а не =: у общей строки dep пуст с обеих
    -- сторон, а обычное сравнение двух null даёт null, и предыдущий
    -- период к ней бы не подцепился — тренд всегда показывал бы «без
    -- изменений».
    from cur left join prev on prev.dep is not distinct from cur.dep
   where cur.risk is not null
  on conflict (company_id, department_tag, period_start, period_end)
  do update set risk_score      = excluded.risk_score,
                trend_direction = excluded.trend_direction,
                sample_size     = excluded.sample_size,
                computed_at     = now();

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Полный контроль над своими данными (экран настроек).
--
-- Обе функции сознательно без security definer: они работают ровно с
-- тем, что видит сам пользователь через RLS. Функция с повышенными
-- правами здесь была бы лишним ключом от чужих данных ради удобства.
-- ─────────────────────────────────────────────────────────────

create or replace function export_my_data()
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'exported_at', now(),
    'session_id',  auth.uid(),
    'conversations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'started_at',     c.started_at,
               'department_tag', c.department_tag,
               'messages', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'role',       m.role,
                          'content',    m.content,
                          'created_at', m.created_at
                        ) order by m.created_at)
                   from messages m where m.conversation_id = c.id
               ), '[]'::jsonb)
             ) order by c.started_at)
        from conversations c
    ), '[]'::jsonb),
    'mood_entries', coalesce((
      select jsonb_agg(jsonb_build_object(
               'mood', e.mood, 'note', e.note, 'created_at', e.created_at
             ) order by e.created_at)
        from mood_entries e
    ), '[]'::jsonb)
  );
$$;

create or replace function delete_my_data()
returns void
language sql
volatile
set search_path = public
as $$
  -- Достаточно удалить сессию: разговоры, сообщения и записи дневника
  -- уходят по on delete cascade.
  --
  -- Право на вход при этом не трогается — и не может быть тронуто:
  -- отсюда до employee_access дороги нет. Побочный, но правильный
  -- эффект: удалив переписку, человек не теряет доступ к продукту и не
  -- освобождает место в тарифе, то есть «удалиться» не выглядит для
  -- работодателя как событие.
  delete from anonymous_sessions where id = auth.uid();
$$;
