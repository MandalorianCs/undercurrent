/**
 * Типы повторяют схему из supabase/migrations. Держатся руками, а не
 * генерацией: генератор Supabase тянет в проект весь каталог базы,
 * включая таблицы левой половины схемы. Иметь в клиентском коде тип
 * `EmployeeAccess` — значит однажды его использовать.
 */

export type TariffTier = 'small_20' | 'start_100' | 'growth_500' | 'corp_1000plus';
export type BillingPeriod = 'month' | 'half_year' | 'year';
export type MessageRole = 'user' | 'assistant';
export type TrendDirection = 'up' | 'down' | 'flat';
export type SubscriptionStatus = 'trial' | 'active' | 'expired';

export type Department = {
  slug: string;
  title_ru: string;
  sort_order: number;
};

export type Company = {
  id: string;
  name: string;
  tariff_tier: TariffTier;
  billing_period: BillingPeriod;
};

export type Conversation = {
  id: string;
  anonymous_session_id: string;
  company_id: string | null;
  department_tag: string | null;
  started_at: string;
};

export type Message = {
  id: string;
  conversation_id: string;
  role: MessageRole;
  content: string;
  stress_markers: StressMarkers | null;
  created_at: string;
};

/**
 * Что извлекает ИИ-слой из реплики. Все поля 0…1.
 *
 * Здесь нет ни имени, ни должности, ни цитаты — и это ограничение типа,
 * а не соглашение. Расширять его полями вроде `quote` или `author`
 * нельзя: именно этот объект уходит в расчёт агрегатов, то есть в
 * единственное место, куда смотрит компания.
 */
export type StressMarkers = {
  exhaustion?: number;
  workload?: number;
  hopelessness?: number;
  conflict?: number;
  tags?: string[];
};

export type MoodEntry = {
  id: string;
  session_id: string;
  mood: 1 | 2 | 3 | 4 | 5;
  note: string | null;
  created_at: string;
};

export type HrAggregate = {
  id: string;
  company_id: string;
  department_tag: string | null;
  period_start: string;
  period_end: string;
  risk_score: number;
  trend_direction: TrendDirection;
  sample_size: number;
  computed_at: string;
};

export type PersonalSubscription = {
  id: string;
  user_id: string;
  plan: string;
  status: SubscriptionStatus;
  started_at: string;
  expires_at: string | null;
};

/**
 * Кто сейчас за экраном.
 *
 * Промежуточных состояний два, и оба настоящие, а не технические:
 * человек физически проходит через них между двумя входами. Свернуть их
 * в одно «загружается» значит потерять место, где нужно показать, что
 * происходит, — а происходит здесь самое важное для доверия.
 */
export type Viewer =
  | { kind: 'guest' }
  /** Вошёл по корпоративной почте. Билет ещё не взят или не погашен. */
  | { kind: 'awaiting_grant'; userId: string }
  /** Вошёл анонимно, но билет к сессии ещё не привязан. */
  | { kind: 'anonymous_unbound'; userId: string }
  /** Рабочее состояние B2B-сотрудника. */
  | { kind: 'anonymous'; sessionId: string; companyId: string | null }
  /** Рабочее состояние B2C-подписчика: аккаунт свой, история своя. */
  | { kind: 'personal'; userId: string; sessionId: string }
  | { kind: 'hr'; userId: string; companyId: string };
