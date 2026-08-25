/**
 * Весь доступ к данным. Экраны не обращаются к supabase напрямую —
 * иначе однажды появится экран, который сам собирает запрос, и его
 * никто не заметит при ревизии того, кто что видит.
 */

import { extractMarkers, respond } from './companion';
import { supabase } from './supabase';
import type {
  Company,
  Conversation,
  Department,
  HrAggregate,
  Message,
  MoodEntry,
  PersonalSubscription,
} from './types';

function unwrap<T>({ data, error }: { data: T | null; error: unknown }): T {
  if (error) throw error;
  return data as T;
}

// ─────────────────────────────────────────────────────────────
// Вход и сессии
// ─────────────────────────────────────────────────────────────

/** Шаг 1: сессия с корпоративной почтой берёт билет. */
export async function issueAccessGrant(): Promise<string> {
  return unwrap(await supabase.rpc('issue_access_grant'));
}

/** Шаг 2: анонимная сессия гасит билет и получает id компании. */
export async function bindAccessGrant(code: string): Promise<string> {
  return unwrap(await supabase.rpc('bind_access_grant', { p_code: code }));
}

/** B2C: личный аккаунт заводит себе сессию. */
export async function startPersonalSession(): Promise<string> {
  return unwrap(await supabase.rpc('start_personal_session'));
}

/**
 * Своя сессия, если она есть.
 *
 * maybeSingle, а не single: отсутствие строки — обычное состояние
 * (вошёл по почте, но билет ещё не погасил), а не ошибка.
 */
export async function fetchMySession(
  userId: string,
): Promise<{ id: string; company_id: string | null } | null> {
  const { data, error } = await supabase
    .from('anonymous_sessions')
    .select('id, company_id')
    .eq('id', userId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function fetchHrAccount(
  userId: string,
): Promise<{ user_id: string; company_id: string; full_name: string | null } | null> {
  const { data, error } = await supabase
    .from('hr_accounts')
    .select('user_id, company_id, full_name')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function fetchCompany(companyId: string): Promise<Company | null> {
  const { data, error } = await supabase
    .from('companies')
    .select('id, name, tariff_tier, billing_period')
    .eq('id', companyId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// ─────────────────────────────────────────────────────────────
// Справочники
// ─────────────────────────────────────────────────────────────

export async function fetchDepartments(): Promise<Department[]> {
  return unwrap(
    await supabase.from('departments').select('slug, title_ru, sort_order').order('sort_order'),
  );
}

export async function fetchMinSampleSize(): Promise<number> {
  const { data, error } = await supabase
    .from('app_settings')
    .select('value')
    .eq('key', 'min_sample_size')
    .maybeSingle();
  if (error) throw error;
  return Number(data?.value ?? 5);
}

// ─────────────────────────────────────────────────────────────
// Разговоры
// ─────────────────────────────────────────────────────────────

export async function fetchConversations(): Promise<Conversation[]> {
  return unwrap(
    await supabase
      .from('conversations')
      .select('id, anonymous_session_id, company_id, department_tag, started_at')
      .order('started_at', { ascending: false }),
  );
}

export async function createConversation(
  sessionId: string,
  companyId: string | null,
  departmentTag: string | null,
): Promise<Conversation> {
  return unwrap(
    await supabase
      .from('conversations')
      .insert({
        anonymous_session_id: sessionId,
        company_id: companyId,
        department_tag: departmentTag,
      })
      .select('id, anonymous_session_id, company_id, department_tag, started_at')
      .single(),
  );
}

export async function fetchMessages(conversationId: string): Promise<Message[]> {
  return unwrap(
    await supabase
      .from('messages')
      .select('id, conversation_id, role, content, stress_markers, created_at')
      .eq('conversation_id', conversationId)
      .order('created_at'),
  );
}

/**
 * Отправка реплики и ответ собеседника.
 *
 * Маркеры считаются на клиенте и кладутся рядом с сообщением одной
 * вставкой. Это осознанный компромисс MVP: клиенту, вообще говоря,
 * нельзя доверять разметку, потому что её можно подделать и испортить
 * агрегат отдела. Когда появится серверный ИИ-слой, извлечение уедет
 * туда, и клиент перестанет присылать stress_markers вовсе — схема при
 * этом не изменится.
 */
export async function sendMessage(
  conversationId: string,
  text: string,
  turn: number,
): Promise<Message[]> {
  const markers = extractMarkers(text);

  const inserted = unwrap(
    await supabase
      .from('messages')
      .insert([
        { conversation_id: conversationId, role: 'user', content: text, stress_markers: markers },
        {
          conversation_id: conversationId,
          role: 'assistant',
          content: respond(text, markers, turn),
          // У ответа модели разметки нет намеренно: она попала бы в
          // расчёт риска отдела, и он начал бы зависеть от того, насколько
          // сочувственно сформулирован ответ бота.
          stress_markers: null,
        },
      ])
      .select('id, conversation_id, role, content, stress_markers, created_at'),
  );

  return inserted;
}

// ─────────────────────────────────────────────────────────────
// Дневник состояния
// ─────────────────────────────────────────────────────────────

export async function fetchMoodEntries(limit = 60): Promise<MoodEntry[]> {
  return unwrap(
    await supabase
      .from('mood_entries')
      .select('id, session_id, mood, note, created_at')
      .order('created_at', { ascending: false })
      .limit(limit),
  );
}

export async function addMoodEntry(
  sessionId: string,
  mood: number,
  note: string | null,
): Promise<MoodEntry> {
  return unwrap(
    await supabase
      .from('mood_entries')
      .insert({ session_id: sessionId, mood, note: note?.trim() || null })
      .select('id, session_id, mood, note, created_at')
      .single(),
  );
}

// ─────────────────────────────────────────────────────────────
// HR
// ─────────────────────────────────────────────────────────────

/**
 * Срезы для дашборда.
 *
 * Фильтра по sample_size здесь нет — и это не забывчивость. Порог
 * отсекается RLS-политикой в базе: строки ниже порога сюда физически не
 * доезжают. Продублировать фильтр на клиенте означало бы создать
 * впечатление, что он тут и работает, — и однажды кто-то «оптимизирует»
 * политику, полагаясь на клиентскую проверку.
 */
export async function fetchHrAggregates(companyId: string): Promise<HrAggregate[]> {
  return unwrap(
    await supabase
      .from('hr_aggregates')
      .select(
        'id, company_id, department_tag, period_start, period_end, risk_score, trend_direction, sample_size, risk_delta_pct, computed_at',
      )
      .eq('company_id', companyId)
      .order('period_start', { ascending: false })
      .order('risk_score', { ascending: false }),
  );
}

// ─────────────────────────────────────────────────────────────
// Свои данные
// ─────────────────────────────────────────────────────────────

export async function fetchMySubscription(userId: string): Promise<PersonalSubscription | null> {
  const { data, error } = await supabase
    .from('personal_subscriptions')
    .select('id, user_id, plan, status, started_at, expires_at')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function exportMyData(): Promise<unknown> {
  return unwrap(await supabase.rpc('export_my_data'));
}

export async function deleteMyData(): Promise<void> {
  const { error } = await supabase.rpc('delete_my_data');
  if (error) throw error;
}
