# Expo HAS CHANGED

Read the exact versioned docs at https://docs.expo.dev/versions/v57.0.0/ before writing any code.

# Правило, которое нельзя нарушить

Между `employee_access` / `access_grants` (кто имеет право войти) и
`conversations` / `messages` / `mood_entries` (что человек написал) не
должно появиться ни одной связи: ни внешнего ключа, ни общей колонки,
ни «временного поля для отладки».

Если задача выглядит так, что её удобно решить такой связью, — задача
поставлена неверно. Обсудите её с человеком, не решайте сами.

Проверка живёт в `db-tests/30_isolation.sql` и обязана оставаться
зелёной: `npm run test:db`.
