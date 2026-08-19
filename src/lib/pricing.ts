import type { BillingPeriod, TariffTier } from './types';

/**
 * Тарифы B2B — фиксированная цена за диапазон команды, не за человека.
 *
 * Поштучная тарификация выглядела бы гибче, но она несовместима с
 * продуктом: чтобы выставить счёт за N сотрудников, платформе пришлось
 * бы считать, сколько именно человек завело переписку, — то есть
 * измерять ровно то, что обещано не измерять. Фиксированная цена за
 * диапазон снимает вопрос: счёт не зависит от того, пользуется продуктом
 * весь отдел или один человек.
 *
 * Цены — из деки и лендинга, менять только вместе с ними.
 */
export const TARIFFS: Record<TariffTier, { title: string; range: string; monthly: number }> = {
  small_20: { title: 'Малая команда', range: 'до 20 человек', monthly: 30_000 },
  start_100: { title: 'Старт', range: 'до 100 человек', monthly: 120_000 },
  growth_500: { title: 'Рост', range: '100–500 человек', monthly: 350_000 },
  corp_1000plus: { title: 'Корпорация', range: '1000+ человек', monthly: 700_000 },
};

/**
 * Скидка за срок — это покупка удержания, а не щедрость.
 *
 * Полугодовой контракт нужен обеим сторонам: внедрение HR-аналитики
 * занимает недели, и на месячной подписке клиент успевает отвалиться
 * раньше, чем увидит первый осмысленный тренд.
 */
export const PERIODS: Record<BillingPeriod, { title: string; months: number; discount: number }> = {
  month: { title: 'Помесячно', months: 1, discount: 0 },
  half_year: { title: '6 месяцев', months: 6, discount: 0.1 },
  year: { title: 'Год', months: 12, discount: 0.2 },
};

export function periodTotal(tier: TariffTier, period: BillingPeriod): number {
  const { monthly } = TARIFFS[tier];
  const { months, discount } = PERIODS[period];
  return Math.round(monthly * months * (1 - discount));
}

export function effectiveMonthly(tier: TariffTier, period: BillingPeriod): number {
  return Math.round(periodTotal(tier, period) / PERIODS[period].months);
}

/** Личная подписка. */
export const B2C_MONTHLY = 2_990;

/**
 * Формат сумм.
 *
 * Неразрывный пробел между числом и знаком: «700 000 ₸», перенесённое
 * на две строки посреди цены, читается как ошибка вёрстки на экране,
 * который человек показывает своему финансовому директору.
 */
export function formatKzt(amount: number): string {
  return `${amount.toLocaleString('ru-RU').replace(/\s/g, ' ')} ₸`;
}
