-- Undercurrent — Row Level Security.
--
-- Приложение ходит в базу напрямую с anon-ключом, который лежит в APK и
-- в JS веб-версии, то есть публично. Всё, что отделяет чужие данные от
-- пользователя, — политики ниже. Это не «дополнительный уровень
-- защиты», это единственный уровень.
--
-- Как здесь выражено главное обещание продукта. Можно было написать
-- «HR не имеет права читать conversations» отдельным правилом. Не
-- написано — и это осознанно. Правило на conversations ровно одно:
--
--     anonymous_session_id = auth.uid()
--
-- HR-аккаунт не является ничьей анонимной сессией, поэтому не проходит
-- условие и получает ноль строк. Запрет для HR — не отдельная сущность,
-- которую нужно помнить и обновлять при каждом рефакторинге, а следствие
-- единственного правила доступа. Отдельное правило можно случайно
-- ослабить; следствие — нельзя, не сломав доступ самому сотруднику,
-- что заметят в тот же день.

alter table app_settings           enable row level security;
alter table companies              enable row level security;
alter table departments            enable row level security;
alter table employee_access        enable row level security;
alter table access_grants          enable row level security;
alter table anonymous_sessions     enable row level security;
alter table conversations          enable row level security;
alter table messages               enable row level security;
alter table mood_entries           enable row level security;
alter table hr_accounts            enable row level security;
alter table hr_aggregates          enable row level security;
alter table personal_subscriptions enable row level security;

-- ─────────────────────────────────────────────────────────────
-- Левая половина схемы: ни одной политики
--
-- У employee_access и access_grants политик нет вообще. При включённом
-- RLS это означает полный отказ: ни select, ни insert, ни update через
-- API невозможны никому — ни сотруднику, ни HR, ни B2C-подписчику.
-- Работают с ними только функции issue_access_grant / bind_access_grant,
-- у которых security definer, и обе устроены так, что наружу не отдают
-- ничего, кроме кода билета и id компании.
--
-- Отзыв привилегий поверх RLS — вторая линия на случай будущей ошибки:
-- если кто-нибудь однажды добавит сюда политику «для отладки», она не
-- сработает, потому что у ролей нет самих прав на таблицу.
-- ─────────────────────────────────────────────────────────────

revoke all on employee_access from anon, authenticated;
revoke all on access_grants  from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Справочники
-- ─────────────────────────────────────────────────────────────

-- Список отделов нужен на экране старта чата.
create policy departments_read on departments
  for select to authenticated using (true);

-- Пороги видны всем намеренно. Продукт про доверие не может прятать
-- от пользователя число, при котором его срез перестаёт показываться
-- HR: это ровно та цифра, которую он захочет проверить.
create policy app_settings_read on app_settings
  for select to authenticated using (true);

-- ─────────────────────────────────────────────────────────────
-- Компании
-- ─────────────────────────────────────────────────────────────

-- Компанию видит её HR (экран тарифа) и сотрудник, чья анонимная сессия
-- к ней привязана (название в шапке чата — «вы пишете как сотрудник
-- такой-то компании»). Список всех компаний-клиентов не виден никому:
-- кто подключил Undercurrent — коммерческая информация клиента, а не
-- наша витрина.
create policy companies_read_related on companies
  for select to authenticated
  using (
    exists (select 1 from hr_accounts h
             where h.user_id = auth.uid() and h.company_id = companies.id)
    or
    exists (select 1 from anonymous_sessions s
             where s.id = auth.uid() and s.company_id = companies.id)
  );

-- ─────────────────────────────────────────────────────────────
-- Правая половина схемы: разговоры
-- ─────────────────────────────────────────────────────────────

create policy anonymous_sessions_read_own on anonymous_sessions
  for select to authenticated
  using (id = auth.uid());

-- Удаление своей сессии — это «удалить всю мою историю» с экрана
-- настроек: разговоры, сообщения и дневник уходят каскадом.
create policy anonymous_sessions_delete_own on anonymous_sessions
  for delete to authenticated
  using (id = auth.uid());

-- Вставки нет намеренно: сессия создаётся только через bind_access_grant
-- (по билету) или start_personal_session (личная подписка). Разреши мы
-- прямой insert — любой анонимный вход заводил бы себе сессию с любым
-- company_id и попадал в чужие агрегаты.

-- ── Единственное правило доступа к переписке ──────────────────

create policy conversations_own on conversations
  for all to authenticated
  using (anonymous_session_id = auth.uid())
  with check (anonymous_session_id = auth.uid());

create policy messages_own on messages
  for all to authenticated
  using (
    exists (select 1 from conversations c
             where c.id = messages.conversation_id
               and c.anonymous_session_id = auth.uid())
  )
  with check (
    exists (select 1 from conversations c
             where c.id = messages.conversation_id
               and c.anonymous_session_id = auth.uid())
  );

create policy mood_entries_own on mood_entries
  for all to authenticated
  using (session_id = auth.uid())
  with check (session_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- HR
-- ─────────────────────────────────────────────────────────────

create policy hr_accounts_read_own on hr_accounts
  for select to authenticated
  using (user_id = auth.uid());

-- Агрегаты своей компании — и только те, где выборка достаточна.
--
-- Порог отсекается здесь, а не в дашборде. Разница видна в тот момент,
-- когда кто-то откроет консоль браузера и повторит запрос руками: из
-- дашборда можно убрать фильтр, из политики — нет. В отделе из двух
-- человек строка «риск 82, тренд вверх» — это сообщение о конкретном
-- человеке, каким бы обезличенным ни выглядел её формат.
create policy hr_aggregates_read_own_company on hr_aggregates
  for select to authenticated
  using (
    sample_size >= setting('min_sample_size')
    and exists (
      select 1 from hr_accounts h
       where h.user_id = auth.uid() and h.company_id = hr_aggregates.company_id
    )
  );

-- Писать в hr_aggregates не может никто: строки появляются только
-- из recompute_hr_aggregates с security definer. Иначе HR мог бы
-- сочинить себе строку с sample_size = 999 и обойти порог.

-- ─────────────────────────────────────────────────────────────
-- Личные подписки
-- ─────────────────────────────────────────────────────────────

create policy personal_subscriptions_read_own on personal_subscriptions
  for select to authenticated
  using (user_id = auth.uid());

-- Статус подписки меняет платёжный провайдер (позже — вебхуком), а не
-- клиент. Update-политики нет: иначе «активная подписка» ставилась бы
-- одним запросом из браузера.
