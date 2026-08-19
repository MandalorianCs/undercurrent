import { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Card, Chip, Field, H1, H2, Notice, P, Screen } from '../src/components/ui';
import { useAuth } from '../src/lib/auth';
import { humanizeError } from '../src/lib/supabase';
import { colors, font, spacing, typeface } from '../src/theme';

type Mode = 'corporate' | 'personal';
type Step = 'email' | 'code' | 'grant' | 'anonymous';

export default function SignIn() {
  const { viewer, sendEmailCode, verifyEmailCode, takeGrant, becomeAnonymous, signInPersonal, signUpPersonal } =
    useAuth();

  const [mode, setMode] = useState<Mode>('corporate');
  const [step, setStep] = useState<Step>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [password, setPassword] = useState('');
  const [grant, setGrant] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  // Экран входа переживает перезагрузку: если человек уже подтвердил
  // почту, но закрыл приложение до получения билета, он возвращается не
  // на первый шаг, а туда, где остановился.
  const resumed =
    viewer.kind === 'awaiting_grant' ? 'grant' : viewer.kind === 'anonymous_unbound' ? 'anonymous' : null;
  const current: Step = resumed ?? step;

  async function run(fn: () => Promise<void>) {
    setBusy(true);
    setError('');
    try {
      await fn();
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Screen>
      <View style={{ gap: spacing.sm, paddingTop: spacing.xxl }}>
        <H1>Undercurrent</H1>
        <P muted>Слышим то, что не говорят вслух</P>
      </View>

      {current === 'email' ? (
        <View style={{ flexDirection: 'row', gap: spacing.sm }}>
          <Chip label="Я сотрудник компании" active={mode === 'corporate'} onPress={() => setMode('corporate')} />
          <Chip label="Личная подписка" active={mode === 'personal'} onPress={() => setMode('personal')} />
        </View>
      ) : null}

      {/* ── B2C: обычная регистрация, без билетов ────────────── */}
      {mode === 'personal' && current === 'email' ? (
        <Card>
          <H2>Личный доступ</H2>
          <P muted>
            Аккаунт ваш и только ваш. Работодатель к нему отношения не имеет: он не узнает ни что вы
            зарегистрированы, ни что вы пишете.
          </P>
          <Field
            label="Почта"
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            keyboardType="email-address"
            placeholder="you@example.com"
          />
          <Field
            label="Пароль"
            value={password}
            onChangeText={setPassword}
            secureTextEntry
            placeholder="Не короче шести знаков"
          />
          <Notice text={error} />
          <Button title="Войти" onPress={() => run(() => signInPersonal(email, password))} loading={busy} />
          <Button
            title="Создать аккаунт"
            variant="ghost"
            onPress={() => run(() => signUpPersonal(email, password))}
            disabled={busy}
          />
        </Card>
      ) : null}

      {/* ── B2B, шаг 1: подтверждение корпоративной почты ────── */}
      {mode === 'corporate' && current === 'email' ? (
        <Card>
          <H2>Шаг 1 из 3 — подтверждение работы в компании</H2>
          <P muted>
            Почта нужна ровно для одного: убедиться, что вы сотрудник подключённой компании. Дальше она
            больше нигде не появится — ни в переписке, ни в отчётах.
          </P>
          <Field
            label="Корпоративная почта"
            value={email}
            onChangeText={setEmail}
            autoCapitalize="none"
            keyboardType="email-address"
            placeholder="name@company.kz"
          />
          <Notice text={error} />
          <Button
            title="Получить код"
            onPress={() => run(async () => {
              await sendEmailCode(email);
              setStep('code');
            })}
            loading={busy}
            disabled={!email.includes('@')}
          />
        </Card>
      ) : null}

      {mode === 'corporate' && current === 'code' ? (
        <Card>
          <H2>Код из письма</H2>
          <P muted>Отправили на {email}. Письмо приходит за минуту, иногда попадает в спам.</P>
          <Field
            label="Код"
            value={code}
            onChangeText={setCode}
            keyboardType="number-pad"
            placeholder="000000"
          />
          <Notice text={error} />
          <Button
            title="Подтвердить"
            onPress={() => run(async () => {
              await verifyEmailCode(email, code);
              setStep('grant');
            })}
            loading={busy}
            disabled={code.trim().length < 6}
          />
          <Button title="Изменить адрес" variant="ghost" onPress={() => setStep('email')} disabled={busy} />
        </Card>
      ) : null}

      {/* ── B2B, шаг 2: билет ─────────────────────────────────
          Самый важный экран продукта. Человека сейчас попросят выйти
          из аккаунта, в который он только что вошёл, — и если не
          объяснить зачем, это выглядит как ошибка приложения. */}
      {mode === 'corporate' && current === 'grant' ? (
        <Card>
          <H2>Шаг 2 из 3 — одноразовый код доступа</H2>
          <P muted>
            Сейчас вы получите код и выйдете из корпоративного аккаунта. Это не сбой — так устроена
            анонимность.
          </P>
          <P muted>
            Ваш адрес останется на стороне проверки доступа, а чат начнётся с чистой учётной записи, у
            которой нет ни почты, ни имени. Код — единственное, что переходит между ними, и он
            стирается сразу после использования.
          </P>

          {grant ? (
            <View
              style={{
                backgroundColor: colors.panelRaised,
                borderRadius: 12,
                paddingVertical: spacing.lg,
                alignItems: 'center',
                gap: spacing.xs,
              }}
            >
              <GrantCode code={grant} />
              <P muted>Запишите или запомните — второй раз он не показывается</P>
            </View>
          ) : null}

          <Notice text={error} />

          {grant ? (
            <Button
              title="Выйти и продолжить анонимно"
              onPress={() => run(() => becomeAnonymous(grant))}
              loading={busy}
            />
          ) : (
            <Button title="Получить код" onPress={() => run(async () => setGrant(await takeGrant()))} loading={busy} />
          )}
        </Card>
      ) : null}

      {/* ── B2B, шаг 3: анонимная сессия без привязки ─────────
          Сюда попадают, если приложение закрылось между выходом и
          привязкой. Код у человека на руках, сессия уже анонимная. */}
      {current === 'anonymous' ? (
        <Card>
          <H2>Шаг 3 из 3 — привязка кода</H2>
          <P muted>
            Вы вошли анонимно. Введите код, который получили на прошлом шаге, — он свяжет эту сессию с
            вашей компанией, не связывая её с вами.
          </P>
          <Field
            label="Код доступа"
            value={grant}
            onChangeText={setGrant}
            autoCapitalize="characters"
            placeholder="UC-XXXX-XXXX-XXXX"
          />
          <Notice text={error} />
          <Button
            title="Войти в чат"
            onPress={() => run(() => becomeAnonymous(grant))}
            loading={busy}
            disabled={grant.trim().length < 8}
          />
        </Card>
      ) : null}

      <P muted>
        Работодатель никогда не получает доступ к переписке — ни через приложение, ни через запрос в
        поддержку. Он видит только обезличенные тренды по отделам, и только если в отделе достаточно
        людей, чтобы никого нельзя было узнать.
      </P>
    </Screen>
  );
}

/**
 * Код билета.
 *
 * Крупно, с разрядкой и выделяемый: его переписывают с экрана телефона
 * на ноутбук или диктуют вслух. selectable нужен на вебе — там код
 * копируют мышью, и без него приходится набирать руками при живой
 * возможности скопировать.
 */
function GrantCode({ code }: { code: string }) {
  return (
    <Text
      selectable
      style={{
        ...font.h2,
        fontFamily: typeface.body600,
        color: colors.warm,
        letterSpacing: 2,
        textAlign: 'center',
      }}
    >
      {code}
    </Text>
  );
}
