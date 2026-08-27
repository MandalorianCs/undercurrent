/**
 * Собеседник как сервис.
 *
 * Существует ради одного: чтобы у приложения и телеграм-бота был ОДИН
 * источник правил, а не две копии. Копия на Python разошлась бы с
 * оригиналом молча, и первым, что перестало бы совпадать, оказалось бы
 * распознавание кризисных сигналов — то есть цена расхождения измеряется
 * не багом, а человеком, которому не ответили правильно.
 *
 * Поэтому здесь нет ни одного правила. Функция импортирует тот же
 * src/lib/companion.ts, который исполняет приложение, и добавляет к нему
 * только транспорт: разбор запроса, запись в базу, ответ.
 *
 * Deno исполняет TypeScript напрямую, поэтому импорт настоящий, а не
 * скопированный при сборке. Изменение в companion.ts меняет поведение
 * обоих клиентов одновременно и по определению.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2';
import {
  CRISIS_CONTACTS,
  extractMarkers,
  isCrisis,
  respond,
} from '../../../src/lib/companion.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

/**
 * Общий заголовок для браузера. Приложение ходит сюда с веба, а веб без
 * CORS получит ошибку ещё до того, как запрос уйдёт.
 */
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Только POST' }, 405);

  let payload: { session_id?: string; text?: string; department_tag?: string | null };
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'Тело запроса не разобрано' }, 400);
  }

  const text = (payload.text ?? '').trim();
  const sessionId = payload.session_id;

  if (!text) return json({ error: 'Пустое сообщение' }, 400);
  if (!sessionId) return json({ error: 'Не указана сессия' }, 400);

  const db = createClient(SUPABASE_URL, SERVICE_KEY);

  // Сессия обязана существовать. Проверка не формальность: без неё
  // функция со служебным ключом писала бы сообщения в произвольный
  // идентификатор, и любой, кто дотянулся до неё, мог бы засорять чужие
  // разговоры.
  const { data: session, error: sessionError } = await db
    .from('anonymous_sessions')
    .select('id, company_id')
    .eq('id', sessionId)
    .maybeSingle();

  if (sessionError) return json({ error: sessionError.message }, 500);
  if (!session) return json({ error: 'Сессия не найдена' }, 404);

  // Продолжаем последний разговор этой сессии либо начинаем новый.
  const { data: existing } = await db
    .from('conversations')
    .select('id')
    .eq('anonymous_session_id', sessionId)
    .order('started_at', { ascending: false })
    .limit(1);

  let conversationId = existing?.[0]?.id as string | undefined;

  if (!conversationId) {
    const { data: created, error: createError } = await db
      .from('conversations')
      .insert({
        anonymous_session_id: sessionId,
        company_id: session.company_id,
        department_tag: payload.department_tag ?? null,
      })
      .select('id')
      .single();

    if (createError) return json({ error: createError.message }, 500);
    conversationId = created.id;
  }

  // Номер реплики для выбора ответа без повторов.
  const { count } = await db
    .from('messages')
    .select('id', { count: 'exact', head: true })
    .eq('conversation_id', conversationId);

  const markers = extractMarkers(text);
  const reply = respond(text, markers, count ?? 0);

  const { error: insertError } = await db.from('messages').insert([
    { conversation_id: conversationId, role: 'user', content: text, stress_markers: markers },
    // У ответа модели разметки нет: она попала бы в расчёт риска отдела,
    // и он начал бы зависеть от того, насколько сочувственно
    // сформулирован ответ бота.
    { conversation_id: conversationId, role: 'assistant', content: reply, stress_markers: null },
  ]);

  if (insertError) return json({ error: insertError.message }, 500);

  // markers наружу не отдаём. Клиенту они не нужны для отображения, а
  // всякое лишнее поле в ответе однажды окажется на экране.
  //
  // Признак кризиса и контакты — отдаём. Иначе клиенту пришлось бы
  // самому решать, кризис это или нет, то есть завести вторую копию
  // правила. Ровно того, ради чего эта функция и существует, не
  // случилось бы.
  return json({
    reply,
    conversation_id: conversationId,
    crisis: isCrisis(text),
    contacts: isCrisis(text) ? CRISIS_CONTACTS : [],
  });
});
