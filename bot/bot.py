"""
Телеграм-бот Undercurrent.

Делает три вещи:

1. Привязывает Telegram к ИМЕНной учётной записи — HR или личной
   подписке B2C. Человек берёт код в приложении и открывает ссылку
   t.me/бот?start=КОД: одно нажатие вместо набора символов.

2. Разносит уведомления. Таблицу notifications заполняет база; бот
   забирает строки с пустым sent_at и отправляет. Приложение и бот —
   два окна в одни данные, а не два источника правды.

3. Приводит сотрудника в приложение. Для B2B это единственное, что бот
   делает, и ниже объяснено почему.

═══════════════════════════════════════════════════════════════
ЧЕГО БОТ НЕ ДЕЛАЕТ И ПОЧЕМУ
═══════════════════════════════════════════════════════════════

**Не ведёт разговор.** Собеседник и распознавание кризисных сигналов
живут в src/lib/companion.ts. Переписать их сюда на Python значило бы
завести вторую копию правил, которая разойдётся с первой молча. Цена
расхождения здесь не абстрактная: приложение распознает сообщение о
желании уйти из жизни, а бот — нет, и человек получит вежливый вопрос
про нагрузку.

Когда разговор в Telegram понадобится, правильный путь — вынести
companion в Edge Function, куда ходят оба клиента. Не копия, а один
источник.

**Не привязывается к анонимной сессии сотрудника.** Telegram знает, кто
человек: за чатом стоит номер телефона. Связать чат с перепиской значит
получить в базе пару «переписка ↔ личность» — ровно то, чего в схеме
Undercurrent нет по построению, и на чём держится обещание B2B.

Запрет живёт не здесь, а в триггере telegram_link_guard: бот ходит
служебным ключом, то есть мимо всех политик, и остановить его может
только правило внутри Postgres. Если завтра появится второй бот или
«временный скрипт», правило продолжит работать без их участия.

Сотрудник от бота получает ссылку в приложение — там, где для разговора
есть анонимность.

**Не пишет первым.** Это ограничение Telegram, а не выбор архитектуры:
бот не может отправить сообщение тому, кто сам не начинал диалог.
Отсюда порядок — сначала человек открывает бота, потом ему можно писать.
Уведомление для непривязанного не теряется, а ждёт в базе и приходит
сразу после привязки.
"""

import asyncio
import logging
import os
import sys

# Консоль Windows по умолчанию не в UTF-8, и Python выводит в неё русский
# текст заменами вместо букв. Одна строка снимает весь класс проблемы.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import httpx
from aiogram import Bot, Dispatcher, F
from aiogram.enums import ParseMode
from aiogram.filters import CommandStart, CommandObject
from aiogram.types import (
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Message,
)
from dotenv import load_dotenv

BOT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BOT_DIR)

# Три файла вместо одного — чтобы каждое значение лежало ровно в одном
# месте. bot/.env — только токен Telegram; адрес проекта уже есть в
# корневом .env (его же читает Expo); служебный ключ — в .env.secret,
# отдельно от всего, что попадает в бандл приложения.
load_dotenv(os.path.join(BOT_DIR, ".env"))
load_dotenv(os.path.join(ROOT, ".env"))
load_dotenv(os.path.join(ROOT, ".env.secret"))


def required(name: str, where: str, *fallbacks: str) -> str:
    """
    Значение или понятная остановка.

    KeyError с именем переменной ничего не говорит человеку, который
    запускает бота впервые. Здесь сразу сказано, какой файл открыть.
    """
    for key in (name, *fallbacks):
        value = os.environ.get(key)
        if value:
            return value
    print(f"✗ Не задано {name}. Заполните {where}.", file=sys.stderr)
    sys.exit(1)


TOKEN = required("TELEGRAM_BOT_TOKEN", "bot/.env")
SUPABASE_URL = required("SUPABASE_URL", "корневой .env", "EXPO_PUBLIC_SUPABASE_URL")
SECRET_KEY = required("SUPABASE_SECRET_KEY", ".env.secret")
APP_URL = os.environ.get("APP_URL", "http://localhost:8082")
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))

REST = f"{SUPABASE_URL.rstrip('/')}/rest/v1"
HEADERS = {
    "apikey": SECRET_KEY,
    "Authorization": f"Bearer {SECRET_KEY}",
    "Content-Type": "application/json",
}

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s")
log = logging.getLogger("undercurrent")

bot = Bot(token=TOKEN)
dp = Dispatcher()


# ── Обёртки над REST ──────────────────────────────────────────


async def rest_get(client: httpx.AsyncClient, path: str, params: dict) -> list[dict]:
    r = await client.get(f"{REST}/{path}", headers=HEADERS, params=params)
    r.raise_for_status()
    return r.json()


async def rest_post(client: httpx.AsyncClient, path: str, body: dict) -> httpx.Response:
    return await client.post(f"{REST}/{path}", headers=HEADERS, json=body)


async def rest_patch(client: httpx.AsyncClient, path: str, params: dict, body: dict) -> None:
    r = await client.patch(f"{REST}/{path}", headers=HEADERS, params=params, json=body)
    r.raise_for_status()


async def rest_delete(client: httpx.AsyncClient, path: str, params: dict) -> None:
    r = await client.delete(f"{REST}/{path}", headers=HEADERS, params=params)
    r.raise_for_status()


def app_button(text: str = "Открыть Undercurrent") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(
        inline_keyboard=[[InlineKeyboardButton(text=text, url=APP_URL)]]
    )


# ── Привязка ──────────────────────────────────────────────────


@dp.message(CommandStart(deep_link=True))
async def on_start_with_code(message: Message, command: CommandObject) -> None:
    """
    Переход по ссылке t.me/бот?start=КОД.

    Код одноразовый и живёт пятнадцать минут. Гасим сразу после
    использования — по той же причине, что и билет доступа: код,
    оставшийся в базе, однажды окажется в чужой переписке.
    """
    code = (command.args or "").strip()

    async with httpx.AsyncClient(timeout=20) as client:
        rows = await rest_get(
            client,
            "telegram_link_codes",
            {
                "code": f"eq.{code}",
                "expires_at": "gt.now()",
                "select": "code,user_id,kind",
            },
        )

        if not rows:
            await message.answer(
                "Код не найден или истёк.\n\n"
                "Возьмите новый в приложении: Настройки → Подключить Telegram. "
                "Код действует пятнадцать минут.",
                reply_markup=app_button(),
            )
            return

        row = rows[0]

        # Одна привязка на человека. Старую снимаем: иначе уведомления
        # уедут в чат, которым он больше не пользуется, а он решит, что
        # бот не работает.
        await rest_delete(client, "telegram_links", {"user_id": f"eq.{row['user_id']}"})

        response = await rest_post(
            client,
            "telegram_links",
            {
                "telegram_id": message.chat.id,
                "user_id": row["user_id"],
                "kind": row["kind"],
                "username": message.from_user.username if message.from_user else None,
            },
        )

        if response.status_code >= 400:
            # Сюда попадаем, если сработал страж в базе. Показывать
            # человеку текст ошибки Postgres нельзя, но и молчать нельзя:
            # он должен понимать, что делать дальше.
            detail = response.text
            log.warning("привязка отклонена: %s", detail)
            if "UC_ANONYMOUS_LINK" in detail:
                await message.answer(
                    "Эту сессию нельзя связать с Telegram — она анонимная.\n\n"
                    "Так и задумано: связка с Telegram означала бы связку с вашим "
                    "номером телефона, а переписка в Undercurrent ни с чем таким "
                    "не соединяется.",
                    reply_markup=app_button(),
                )
            else:
                await message.answer("Не получилось привязать. Попробуйте новый код в приложении.")
            return

        await rest_delete(client, "telegram_link_codes", {"code": f"eq.{code}"})

        if row["kind"] == "hr":
            await message.answer(
                "Готово. Буду присылать сюда изменения по отделам.\n\n"
                "Только цифры: отдел, уровень риска, направление. "
                "Переписки сотрудников здесь не будет никогда — её нельзя "
                "получить ни через бота, ни через запрос в поддержку.",
                reply_markup=app_button("Открыть дашборд"),
            )
        else:
            await message.answer(
                "Готово. Буду напоминать про дневник состояния и присылать важное.\n\n"
                "Разговор с собеседником — в приложении: там он защищён, "
                "а Telegram знает, кто вы.",
                reply_markup=app_button(),
            )

        # Всё, что накопилось, пока человек не был привязан, уходит сразу.
        await deliver_pending(client)


@dp.message(CommandStart())
async def on_start(message: Message) -> None:
    """Открыли бота без кода — обычный вход для сотрудника."""
    await message.answer(
        "Undercurrent — анонимный собеседник для сотрудников.\n\n"
        "Разговор происходит в приложении, а не здесь, и это не неудобство, "
        "а устройство продукта: Telegram знает ваш номер телефона, "
        "а приложение о вас не знает ничего.\n\n"
        "Работодатель не может прочитать вашу переписку. Не «обещает не читать» — "
        "не может: связи между вами и вашими сообщениями нет в базе данных.\n\n"
        "Если вы HR или у вас личная подписка, подключить Telegram можно "
        "в приложении: Настройки → Подключить Telegram.",
        reply_markup=app_button(),
    )


@dp.message(F.text == "/unlink")
async def on_unlink(message: Message) -> None:
    async with httpx.AsyncClient(timeout=20) as client:
        await rest_delete(client, "telegram_links", {"telegram_id": f"eq.{message.chat.id}"})
    await message.answer(
        "Отвязал. Уведомления сюда больше не придут.\n\n"
        "Ваши данные в приложении это не затронуло — привязка к Telegram "
        "и есть отдельная от них вещь."
    )


@dp.message(F.text.in_({"/help", "/помощь"}))
async def on_help(message: Message) -> None:
    await message.answer(
        "Что умеет бот:\n\n"
        "/start — начать\n"
        "/unlink — отвязать этот чат\n"
        "/help — эта справка\n\n"
        "Чего бот не умеет и не будет: показывать переписку сотрудников. "
        "Такой возможности нет ни на одном тарифе — не по правилам доступа, "
        "а потому что связи между человеком и его сообщениями не существует "
        "в самой базе.",
        reply_markup=app_button(),
    )


# ── Разговор ──────────────────────────────────────────────────
#
# Обработчик обычного текста регистрируется ПОСЛЕ команд: aiogram
# перебирает их в порядке объявления, и поставленный выше он перехватил
# бы /help и /unlink, отправив их собеседнику как реплику.


@dp.message(F.text)
async def on_text(message: Message) -> None:
    """
    Реплика в разговоре — только для личной подписки.

    Ни одного правила беседы здесь нет и быть не должно. Текст уходит в
    Edge Function, которая исполняет тот же src/lib/companion.ts, что и
    приложение. Если завтра поменяется распознавание кризиса, оно
    поменяется сразу в обоих местах, потому что место одно.
    """
    async with httpx.AsyncClient(timeout=30) as client:
        links = await rest_get(
            client,
            "telegram_links",
            {"telegram_id": f"eq.{message.chat.id}", "select": "user_id,kind"},
        )

        if not links:
            await message.answer(
                "Чтобы разговаривать здесь, нужна личная подписка и привязка.\n\n"
                "Если вы сотрудник компании — разговор происходит в приложении, "
                "и это не неудобство: Telegram знает ваш номер телефона, "
                "а приложение о вас не знает ничего.",
                reply_markup=app_button(),
            )
            return

        link = links[0]

        if link["kind"] == "hr":
            await message.answer(
                "Это HR-аккаунт — сюда приходят изменения по отделам.\n\n"
                "Разговор с собеседником доступен по личной подписке."
            )
            return

        # Показываем «печатает», пока функция считает: без него пауза в
        # пару секунд читается как «бот завис», и человек пишет второй раз.
        await bot.send_chat_action(message.chat.id, "typing")

        try:
            response = await client.post(
                f"{SUPABASE_URL.rstrip('/')}/functions/v1/companion",
                headers=HEADERS,
                json={"session_id": link["user_id"], "text": message.text},
            )
            response.raise_for_status()
            data = response.json()
        except Exception as exc:
            log.warning("собеседник недоступен: %s", exc)
            await message.answer(
                "Не получилось ответить — что-то со связью. Напишите ещё раз "
                "через минуту, я никуда не денусь."
            )
            return

        await message.answer(data.get("reply", ""))

        # Контакты приходят вместе с признаком кризиса. Бот не решает,
        # кризис это или нет: решение принимает та же функция, что и для
        # приложения, иначе правило раздвоилось бы.
        if data.get("crisis"):
            lines = ["Пожалуйста, свяжитесь с человеком прямо сейчас:", ""]
            for contact in data.get("contacts", []):
                lines.append(f"<b>{contact['number']}</b> — {contact['title']}")
                lines.append(contact["note"])
                lines.append("")
            await message.answer("\n".join(lines).strip(), parse_mode=ParseMode.HTML)


# ── Доставка уведомлений ──────────────────────────────────────


async def deliver_pending(client: httpx.AsyncClient) -> None:
    """
    Один проход по неотправленным.

    Порядок «отправить → отметить» выбран сознательно. При падении между
    шагами человек получит уведомление дважды — заметно и безобидно.
    Обратный порядок терял бы его молча, а молча потерянное уведомление
    о росте риска в отделе означает, что HR не узнал вовремя.
    """
    pending = await rest_get(
        client,
        "notifications",
        {
            "sent_at": "is.null",
            "select": "id,user_id,title,body",
            "order": "created_at.asc",
            "limit": "50",
        },
    )
    if not pending:
        return

    links = await rest_get(client, "telegram_links", {"select": "telegram_id,user_id"})
    chat_by_user = {row["user_id"]: row["telegram_id"] for row in links}

    for item in pending:
        chat_id = chat_by_user.get(item["user_id"])

        # Непривязанные пропускаем БЕЗ отметки: придут после привязки.
        if not chat_id:
            continue

        text = f"<b>{item['title']}</b>"
        if item.get("body"):
            text += f"\n{item['body']}"

        try:
            await bot.send_message(chat_id, text, parse_mode=ParseMode.HTML)
        except Exception as exc:
            # Чаще всего — человек заблокировал бота. Отметку не ставим:
            # если он вернётся, уведомление ещё живо.
            log.warning("не удалось отправить %s: %s", item["id"], exc)
            continue

        await rest_patch(
            client,
            "notifications",
            {"id": f"eq.{item['id']}"},
            {"sent_at": "now()"},
        )


async def notifier() -> None:
    async with httpx.AsyncClient(timeout=20) as client:
        while True:
            try:
                await deliver_pending(client)
            except Exception as exc:
                # Цикл не должен умирать от одной неудачной итерации:
                # упавший разносчик выглядит снаружи точно так же, как
                # «уведомлений просто нет».
                log.warning("цикл доставки: %s", exc)
            await asyncio.sleep(POLL_SECONDS)


async def main() -> None:
    log.info("Undercurrent bot запущен. Проект: %s", SUPABASE_URL)
    asyncio.create_task(notifier())
    await dp.start_polling(bot)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nОстановлен.")
