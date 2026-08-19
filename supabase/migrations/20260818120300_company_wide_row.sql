-- Общий срез по компании — строка с department_tag = null.
--
-- Зачем понадобилась. Отдел, не набравший порог, просто исчезает из
-- дашборда, и HR читает это как «там всё спокойно». На самом деле там
-- может быть что угодно — данных просто недостаточно, чтобы показать их
-- безопасно. Разница между «спокойно» и «не показываем» существенна:
-- в первом случае HR ничего не делает и прав, во втором — ничего не
-- делает и не прав.
--
-- Общая строка закрывает дыру, не открывая новой: HR видит, скольких
-- людей охватывает картина целиком, и понимает, что остаток
-- существует, — но разложить остаток по отделам не может.

-- ─────────────────────────────────────────────────────────────
-- Уникальность с учётом null
--
-- В обычном уникальном ограничении два null считаются разными
-- значениями, поэтому on conflict для общей строки не сработал бы и
-- каждый пересчёт добавлял бы дубль. NULLS NOT DISTINCT (Postgres 15+)
-- заставляет считать их одинаковыми.
-- ─────────────────────────────────────────────────────────────

alter table hr_aggregates
  drop constraint hr_aggregates_company_id_department_tag_period_start_period_end_key;

create unique index hr_aggregates_slice_key
  on hr_aggregates (company_id, department_tag, period_start, period_end)
  nulls not distinct;

-- ─────────────────────────────────────────────────────────────
-- Пересчёт: отделы + компания целиком
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
    select c.department_tag        as dep,
           c.anonymous_session_id  as session_id,
           m.stress_markers        as markers,
           m.created_at            as at
      from conversations c
      join messages m on m.conversation_id = c.id
     where c.company_id     = p_company
       and m.role           = 'user'
       and m.stress_markers is not null
       and m.created_at    >= v_prev_start
       and m.created_at     < p_period_end + 1
  ),
  -- Два набора строк: по отделам и одна общая. В общую попадают и те,
  -- кто отдел не указал, — на охват это влияет, а на анонимность нет:
  -- в срезе по всей компании никого не выделить по определению.
  cur as (
    select dep,
           avg(message_risk(markers))    as risk,
           count(distinct session_id)    as n
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
           when prev.risk is null         then 'flat'
           when cur.risk - prev.risk >  5 then 'up'
           when prev.risk - cur.risk >  5 then 'down'
           else                                'flat'
         end::trend_direction,
         cur.n
    from cur
    left join prev on prev.dep is not distinct from cur.dep
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
-- Политика: общая строка порогом не режется
--
-- Она и не может его нарушить — в ней вся компания. Но условие
-- sample_size >= порога применяется ко всем строкам одинаково, и для
-- компании из трёх человек общая строка была бы скрыта тоже. Это
-- правильно: в компании из трёх человек анонимности нет вообще, и
-- показывать там нечего.
-- Отдельного исключения не делаем — старая политика подходит как есть.
-- ─────────────────────────────────────────────────────────────
