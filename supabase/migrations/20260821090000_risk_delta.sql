-- Относительное изменение риска — та самая цифра «+34%» с лендинга.
--
-- Продукт до сих пор показывал уровень (71.5) и направление («вырос»),
-- но не величину движения. Лендинг обещает именно её, и это не придирка
-- к формулировке: уровень и изменение отвечают на разные вопросы.
-- «Риск 71» — это «здесь тяжело». «+34%» — это «здесь стало тяжело
-- недавно», то есть повод искать причину в последних решениях компании.
--
-- Храним в базе, а не считаем на клиенте: предыдущее окно живёт внутри
-- функции пересчёта и наружу не выдаётся. Клиенту пришлось бы искать
-- строку прошлого периода, а её может не быть вовсе — пересчёт мог ни
-- разу не запускаться в то время.

alter table hr_aggregates
  add column risk_delta_pct integer;

comment on column hr_aggregates.risk_delta_pct is
  'Относительное изменение риска к прошлому окну, в процентах. '
  'null, если сравнивать не с чем или прошлый уровень слишком мал.';

-- ─────────────────────────────────────────────────────────────
-- Пересчёт с дельтой
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
       and m.role           = 'user'
       and m.stress_markers is not null
       and m.created_at    >= v_prev_start
       and m.created_at     < p_period_end + 1
  ),
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
    risk_score, trend_direction, sample_size, risk_delta_pct
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
         cur.n,
         -- Порог 10 на прошлый уровень — защита от арифметики, которая
         -- формально верна и содержательно пуста. Рост риска с 2 до 4 —
         -- это «+100%», но означает лишь, что раньше почти никто ничего
         -- не писал. HR, увидев такую цифру, побежит спасать отдел,
         -- в котором ничего не происходит.
         case
           when prev.risk is null or prev.risk < 10 then null
           else round(100 * (cur.risk - prev.risk) / prev.risk)::integer
         end
    from cur
    left join prev on prev.dep is not distinct from cur.dep
   where cur.risk is not null
  on conflict (company_id, department_tag, period_start, period_end)
  do update set risk_score      = excluded.risk_score,
                trend_direction = excluded.trend_direction,
                sample_size     = excluded.sample_size,
                risk_delta_pct  = excluded.risk_delta_pct,
                computed_at     = now();

  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;
