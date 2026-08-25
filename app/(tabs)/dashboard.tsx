import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Badge, Card, Empty, H2, Loading, Notice, P, Screen } from '../../src/components/ui';
import { fetchDepartments, fetchHrAggregates, fetchMinSampleSize } from '../../src/lib/api';
import { useAuth } from '../../src/lib/auth';
import { humanizeError } from '../../src/lib/supabase';
import type { Department, HrAggregate } from '../../src/lib/types';
import { colors, font, radius, riskTone, spacing } from '../../src/theme';

/**
 * Дельта в скобках после направления: «↑ вырос (+34%)».
 *
 * Отдельно от стрелки намеренно. Стрелка появляется только при движении
 * больше пяти пунктов — это полоса нечувствительности против шума.
 * Дельта же может быть посчитана и при меньшем движении, и показывать
 * «→ без изменений (+3%)» значит спорить с самим собой.
 */
function formatDelta(pct: number | null): string {
  if (pct === null || pct === 0) return '';
  return `  (${pct > 0 ? '+' : ''}${pct}%)`;
}

const TREND: Record<string, { arrow: string; text: string }> = {
  up: { arrow: '↑', text: 'вырос' },
  down: { arrow: '↓', text: 'снизился' },
  flat: { arrow: '→', text: 'без изменений' },
};

export default function Dashboard() {
  const { viewer } = useAuth();
  const companyId = viewer.kind === 'hr' ? viewer.companyId : null;

  const [rows, setRows] = useState<HrAggregate[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [threshold, setThreshold] = useState(5);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    if (!companyId) return;
    try {
      const [aggregates, deps, min] = await Promise.all([
        fetchHrAggregates(companyId),
        fetchDepartments(),
        fetchMinSampleSize(),
      ]);
      setRows(aggregates);
      setDepartments(deps);
      setThreshold(min);
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

  // Свежий период — первый по сортировке из api.
  const period = rows[0]?.period_start ?? null;
  const current = rows.filter((r) => r.period_start === period);
  const overall = current.find((r) => r.department_tag === null) ?? null;
  const byDepartment = current.filter((r) => r.department_tag !== null);

  const covered = overall?.sample_size ?? 0;
  const shown = byDepartment.reduce((sum, r) => sum + r.sample_size, 0);
  const hidden = Math.max(0, covered - shown);

  const title = (slug: string | null) =>
    departments.find((d) => d.slug === slug)?.title_ru ?? slug ?? 'Компания целиком';

  return (
    <Screen>
      <Notice text={error} />

      {!overall ? (
        <Empty
          title="Данных пока нет"
          hint={`Срез появится, когда наберётся минимум ${threshold} разных собеседников. До этого показывать нечего — любая цифра указывала бы на конкретных людей.`}
        />
      ) : (
        <>
          <Card>
            <H2>Компания целиком</H2>
            <View style={s.head}>
              <Text style={[s.score, { color: riskTone(overall.risk_score).fg }]}>
                {overall.risk_score}
              </Text>
              <View style={{ gap: spacing.xs }}>
                <Badge
                  label={riskTone(overall.risk_score).label}
                  fg={riskTone(overall.risk_score).fg}
                  bg={riskTone(overall.risk_score).bg}
                />
                <Text style={s.trend}>
                  {TREND[overall.trend_direction]?.arrow} {TREND[overall.trend_direction]?.text} за период
                  {formatDelta(overall.risk_delta_pct)}
                </Text>
              </View>
            </View>
            <Text style={s.period}>
              {new Date(overall.period_start).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}
              {' — '}
              {new Date(overall.period_end).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}
            </Text>
            <P muted>Разговаривали {covered} человек.</P>
          </Card>

          {byDepartment.length === 0 ? (
            <Empty
              title="По отделам разбивки нет"
              hint={`Ни в одном отделе не набралось ${threshold} собеседников. Общая цифра выше — по всем сразу.`}
            />
          ) : (
            byDepartment.map((row) => {
              const tone = riskTone(row.risk_score);
              return (
                <Card key={row.id}>
                  <View style={s.head}>
                    <Text style={[s.score, { color: tone.fg }]}>{row.risk_score}</Text>
                    <View style={{ flex: 1, gap: spacing.xs }}>
                      <Text style={s.dept}>{title(row.department_tag)}</Text>
                      <Text style={s.trend}>
                        {TREND[row.trend_direction]?.arrow} {TREND[row.trend_direction]?.text}
                        {formatDelta(row.trend_direction === 'flat' ? null : row.risk_delta_pct)}
                        {'  ·  '}
                        {row.sample_size} чел.
                      </Text>
                    </View>
                    <Badge label={tone.label} fg={tone.fg} bg={tone.bg} />
                  </View>
                </Card>
              );
            })
          )}

          {/* Честная строка про остаток. Без неё исчезнувший отдел
              читается как «там спокойно», хотя означает «там мало
              людей, чтобы показывать безопасно». */}
          {hidden > 0 ? (
            <Card>
              <Text style={s.hiddenTitle}>{hidden} чел. не показаны в разбивке</Text>
              <P muted>
                Это сотрудники из отделов, где собеседников меньше {threshold}, и те, кто не указал
                отдел. Их состояние учтено в общей цифре, но разложить его по отделам нельзя: в
                маленькой группе такой срез указывал бы на конкретного человека.
              </P>
              <P muted>
                Порог задан в базе и одинаков для всех — его нельзя обойти ни через интерфейс, ни
                запросом напрямую.
              </P>
            </Card>
          ) : null}
        </>
      )}

      <Card>
        <Text style={s.hiddenTitle}>Что здесь никогда не появится</Text>
        <P muted>
          Тексты сообщений, имена, должности, почта, идентификаторы устройств. Не потому, что мы их
          скрываем, а потому что связи между перепиской и человеком нет в самой базе.
        </P>
      </Card>
    </Screen>
  );
}

const s = StyleSheet.create({
  head: { flexDirection: 'row', alignItems: 'center', gap: spacing.lg },
  score: { fontSize: 40, fontFamily: font.h1.fontFamily },
  dept: { ...font.h2, color: colors.text },
  trend: { ...font.small, color: colors.textMuted },
  period: { ...font.small, color: colors.textMuted },
  hiddenTitle: { ...font.body, color: colors.text },
});
