-- Демонстрационные данные Undercurrent.
--
-- НЕ ЧАСТЬ СХЕМЫ. Это отдельный файл, который выполняется вручную и
-- только на демо-стенде. На боевом проекте его запускать нельзя: он
-- создаёт фиктивные учётные записи в auth.users и переписку, которой
-- никто не писал.
--
-- Зачем нужен. Пустой дашборд HR ничего не доказывает — он выглядит
-- одинаково и когда всё хорошо, и когда продукт не работает. Посев даёт
-- картину, на которой видно главное: отделы с разными трендами и два
-- отдела, скрытых порогом анонимности.
--
-- Что получится:
--
--   Отдел          Людей  Риск   Тренд     Виден HR
--   ─────────────────────────────────────────────────
--   Продажи          7    ~72    вырос     да
--   Разработка       6    ~42    ровно     да
--   Поддержка        5    ~69    снизился  да
--   Маркетинг        3     —     —         НЕТ, порог
--   Финансы          2     —     —         НЕТ, порог
--   ─────────────────────────────────────────────────
--   Компания        23    ~58              да
--
-- Маркетинг и финансы здесь не для полноты, а ради демонстрации: на
-- дашборде их не будет, но общий охват покажет 23 человека против 18
-- разложенных по отделам. Разницу в 5 человек видно, а кто это — нет.

-- ⚠ ДАННЫЕ СТАРЕЮТ. Риск считается в скользящем окне в две недели, и
-- через две недели после посева «предыдущее окно» уезжает за край
-- данных: сравнивать становится не с чем, тренды превращаются в «без
-- изменений», дельта исчезает. Выглядит как сломанная аналитика.
--
-- Перед каждым показом запускайте supabase/refresh-demo.sql — он
-- сдвигает даты к сегодняшнему дню и пересчитывает.

begin;

do $$
declare
  v_company uuid;
  v_dep     record;
  v_user    uuid;
  v_conv    uuid;
  v_jitter  numeric;
  i         integer;
begin
  insert into companies (name, email_domain, tariff_tier, billing_period)
  values ('NomadTech', 'nomadtech.kz', 'growth_500', 'half_year')
  returning id into v_company;

  raise notice 'Компания NomadTech создана: %', v_company;

  -- Профиль каждого отдела: сколько человек и какие маркеры в текущем
  -- окне (e1…c1) и в предыдущем (e0…c0). Разница между окнами и даёт
  -- стрелку тренда — она считается, а не проставляется руками.
  for v_dep in
    select * from (values
      ('sales',       7, 0.90, 0.80, 0.60, 0.40,  0.70, 0.60, 0.40, 0.30),
      ('engineering', 6, 0.60, 0.50, 0.20, 0.20,  0.60, 0.50, 0.20, 0.15),
      ('support',     5, 0.85, 0.70, 0.50, 0.60,  0.95, 0.90, 0.70, 0.70),
      ('marketing',   3, 0.50, 0.40, 0.20, 0.10,  0.45, 0.40, 0.15, 0.10),
      ('finance',     2, 0.40, 0.30, 0.10, 0.10,  0.40, 0.35, 0.10, 0.10)
    ) as t(dep, n, e1, w1, h1, c1, e0, w0, h0, c0)
  loop
    for i in 1..v_dep.n loop
      -- Разброс по людям, но детерминированный: random() дал бы каждый
      -- раз новые цифры, и «риск изменился» после повторного посева
      -- нельзя было бы отличить от настоящего изменения логики.
      v_jitter := ((i % 3) - 1) * 0.05;

      -- Анонимная учётная запись — ровно то, что создаёт Supabase при
      -- signInAnonymously: без почты, без пароля, с признаком
      -- is_anonymous. Ничего, что связывало бы её с человеком, здесь
      -- нет и на живом проекте тоже не появится.
      insert into auth.users (id, instance_id, aud, role, is_anonymous)
      values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
              'authenticated', 'authenticated', true)
      returning id into v_user;

      insert into anonymous_sessions (id, company_id)
      values (v_user, v_company);

      insert into conversations (anonymous_session_id, company_id, department_tag, started_at)
      values (v_user, v_company, v_dep.dep, now() - interval '25 days')
      returning id into v_conv;

      -- Предыдущее окно: 14–28 дней назад.
      insert into messages (conversation_id, role, content, stress_markers, created_at)
      values (
        v_conv, 'user',
        'Демо-сообщение (прошлый период). Настоящей переписки здесь нет.',
        jsonb_build_object(
          'exhaustion',   greatest(0, least(1, v_dep.e0 + v_jitter)),
          'workload',     greatest(0, least(1, v_dep.w0 + v_jitter)),
          'hopelessness', greatest(0, least(1, v_dep.h0 + v_jitter)),
          'conflict',     greatest(0, least(1, v_dep.c0 + v_jitter))
        ),
        now() - interval '20 days'
      );

      -- Текущее окно: последние 14 дней.
      insert into messages (conversation_id, role, content, stress_markers, created_at)
      values (
        v_conv, 'user',
        'Демо-сообщение (текущий период). Настоящей переписки здесь нет.',
        jsonb_build_object(
          'exhaustion',   greatest(0, least(1, v_dep.e1 + v_jitter)),
          'workload',     greatest(0, least(1, v_dep.w1 + v_jitter)),
          'hopelessness', greatest(0, least(1, v_dep.h1 + v_jitter)),
          'conflict',     greatest(0, least(1, v_dep.c1 + v_jitter))
        ),
        now() - interval '3 days'
      );

      -- Ответ собеседника — без разметки, как и в бою: иначе риск отдела
      -- зависел бы от того, насколько сочувственно отвечает модель.
      insert into messages (conversation_id, role, content, stress_markers, created_at)
      values (v_conv, 'assistant', 'Демо-ответ собеседника.', null, now() - interval '3 days');
    end loop;

    raise notice '  отдел % — % человек', v_dep.dep, v_dep.n;
  end loop;

  perform recompute_hr_aggregates(v_company);
  raise notice 'Агрегаты пересчитаны.';
end $$;

commit;

-- ═══════════════════════════════════════════════════════════════
-- Что посеялось
-- ═══════════════════════════════════════════════════════════════

select coalesce(d.title_ru, '── ВСЯ КОМПАНИЯ ──') as "Отдел",
       a.sample_size                              as "Людей",
       a.risk_score                               as "Риск",
       a.trend_direction                          as "Тренд",
       case when a.sample_size >= setting('min_sample_size')::int
            then 'виден' else 'СКРЫТ порогом' end as "На дашборде"
  from hr_aggregates a
  left join departments d on d.slug = a.department_tag
 order by a.department_tag nulls first;

-- ═══════════════════════════════════════════════════════════════
-- HR-аккаунт
--
-- Автоматически не создаётся: hr_accounts ссылается на auth.users, а
-- полноценную учётную запись с паролем заводит Supabase Auth, а не SQL.
-- Подделать её здесь можно, но получится запись, под которой нельзя
-- войти, — и полчаса уйдёт на выяснение, почему.
--
-- Правильный порядок:
--   1. Зарегистрируйтесь в приложении как «Личная подписка»
--      с почтой вида hr@nomadtech.kz
--   2. Выполните это, подставив свою почту:
--
--   insert into hr_accounts (user_id, company_id, full_name)
--   select u.id,
--          (select id from companies where email_domain = 'nomadtech.kz'),
--          'Демо HR'
--     from auth.users u
--    where u.email = 'hr@nomadtech.kz';
--
--   3. Перезайдите в приложении — вместо чата появятся «Риски» и «Тариф».
--
-- Учтите: шаг 1 создаст ещё и личную сессию B2C. Это не мешает, но если
-- хотите чистый HR-аккаунт, удалите её:
--   delete from anonymous_sessions
--    where id = (select id from auth.users where email = 'hr@nomadtech.kz');
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- Убрать демо-данные целиком
--
-- Каскады сделают остальное: удаление auth.users уносит сессии,
-- разговоры и сообщения, удаление компании — агрегаты.
--
--   delete from auth.users
--    where is_anonymous
--      and id in (select id from anonymous_sessions
--                  where company_id = (select id from companies
--                                       where email_domain = 'nomadtech.kz'));
--   delete from companies where email_domain = 'nomadtech.kz';
-- ═══════════════════════════════════════════════════════════════
