import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Card, Chip, H2, Loading, Notice, P, Screen } from '../../src/components/ui';
import { fetchCompany } from '../../src/lib/api';
import { useAuth } from '../../src/lib/auth';
import { PERIODS, TARIFFS, effectiveMonthly, formatKzt, periodTotal } from '../../src/lib/pricing';
import { humanizeError } from '../../src/lib/supabase';
import type { BillingPeriod, Company } from '../../src/lib/types';
import { colors, font, spacing } from '../../src/theme';

export default function Tariff() {
  const { viewer } = useAuth();
  const companyId = viewer.kind === 'hr' ? viewer.companyId : null;

  const [company, setCompany] = useState<Company | null>(null);
  const [period, setPeriod] = useState<BillingPeriod>('month');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!companyId) return;
    try {
      const found = await fetchCompany(companyId);
      setCompany(found);
      if (found) setPeriod(found.billing_period);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setLoading(false);
    }
  }, [companyId]);

  useEffect(() => {
    load();
  }, [load]);

  if (loading) return <Loading />;

  // Обратная сторона того же: сотруднику здесь показывать нечего, а
  // экран успевает смонтироваться при переключении вкладок.
  if (viewer.kind !== 'hr') return null;
  if (!company) return <Notice text={error || 'Компания не найдена'} />;

  const tariff = TARIFFS[company.tariff_tier];
  const total = periodTotal(company.tariff_tier, period);
  const monthly = effectiveMonthly(company.tariff_tier, period);
  const saved = periodTotal(company.tariff_tier, 'month') * PERIODS[period].months - total;

  return (
    <Screen>
      <Card>
        <Text style={s.company}>{company.name}</Text>
        <H2>{tariff.title}</H2>
        <P muted>{tariff.range}</P>
        <P muted>
          Цена фиксированная и не зависит от того, сколько сотрудников на самом деле пользуется
          продуктом. Иначе счёт пришлось бы считать по числу пишущих — то есть измерять ровно то, что
          мы обещали не измерять.
        </P>
      </Card>

      <Card>
        <H2>Период оплаты</H2>
        <View style={s.chips}>
          {(Object.keys(PERIODS) as BillingPeriod[]).map((key) => (
            <Chip
              key={key}
              label={PERIODS[key].title}
              active={period === key}
              onPress={() => setPeriod(key)}
            />
          ))}
        </View>

        <View style={s.priceRow}>
          <Text style={s.price}>{formatKzt(total)}</Text>
          <Text style={s.priceHint}>
            за {PERIODS[period].months === 1 ? 'месяц' : `${PERIODS[period].months} мес.`}
          </Text>
        </View>

        {PERIODS[period].discount > 0 ? (
          <P muted>
            {formatKzt(monthly)} в месяц — экономия {formatKzt(saved)} против помесячной оплаты
            (−{Math.round(PERIODS[period].discount * 100)} %).
          </P>
        ) : (
          <P muted>{formatKzt(monthly)} в месяц.</P>
        )}

        <Notice
          tone="info"
          text={
            period === company.billing_period
              ? 'Текущий период компании.'
              : 'Это расчёт для сравнения. Смена периода — через договор: онлайн-оплата на этом этапе не подключена.'
          }
        />
      </Card>

      <Card>
        <H2>Что входит</H2>
        <P>Круглосуточный анонимный собеседник для всех сотрудников компании.</P>
        <P>Дашборд трендов по отделам с порогом анонимности.</P>
        <P>Дневник состояния для каждого сотрудника.</P>
        <P muted>
          Не входит и не может входить: доступ к переписке, выгрузка сообщений, идентификация
          сотрудника по разговору. Это не вопрос тарифа — таких возможностей нет ни на одном плане.
        </P>
      </Card>
    </Screen>
  );
}

const s = StyleSheet.create({
  company: { ...font.label, color: colors.textMuted, textTransform: 'uppercase', letterSpacing: 0.6 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  priceRow: { flexDirection: 'row', alignItems: 'baseline', gap: spacing.sm },
  price: { ...font.h1, color: colors.warm },
  priceHint: { ...font.small, color: colors.textMuted },
});
