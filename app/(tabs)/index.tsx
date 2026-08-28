import { useCallback, useEffect, useRef, useState } from 'react';
import {
  KeyboardAvoidingView,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { Button, Card, Chip, H2, Loading, Notice, P } from '../../src/components/ui';
import {
  createConversation,
  fetchConversations,
  fetchDepartments,
  fetchMessages,
  sendMessage,
} from '../../src/lib/api';
import { useAuth } from '../../src/lib/auth';
import { CRISIS_CONTACTS, CRISIS_LINE, CRISIS_REPLY } from '../../src/lib/companion';
import { humanizeError } from '../../src/lib/supabase';
import type { Conversation, Department, Message } from '../../src/lib/types';
import { colors, font, radius, spacing, typeface } from '../../src/theme';

export default function Chat() {
  const { viewer } = useAuth();
  const sessionId =
    viewer.kind === 'anonymous' ? viewer.sessionId : viewer.kind === 'personal' ? viewer.sessionId : null;
  const companyId = viewer.kind === 'anonymous' ? viewer.companyId : null;

  const [loading, setLoading] = useState(true);
  const [conversation, setConversation] = useState<Conversation | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [department, setDepartment] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const scroller = useRef<ScrollView>(null);

  const load = useCallback(async () => {
    try {
      const [conversations, deps] = await Promise.all([fetchConversations(), fetchDepartments()]);
      setDepartments(deps);

      const latest = conversations[0] ?? null;
      setConversation(latest);
      if (latest) setMessages(await fetchMessages(latest.id));
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function start() {
    if (!sessionId) return;
    setBusy(true);
    setError('');
    try {
      const created = await createConversation(sessionId, companyId, department);
      setConversation(created);
      setMessages([]);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  async function send() {
    const text = draft.trim();
    if (!text || !conversation) return;

    setBusy(true);
    setError('');
    setDraft('');
    try {
      // turn — номер реплики, нужен собеседнику для выбора ответа без
      // повторов. Считаем по уже отрисованным сообщениям, а не по
      // запросу к базе: лишний круг ради счётчика заметен на медленной
      // связи, а ошибка на единицу здесь ничего не стоит.
      const added = await sendMessage(conversation.id, text, messages.length);
      setMessages((prev) => [...prev, ...added]);
    } catch (e) {
      setError(humanizeError(e));
      setDraft(text);
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <Loading />;

  // HR сюда не попадает по навигации, но успевает отрисоваться: корневой
  // маршрут монтируется раньше, чем срабатывает перенаправление, и
  // смонтированный экран остаётся в разметке поверх дашборда.
  //
  // Проверка стоит здесь, а не в маршрутизации, потому что не зависит от
  // того, кто успеет первым. Экран, которому нечего показать этому
  // человеку, не должен показывать ничего.
  if (viewer.kind === 'hr') return null;

  // ── Ещё не начали ────────────────────────────────────────────
  if (!conversation) {
    return (
      <ScrollView style={s.screen} contentContainerStyle={s.startContent}>
        <H2>С чего начнём?</H2>
        <P muted>
          Здесь можно писать что угодно и как угодно. Разговор не привязан к вашему имени, почте или
          устройству работодателя.
        </P>

        {viewer.kind === 'anonymous' && companyId ? (
          <Card>
            <Text style={s.label}>Отдел — по желанию</Text>
            <P muted>
              Если укажете, ваши обезличенные маркеры попадут в общий тренд отдела. Если нет — разговор
              просто не попадёт ни в один отчёт. Оба варианта нормальны.
            </P>
            <View style={s.chips}>
              {departments.map((d) => (
                <Chip
                  key={d.slug}
                  label={d.title_ru}
                  active={department === d.slug}
                  onPress={() => setDepartment(department === d.slug ? null : d.slug)}
                />
              ))}
            </View>
            {department ? (
              <Pressable onPress={() => setDepartment(null)}>
                <Text style={s.clear}>Не указывать отдел</Text>
              </Pressable>
            ) : null}
          </Card>
        ) : null}

        <Notice text={error} />
        <Button title="Начать разговор" onPress={start} loading={busy} />
      </ScrollView>
    );
  }

  // ── Разговор ─────────────────────────────────────────────────
  return (
    <KeyboardAvoidingView
      style={s.screen}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      keyboardVerticalOffset={90}
    >
      <ScrollView
        ref={scroller}
        contentContainerStyle={s.thread}
        onContentSizeChange={() => scroller.current?.scrollToEnd({ animated: true })}
      >
        {messages.length === 0 ? (
          <P muted>Напишите первое сообщение — я здесь.</P>
        ) : (
          messages.map((m) => <Bubble key={m.id} message={m} />)
        )}
        <Notice text={error} />
      </ScrollView>

      <View style={s.composer}>
        <TextInput
          value={draft}
          onChangeText={setDraft}
          placeholder="Что происходит?"
          placeholderTextColor={colors.textMuted}
          style={s.input}
          multiline
          editable={!busy}
        />
        <Pressable
          onPress={send}
          disabled={busy || !draft.trim()}
          style={({ pressed }) => [
            s.send,
            { opacity: busy || !draft.trim() ? 0.4 : pressed ? 0.8 : 1 },
          ]}
        >
          <Text style={s.sendText}>→</Text>
        </Pressable>
      </View>
    </KeyboardAvoidingView>
  );
}

function Bubble({ message }: { message: Message }) {
  const mine = message.role === 'user';

  // Кризисный ответ оформлен иначе намеренно: он должен выпадать из
  // ритма разговора, а не выглядеть очередной репликой собеседника.
  if (!mine && message.content === CRISIS_REPLY) {
    return (
      <View style={s.crisis}>
        <Text style={s.crisisText}>{message.content}</Text>

        {CRISIS_LINE ? (
          <CrisisCall number={CRISIS_LINE} title="Контакт вашей компании" note="" />
        ) : null}

        {CRISIS_CONTACTS.map((c) => (
          <CrisisCall key={c.number} number={c.number} title={c.title} note={c.note} />
        ))}

        <Text style={s.crisisHint}>
          Если звонить сейчас тяжело — напишите тому, кому доверяете. Главное, чтобы рядом оказался
          человек.
        </Text>
      </View>
    );
  }

  return (
    <View style={[s.bubble, mine ? s.bubbleMine : s.bubbleTheirs]}>
      <Text style={[s.bubbleText, mine && { color: colors.text }]}>{message.content}</Text>
    </View>
  );
}

/**
 * Номер кризисной линии — нажимаемый.
 *
 * Человеку в тяжёлом состоянии нельзя предлагать переписать цифры в
 * приложение «Телефон»: каждый лишний шаг — это возможность передумать.
 * Одно касание должно открывать набор номера.
 */
function CrisisCall({ number, title, note }: { number: string; title: string; note: string }) {
  return (
    <Pressable
      onPress={() => {
        // Молча: если набор недоступен (десктопный браузер без
        // обработчика tel:), падать с ошибкой нельзя — номер всё равно
        // виден на экране и его можно набрать вручную.
        Linking.openURL(`tel:${number.replace(/[^\d+]/g, '')}`).catch(() => {});
      }}
      style={({ pressed }) => [s.crisisCall, pressed && { opacity: 0.8 }]}
    >
      <Text selectable style={s.crisisNumber}>
        {number}
      </Text>
      <View style={{ flex: 1 }}>
        <Text style={s.crisisCallTitle}>{title}</Text>
        {note ? <Text style={s.crisisHint}>{note}</Text> : null}
      </View>
    </Pressable>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg },
  startContent: { padding: spacing.lg, gap: spacing.lg },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  label: { ...font.label, color: colors.textMuted, textTransform: 'uppercase', letterSpacing: 0.6 },
  clear: { ...font.small, color: colors.cool },

  thread: { padding: spacing.lg, gap: spacing.md, paddingBottom: spacing.xl },

  bubble: { maxWidth: '85%', borderRadius: radius.lg, padding: spacing.md },
  bubbleMine: { alignSelf: 'flex-end', backgroundColor: colors.warmSoft },
  bubbleTheirs: { alignSelf: 'flex-start', backgroundColor: colors.panel },
  bubbleText: { ...font.body, color: colors.text },

  crisis: {
    backgroundColor: colors.alertSoft,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.alert,
    padding: spacing.lg,
    gap: spacing.md,
  },
  crisisText: { ...font.body, color: colors.text },
  crisisHint: { ...font.small, color: colors.textMuted },
  crisisCall: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.panel,
    borderRadius: radius.md,
    padding: spacing.md,
  },
  crisisNumber: { ...font.h1, color: colors.alert },
  crisisCallTitle: { ...font.body, color: colors.text },

  composer: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: spacing.sm,
    padding: spacing.md,
    borderTopWidth: 1,
    borderTopColor: colors.hairline,
    backgroundColor: colors.panel,
  },
  input: {
    flex: 1,
    maxHeight: 120,
    backgroundColor: colors.panelRaised,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    color: colors.text,
    fontFamily: typeface.body400,
    fontSize: 15,
  },
  send: {
    width: 48,
    height: 48,
    borderRadius: radius.md,
    backgroundColor: colors.warm,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendText: { fontSize: 20, color: '#1A140A', fontFamily: typeface.body600 },
});
