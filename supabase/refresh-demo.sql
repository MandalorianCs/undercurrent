-- Обновление демо-данных перед показом.
--
-- ЗАЧЕМ. Риск считается в скользящем окне: текущие две недели против
-- предыдущих двух. Посев расставляет сообщения относительно дня, когда
-- его запустили, — и через две недели «предыдущее окно» уезжает за край
-- данных. Сравнивать становится не с чем, все тренды превращаются в
-- «без изменений», а дельта исчезает.
--
-- Снаружи это выглядит как сломанная аналитика, хотя данные на месте и
-- расчёт верен. Дважды подряд перед демо это неприятный сюрприз.
--
-- Запускать перед каждым показом. Идемпотентно: можно сколько угодно раз.

begin;

-- ── 1. Сдвигаем сообщения к сегодняшнему дню ──────────────────
--
-- Опознаём по тексту: посев пишет в него, к какому периоду относится
-- сообщение. Это надёжнее, чем считать по датам, — даты и есть то, что
-- мы правим.

update messages m
   set created_at = now() - interval '20 days'
  from conversations c
 where c.id = m.conversation_id
   and c.company_id is not null
   and m.content like '%прошлый период%';

update messages m
   set created_at = now() - interval '3 days'
  from conversations c
 where c.id = m.conversation_id
   and c.company_id is not null
   and m.content like '%текущий период%';

-- Ответы собеседника тянем за текущим окном: они в расчёт не идут, но
-- в выгрузке и в чате должны стоять рядом с репликой, а не в прошлом.
update messages m
   set created_at = now() - interval '3 days' + interval '1 minute'
  from conversations c
 where c.id = m.conversation_id
   and c.company_id is not null
   and m.role = 'assistant';

update conversations
   set started_at = now() - interval '25 days'
 where company_id is not null
   and started_at < now() - interval '25 days';

-- ── 2. Убираем срезы за старые окна ───────────────────────────
--
-- Дашборд показывает самый свежий период, но старые строки копятся при
-- каждом пересчёте и мешают смотреть в базу глазами.

delete from hr_aggregates where period_end < current_date - 1;

-- ── 3. Пересчитываем ──────────────────────────────────────────

select recompute_hr_aggregates(id) from companies;

commit;

-- ── Что получилось ────────────────────────────────────────────
--
-- Продажи должны показать заметный рост, поддержка — снижение,
-- разработка — ровно. Маркетинг и финансы не должны быть видны HR:
-- их выборка ниже порога.

select coalesce(d.title_ru, '── ВСЯ КОМПАНИЯ ──')       as "Отдел",
       a.sample_size                                     as "Людей",
       a.risk_score                                      as "Риск",
       a.trend_direction                                 as "Тренд",
       coalesce(a.risk_delta_pct::text || ' %', '—')     as "Изменение",
       case when a.sample_size >= setting('min_sample_size')::int
            then 'виден' else 'СКРЫТ порогом' end        as "На дашборде"
  from hr_aggregates a
  left join departments d on d.slug = a.department_tag
 order by a.department_tag nulls first;
