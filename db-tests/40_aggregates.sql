-- Сценарий 3 — агрегаты и порог k-анонимности.
--
-- Проверяем то, что HR реально увидит на дашборде, и — важнее — чего он
-- не увидит. Отдел из двух человек не должен появиться в отчёте ни при
-- каких обстоятельствах: «риск в отделе финансов 58» при двух
-- сотрудниках — это высказывание о конкретных людях.

do $$ begin raise notice 'Сценарий 3 — агрегаты по отделам и порог выборки'; end $$;

-- ── Посев ─────────────────────────────────────────────────────
--
-- От имени postgres: прямой insert в anonymous_sessions клиенту закрыт
-- (сессия заводится только билетом), а здесь мы имитируем результат
-- десятка успешных входов, не прогоняя выдачу билетов десять раз.

insert into anonymous_sessions (id, company_id)
select ('22222222-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       '33333333-0000-0000-0000-000000000001'
  from generate_series(3, 9) as i;

-- Продажи: шесть разных сессий (вместе с той, что создал сценарий 1).
-- Финансы: две. Порог min_sample_size = 5.
insert into conversations (id, anonymous_session_id, company_id, department_tag, started_at)
select ('44444444-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       ('22222222-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       '33333333-0000-0000-0000-000000000001',
       case when i <= 7 then 'sales' else 'finance' end,
       now() - interval '3 days'
  from generate_series(3, 9) as i;

-- Текущее окно: тяжёлые маркеры.
insert into messages (conversation_id, role, content, stress_markers, created_at)
select ('44444444-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'user',
       'Не вывожу нагрузку',
       '{"exhaustion": 0.8, "workload": 0.9, "hopelessness": 0.3, "conflict": 0.1}',
       now() - interval '3 days'
  from generate_series(3, 9) as i;

-- Предыдущее окно: те же люди, но спокойнее. Нужно, чтобы тренд считался
-- по сравнению, а не выставлялся в 'flat' за неимением истории.
--
-- В продажах прошлый уровень 16.0 — достаточный, чтобы процент роста
-- что-то значил.
insert into messages (conversation_id, role, content, stress_markers, created_at)
select ('44444444-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'user',
       'Обычная неделя',
       '{"exhaustion": 0.2, "workload": 0.2, "hopelessness": 0.1, "conflict": 0.1}',
       now() - interval '20 days'
  from generate_series(3, 7) as i;

-- В финансах прошлый уровень нарочно почти нулевой: 100 × (0.35·0.1 +
-- 0.25·0.1) = 6.0. Это проверяет защиту от процента, посчитанного от
-- малой базы: рост с 6.0 до 58.5 формально «+875 %», а содержательно
-- означает лишь, что раньше там почти ничего не писали. Дельта в таком
-- случае должна остаться пустой.
insert into messages (conversation_id, role, content, stress_markers, created_at)
select ('44444444-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'user',
       'Всё спокойно',
       '{"exhaustion": 0.1, "workload": 0.1, "hopelessness": 0, "conflict": 0}',
       now() - interval '20 days'
  from generate_series(8, 9) as i;

-- Ответы модели с разметкой: они не должны попасть в расчёт. Маркеры
-- нарочно зашкаливающие — если фильтр по role сломается, риск отдела
-- взлетит, и тест это поймает.
insert into messages (conversation_id, role, content, stress_markers, created_at)
select ('44444444-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       'assistant',
       'Слышу вас. Что из этого можно отложить?',
       '{"exhaustion": 1, "workload": 1, "hopelessness": 1, "conflict": 1}',
       now() - interval '3 days'
  from generate_series(3, 9) as i;

-- ── Расчёт ────────────────────────────────────────────────────

select t_eq(
  recompute_hr_aggregates('33333333-0000-0000-0000-000000000001'),
  3,
  'посчитаны два отдела и общий срез по компании');

do $$
declare
  v_sales   hr_aggregates;
  v_finance hr_aggregates;
  v_all     hr_aggregates;
begin
  select * into v_sales   from hr_aggregates where department_tag = 'sales';
  select * into v_finance from hr_aggregates where department_tag = 'finance';
  select * into v_all     from hr_aggregates where department_tag is null;

  perform t_eq(v_sales.sample_size,   6, 'в продажах шесть разных сессий');
  perform t_eq(v_finance.sample_size, 2, 'в финансах две сессии');
  -- Общий срез включает и тех, кто отдел не указал: охват компании
  -- считается по людям, а не по заполненным полям.
  perform t_eq(v_all.sample_size,     8, 'общий охват — восемь сессий');

  -- 100 × (0.35·0.8 + 0.25·0.9 + 0.20·0.3 + 0.20·0.1) = 58.5
  -- Если бы в расчёт попали реплики модели, вышло бы заметно выше.
  perform t_eq(v_sales.risk_score, 58.5::numeric(4,1), 'риск продаж посчитан по репликам человека');
  perform t_eq(v_sales.trend_direction, 'up'::trend_direction, 'тренд вырос относительно прошлого окна');

  -- Прошлое окно: 100 × (0.35·0.2 + 0.25·0.2 + 0.20·0.1 + 0.20·0.1) = 16.0
  -- Изменение: 100 × (58.5 − 16.0) / 16.0 = 265.6 → 266 %
  perform t_eq(v_sales.risk_delta_pct, 266, 'относительное изменение риска посчитано');

  -- Знак дельты обязан совпадать с направлением тренда. Разойтись они
  -- могут только при ошибке в расчёте, и на дашборде это выглядело бы
  -- как «↑ вырос (−12 %)» — цифра, после которой не верят всему экрану.
  perform t_eq(v_sales.risk_delta_pct > 0, true, 'знак дельты совпадает с направлением тренда');

  -- Финансы выросли с 6.0 до 58.5 — это «+875 %», и такой цифры на
  -- дашборде быть не должно. Пусто, а не ноль: ноль означал бы
  -- «измерили и не изменилось», а здесь измерять было не от чего.
  perform t_eq(v_finance.risk_delta_pct is null, true, 'процент от малой базы не считается');
  -- При этом сам факт роста не теряется: направление тренда работает
  -- на разнице в пунктах и защиты не требует.
  perform t_eq(v_finance.trend_direction, 'up'::trend_direction, 'рост в финансах виден направлением');
end $$;

-- ── Что из этого дойдёт до HR ─────────────────────────────────

select t_as('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz', false);
set role authenticated;

select t_eq((select count(*)::int from hr_aggregates), 2, 'HR видит два среза из трёх посчитанных');
select t_eq(
  (select department_tag from hr_aggregates where department_tag is not null),
  'sales',
  'виден отдел, где выборка достаточна');
select t_eq(
  (select count(*)::int from hr_aggregates where department_tag = 'finance'),
  0,
  'отдел из двух человек скрыт порогом');

-- Общий срез виден, и по нему HR понимает, что охват шире того, что
-- разложено по отделам: 8 человек всего против 6 в единственном
-- видимом отделе. Остаток существует, но неразличим — ровно так и надо.
select t_eq(
  (select sample_size from hr_aggregates where department_tag is null),
  8,
  'общий охват виден и больше суммы видимых отделов');

reset role;

-- ── Порог живёт в базе, а не в дашборде ───────────────────────
--
-- Поднимаем порог до семи и убеждаемся, что продажи тоже исчезают. Это
-- проверка не арифметики, а места, где принимается решение: если бы
-- фильтр стоял в клиенте, изменение настройки ничего бы не изменило,
-- и то же самое было бы верно для человека, открывшего консоль браузера.

update app_settings set value = 7 where key = 'min_sample_size';

select t_as('11111111-0000-0000-0000-000000000003', 'hr@nomadtech.kz', false);
set role authenticated;

select t_eq(
  (select count(*)::int from hr_aggregates where department_tag is not null),
  0,
  'при пороге 7 скрываются и продажи');
select t_eq(
  (select count(*)::int from hr_aggregates where department_tag is null),
  1,
  'общий срез по компании из восьми человек остаётся');

reset role;

update app_settings set value = 5 where key = 'min_sample_size';

-- ── Чужая компания ────────────────────────────────────────────

insert into companies (id, name, email_domain, tariff_tier)
values ('33333333-0000-0000-0000-000000000002', 'Другая компания', 'other.kz', 'small_20');

insert into auth.users (id, email, is_anonymous)
values ('11111111-0000-0000-0000-000000000005', 'hr@other.kz', false);

insert into hr_accounts (user_id, company_id)
values ('11111111-0000-0000-0000-000000000005', '33333333-0000-0000-0000-000000000002');

select t_as('11111111-0000-0000-0000-000000000005', 'hr@other.kz', false);
set role authenticated;

select t_eq((select count(*)::int from hr_aggregates), 0, 'HR чужой компании не видит наши срезы');

reset role;

do $$ begin raise notice 'Сценарий 3 пройден'; end $$;
