import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';
import { Platform } from 'react-native';
import 'react-native-url-polyfill/auto';

const url = process.env.EXPO_PUBLIC_SUPABASE_URL;
const anonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;

if (!url || !anonKey) {
  throw new Error(
    'Не заданы EXPO_PUBLIC_SUPABASE_URL / EXPO_PUBLIC_SUPABASE_ANON_KEY. ' +
      'Скопируйте .env.example в .env и подставьте значения из Supabase.',
  );
}

export const supabase = createClient(url, anonKey, {
  auth: {
    // На вебе сессию хранит сам браузер (localStorage). На телефоне
    // своего хранилища нет — подсовываем AsyncStorage, иначе анонимная
    // сессия потеряется при перезапуске, а вместе с ней и вся история:
    // восстановить её будет нечем, билет уже погашен.
    storage: Platform.OS === 'web' ? undefined : AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: Platform.OS === 'web',
  },
});

/**
 * Ошибки бизнес-правил приходят из Postgres как `UC_CODE: текст`.
 * Показываем человеческую часть, а не сырой SQL-стейт.
 */
export function humanizeError(error: unknown): string {
  const raw =
    typeof error === 'object' && error !== null && 'message' in error
      ? String((error as { message: unknown }).message)
      : String(error);

  // Не все отказы приходят как UC_*. Часть — ограничения самого Postgres
  // и Supabase Auth, и их текст английский и технический. Показывать его
  // человеку нельзя: «new row violates row-level security policy» ничего
  // ему не говорит, хотя означает всего лишь «это не ваши данные».
  const patterns: Array<[RegExp, string]> = [
    [/row-level security/i, 'Эти данные принадлежат другой сессии'],
    [/permission denied/i, 'К этой таблице нет доступа — так и задумано'],
    [/Anonymous sign-ins are disabled/i,
      'В проекте Supabase не включён анонимный вход. Authentication → Sign In / Providers → Anonymous Sign-Ins'],
    [/Email logins are disabled/i, 'В проекте Supabase не включён вход по почте'],
    [/Failed to fetch|NetworkError|Load failed/i, 'Нет связи с сервером — проверьте интернет'],
    [/Invalid login credentials/i, 'Неверная почта или пароль'],
    [/For security purposes|rate limit/i, 'Слишком часто. Подождите минуту и повторите'],
  ];

  for (const [pattern, text] of patterns) {
    if (pattern.test(raw)) return text;
  }

  const match = raw.match(/UC_([A-Z_]+):?\s*(.*)/);
  if (!match) return raw;

  const [, code, tail] = match;
  if (tail) return tail;

  const fallbacks: Record<string, string> = {
    NOT_AUTHENTICATED: 'Сессия не найдена — войдите заново',
    UNKNOWN_DOMAIN: 'Компания с таким доменом почты ещё не подключена',
    GRANT_LIMIT: 'Для этого адреса выдано максимум билетов',
    NOT_ANONYMOUS: 'Выйдите из корпоративного аккаунта — билет привязывается только к анонимному входу',
    BAD_GRANT: 'Код не найден, уже использован или истёк',
    ANONYMOUS: 'Это действие недоступно анонимной сессии',
  };

  return fallbacks[code] ?? raw;
}
