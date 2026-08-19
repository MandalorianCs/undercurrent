import { useCallback, useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Button, Card, Chip, Empty, Field, H2, Loading, Notice, P, Screen } from '../../src/components/ui';
import { addMoodEntry, fetchMoodEntries } from '../../src/lib/api';
import { useAuth } from '../../src/lib/auth';
import { humanizeError } from '../../src/lib/supabase';
import type { MoodEntry } from '../../src/lib/types';
import { colors, font, radius, spacing } from '../../src/theme';

/**
 * Шкала из пяти делений с человеческими подписями.
 *
 * Цифры без слов («оцените от 1 до 5») каждый понимает по-своему, и
 * ряд таких оценок нельзя сравнивать даже с самим собой неделю спустя.
 */
const SCALE: Array<{ value: 1 | 2 | 3 | 4 | 5; label: string }> = [
  { value: 1, label: 'Совсем тяжело' },
  { value: 2, label: 'Тяжело' },
  { value: 3, label: 'Ровно' },
  { value: 4, label: 'Неплохо' },
  { value: 5, label: 'Хорошо' },
];

export default function Diary() {
  const { viewer } = useAuth();
  const sessionId =
    viewer.kind === 'anonymous' ? viewer.sessionId : viewer.kind === 'personal' ? viewer.sessionId : null;

  const [entries, setEntries] = useState<MoodEntry[]>([]);
  const [mood, setMood] = useState<number | null>(null);
  const [note, setNote] = useState('');
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    try {
      setEntries(await fetchMoodEntries());
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function save() {
    if (!sessionId || mood === null) return;
    setBusy(true);
    setError('');
    try {
      const created = await addMoodEntry(sessionId, mood, note);
      setEntries((prev) => [created, ...prev]);
      setMood(null);
      setNote('');
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <Loading />;

  return (
    <Screen>
      <Card>
        <H2>Как сегодня?</H2>
        <View style={s.chips}>
          {SCALE.map((item) => (
            <Chip
              key={item.value}
              label={item.label}
              active={mood === item.value}
              onPress={() => setMood(mood === item.value ? null : item.value)}
            />
          ))}
        </View>
        <Field
          label="Заметка — по желанию"
          value={note}
          onChangeText={setNote}
          placeholder="Одна строка, если хочется"
          multiline
        />
        <Notice text={error} />
        <Button title="Записать" onPress={save} loading={busy} disabled={mood === null} />
        <P muted>
          Дневник виден только вам. В отчёты компании он не попадает вообще — ни цифрой, ни трендом.
        </P>
      </Card>

      {entries.length === 0 ? (
        <Empty
          title="Записей пока нет"
          hint="Отметка раз в день за пару недель показывает то, чего не видно изнутри одного дня."
        />
      ) : (
        <View style={{ gap: spacing.md }}>
          <Sparkline entries={entries} />
          {entries.map((e) => (
            <Card key={e.id}>
              <View style={s.row}>
                <Text style={s.mood}>{SCALE.find((x) => x.value === e.mood)?.label ?? e.mood}</Text>
                <Text style={s.date}>
                  {new Date(e.created_at).toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}
                </Text>
              </View>
              {e.note ? <P>{e.note}</P> : null}
            </Card>
          ))}
        </View>
      )}
    </Screen>
  );
}

/**
 * Полоски вместо графика.
 *
 * Линейный график по пятибалльной шкале рисует драматичные пики там, где
 * разница — одно деление. Полоски одинаковой ширины читаются как ряд
 * дней и не подсказывают выводов, которых в данных нет.
 */
function Sparkline({ entries }: { entries: MoodEntry[] }) {
  const recent = [...entries].reverse().slice(-21);
  return (
    <Card>
      <Text style={s.sparkTitle}>Последние записи</Text>
      <View style={s.spark}>
        {recent.map((e) => (
          <View
            key={e.id}
            style={[
              s.bar,
              {
                height: 8 + e.mood * 10,
                backgroundColor: e.mood <= 2 ? colors.alert : e.mood === 3 ? colors.warm : colors.cool,
              },
            ]}
          />
        ))}
      </View>
    </Card>
  );
}

const s = StyleSheet.create({
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  mood: { ...font.body, color: colors.text },
  date: { ...font.small, color: colors.textMuted },
  sparkTitle: { ...font.label, color: colors.textMuted, textTransform: 'uppercase', letterSpacing: 0.6 },
  spark: { flexDirection: 'row', alignItems: 'flex-end', gap: 4, height: 70 },
  bar: { flex: 1, borderRadius: radius.sm, minWidth: 6 },
});
