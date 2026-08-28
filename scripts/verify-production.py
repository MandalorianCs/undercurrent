# -*- coding: utf-8 -*-
"""
Полный путь сотрудника B2B на БОЕВОМ проекте Supabase.

Запуск:  npm run verify:prod

Чем отличается от db-tests. Те идут против чистого контейнера и
проверяют схему. Этот идёт против настоящего проекта и проверяет то,
чего в схеме нет: включён ли анонимный вход, развёрнута ли функция
companion, ведут ли себя политики так же, как локально. Схема может быть
безупречной, а продукт не работать, потому что забыли нажать
«Save changes» в дашборде.

Главное, что здесь проверяется, — не «функция вернула 200», а то, ради
чего продукт существует: после прохождения всего пути в базе не должно
остаться ничего, что связывает корпоративную почту с написанным текстом.

Требует .env.secret со служебным ключом, поэтому запускается вручную и
только тем, у кого этот ключ есть. За собой убирает: обе созданные
учётные записи удаляются в конце.
"""
import io, json, os, sys, urllib.request, urllib.error, uuid

# Консоль Windows по умолчанию не в UTF-8 — без этого отчёт нечитаем.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def from_env(filename, key):
    path = os.path.join(ROOT, filename)
    if not os.path.exists(path):
        print(f"✗ Нет файла {filename}. Он нужен для проверки боевого проекта.")
        sys.exit(1)
    for line in io.open(path, encoding="utf-8"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().rstrip("/")
    print(f"✗ В {filename} не задано {key}.")
    sys.exit(1)


SECRET = from_env(".env.secret", "SUPABASE_SECRET_KEY")
PUB    = from_env(".env", "EXPO_PUBLIC_SUPABASE_ANON_KEY")
H      = from_env(".env", "EXPO_PUBLIC_SUPABASE_URL")

log, failures = [], 0


def say(ok, label, detail=""):
    global failures
    if ok is False:
        failures += 1
    mark = "  ok    " if ok else "  ПРОВАЛ"
    log.append(f"{mark} — {label}" + (f"  ({detail})" if detail else ""))


def call(path, method="GET", body=None, token=None, key=None):
    key = key or PUB
    req = urllib.request.Request(
        f"{H}{path}", method=method,
        data=json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None,
        headers={"apikey": key, "Authorization": f"Bearer {token or key}",
                 "Content-Type": "application/json; charset=utf-8"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode("utf-8")
            return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw


corp_email = f"e2e-{uuid.uuid4().hex[:8]}@gmail.com"   # домен демо-компании
password   = "E2E-" + uuid.uuid4().hex[:12]
corp_id = anon_id = None

log.append(f"═══ ПУТЬ СОТРУДНИКА B2B · {H} ═══\n")

try:
    # ── 1. Корпоративный аккаунт ──────────────────────────────────
    log.append("▸ шаг 1 — подтверждение работы в компании")
    st, d = call("/auth/v1/admin/users", "POST",
                 {"email": corp_email, "password": password, "email_confirm": True}, key=SECRET)
    corp_id = d.get("id") if isinstance(d, dict) else None
    say(bool(corp_id), "корпоративный аккаунт создан", corp_email)

    st, d = call("/auth/v1/token?grant_type=password", "POST",
                 {"email": corp_email, "password": password})
    corp_token = d.get("access_token") if isinstance(d, dict) else None
    say(bool(corp_token), "вход по корпоративной почте")

    # ── 2. Билет ──────────────────────────────────────────────────
    log.append("\n▸ шаг 2 — одноразовый билет")
    st, grant = call("/rest/v1/rpc/issue_access_grant", "POST", {}, token=corp_token)
    say(st == 200 and isinstance(grant, str), "билет выдан",
        str(grant)[:20] if st == 200 else str(grant)[:70])

    st, d = call("/rest/v1/employee_access?select=corporate_email_hash", "GET", token=corp_token)
    say(st in (401, 403) or "denied" in str(d).lower(),
        "сам сотрудник не читает employee_access", f"HTTP {st}")

    # ── 3. Разрыв ─────────────────────────────────────────────────
    log.append("\n▸ шаг 3 — разрыв: выход и анонимный вход")
    st, d = call("/auth/v1/signup", "POST", {})
    u = d.get("user", {}) if isinstance(d, dict) else {}
    anon_token = d.get("access_token") if isinstance(d, dict) else None
    anon_id = u.get("id")
    say(bool(anon_token), "анонимный вход выполнен", str(anon_id)[:8])

    # Supabase отдаёт пустую строку, а не null — проверять на None здесь
    # значит проверять формат ответа, а не суть.
    say(not u.get("email") and not u.get("phone"), "нет ни почты, ни телефона")
    say(not u.get("identities"), "и ни одного связанного идентификатора")
    say(corp_id != anon_id, "это ДРУГАЯ учётная запись, не та же самая")

    st, bound = call("/rest/v1/rpc/bind_access_grant", "POST", {"p_code": grant}, token=anon_token)
    say(st == 200, "билет погашен, сессия привязана к компании", str(bound)[:36])

    st, again = call("/rest/v1/rpc/bind_access_grant", "POST", {"p_code": grant}, token=anon_token)
    say("UC_BAD_GRANT" in str(again), "повторно тот же билет не проходит")

    # ── 4. Разговор ───────────────────────────────────────────────
    log.append("\n▸ шаг 4 — разговор через тот же ИИ-слой, что и в боте")
    st, d = call("/functions/v1/companion", "POST",
                 {"session_id": anon_id, "text": "я совсем вымотался, работаю по ночам",
                  "department_tag": "sales"}, token=anon_token)
    say(st == 200 and bool(d.get("reply")), "ответ получен", (d.get("reply") or str(d))[:60])
    say(d.get("crisis") is False, "обычная реплика тревогу не поднимает")

    st, d = call("/functions/v1/companion", "POST",
                 {"session_id": anon_id, "text": "я больше не хочу жить"}, token=anon_token)
    say(d.get("crisis") is True, "кризисный сигнал распознан")
    say(len(d.get("contacts", [])) >= 2, "контакты кризисных служб выданы",
        ", ".join(c["number"] for c in d.get("contacts", [])))

    # ── 5. Главное: связи между половинами нет ────────────────────
    #
    # Смотрим служебным ключом, то есть с максимальными правами. Если бы
    # связь существовала, здесь бы она и нашлась.
    log.append("\n▸ шаг 5 — есть ли в базе связь между почтой и текстом")

    st, rows = call(f"/rest/v1/anonymous_sessions?select=*&id=eq.{anon_id}", "GET", key=SECRET)
    sess = rows[0] if isinstance(rows, list) and rows else {}
    say(bool(sess.get("company_id")), "сессия знает свою КОМПАНИЮ", str(sess.get("company_id"))[:8])
    leak = [k for k in sess if any(w in k for w in ("email", "mail", "phone", "employee"))]
    say(not leak, "и ничего про личность", f"колонки: {', '.join(sorted(sess))}")

    st, msgs = call("/rest/v1/messages?select=*&limit=1", "GET", key=SECRET)
    cols = set(msgs[0].keys()) if isinstance(msgs, list) and msgs else set()
    suspicious = [c for c in cols
                  if any(w in c for w in ("email", "mail", "phone", "name", "employee", "user_id"))]
    say(not suspicious, "в таблице сообщений нет колонок про личность",
        f"колонки: {', '.join(sorted(cols))}")

    st, ea = call("/rest/v1/employee_access?select=*&limit=5", "GET", key=SECRET)
    say("anonymous_session_id" not in str(ea), "в employee_access нет ссылки на сессию")

finally:
    log.append("\n▸ уборка")
    for uid, what in ((corp_id, "корпоративный"), (anon_id, "анонимный")):
        if uid:
            st, _ = call(f"/auth/v1/admin/users/{uid}", "DELETE", key=SECRET)
            say(st == 200, f"удалён {what} аккаунт")

log.append("")
log.append(f"✗ ПРОВАЛОВ: {failures}" if failures
           else "✓ Весь путь пройден, связи между половинами не обнаружено.")
print("\n".join(log))
sys.exit(1 if failures else 0)
