import { useState } from 'react';
import { Linking, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Button, Card, H2, Notice, P, Screen } from '../../src/components/ui';
import { deleteMyData, exportMyData, issueTelegramLinkCode } from '../../src/lib/api';
import { signOutIsDestructive, useAuth } from '../../src/lib/auth';
import { humanizeError } from '../../src/lib/supabase';
import { colors, font, radius, spacing, typeface } from '../../src/theme';

/**
 * Имя бота из окружения: у разработки и продакшна они разные, а зашитое
 * в код имя однажды уведёт тестового пользователя в боевого бота.
 */
const TELEGRAM_BOT = process.env.EXPO_PUBLIC_TELEGRAM_BOT ?? 'UndercurrentBot';

export default function Settings() {
  const { viewer, signOut } = useAuth();

  const [dump, setDump] = useState<string>('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [tgCode, setTgCode] = useState('');

  const destructiveSignOut = signOutIsDestructive(viewer);

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
      <Card>
        <H2>Кто вы для системы</H2>
        {viewer.kind === 'anonymous' ? (
          <>
            <P>Анонимная сессия{viewer.companyId ? ' сотрудника подключённой компании' : ''}.</P>
            <P muted>
              У этой учётной записи нет ни почты, ни имени, ни телефона. Ваш работодатель знает, что
              кто-то из компании пользуется продуктом, но не знает кто — и не может узнать.
            </P>
            <Text style={s.mono} selectable>
              {viewer.sessionId}
            </Text>
            <P muted>
              Это единственный идентификатор ваших разговоров. Он сгенерирован случайно и ни с чем не
              связан.
            </P>
          </>
        ) : viewer.kind === 'personal' ? (
          <>
            <P>Личная подписка.</P>
            <P muted>
              Аккаунт ваш: история сохраняется между устройствами, и вы можете забрать её или удалить в
              любой момент. Работодатель к нему отношения не имеет.
            </P>
          </>
        ) : viewer.kind === 'hr' ? (
          <>
            <P>HR-аккаунт.</P>
            <P muted>
              Вам доступны только агрегированные срезы по отделам, где выборка достаточно велика.
              Переписка сотрудников недоступна ни через приложение, ни через запрос в поддержку — её
              нельзя связать с человеком даже на стороне базы.
            </P>
          </>
        ) : null}
      </Card>

      {/* Telegram доступен именным аккаунтам: HR и личной подписке.
          Анонимной сессии функция в базе откажет, поэтому и кнопку ей
          не показываем — предлагать действие, которое заведомо не
          сработает, значит выглядеть сломанным. */}
      {viewer.kind === 'hr' || viewer.kind === 'personal' ? (
        <Card>
          <H2>Подключить Telegram</H2>
          <P muted>
            {viewer.kind === 'hr'
              ? 'Изменения по отделам будут приходить в Telegram. Только цифры — переписки там не будет никогда.'
              : 'Напоминания про дневник и важное. Разговор с собеседником остаётся в приложении: Telegram знает ваш номер телефона, а приложение о вас не знает ничего.'}
          </P>
          <Notice text={error} />
          {tgCode ? (
            <>
              <Button
                title="Открыть бота и привязать"
                onPress={() => {
                  Linking.openURL(`https://t.me/${TELEGRAM_BOT}?start=${tgCode}`).catch(() => {});
                }}
              />
              <P muted>Ссылка действует пятнадцать минут.</P>
            </>
          ) : (
            <Button
              title="Получить ссылку"
              variant="secondary"
              onPress={() => run(async () => setTgCode(await issueTelegramLinkCode()))}
              loading={busy}
            />
          )}
        </Card>
      ) : null}

      {viewer.kind !== 'hr' ? (
        <>
          <Card>
            <H2>Забрать свои данные</H2>
            <P muted>
              Выгрузка содержит все ваши разговоры и записи дневника в открытом виде. Ничего, кроме
              них, о вас не хранится.
            </P>
            <Button
              title="Показать выгрузку"
              variant="secondary"
              onPress={() => run(async () => setDump(JSON.stringify(await exportMyData(), null, 2)))}
              loading={busy}
            />
            {dump ? (
              <ScrollView style={s.dump} nestedScrollEnabled>
                <Text selectable style={s.dumpText}>
                  {dump}
                </Text>
              </ScrollView>
            ) : null}
          </Card>

          <Card>
            <H2>Удалить историю</H2>
            <P muted>
              Разговоры, сообщения и дневник исчезнут безвозвратно. Доступ к продукту при этом
              сохранится, и для работодателя это не будет выглядеть никаким событием — он и так не
              видел, что вы им пользуетесь.
            </P>
            <Notice text={error} />
            {confirmDelete ? (
              <>
                <Notice text="Это необратимо. Выгрузите данные, если они вам нужны." />
                <Button
                  title="Да, удалить всё"
                  variant="danger"
                  onPress={() =>
                    run(async () => {
                      await deleteMyData();
                      setDump('');
                      setConfirmDelete(false);
                    })
                  }
                  loading={busy}
                />
                <Button title="Отмена" variant="ghost" onPress={() => setConfirmDelete(false)} />
              </>
            ) : (
              <Button title="Удалить историю" variant="danger" onPress={() => setConfirmDelete(true)} />
            )}
          </Card>
        </>
      ) : null}

      <Card>
        <H2>Выход</H2>
        {destructiveSignOut ? (
          <P muted>
            Внимание: у анонимной сессии нет ни почты, ни пароля — войти в неё обратно невозможно.
            Выход означает потерю всей переписки и дневника навсегда. Чтобы пользоваться продуктом
            снова, придётся получить новый билет у работодателя.
          </P>
        ) : (
          <P muted>Вы сможете войти обратно по своей почте.</P>
        )}

        {destructiveSignOut && !confirmSignOut ? (
          <Button title="Выйти" variant="ghost" onPress={() => setConfirmSignOut(true)} />
        ) : (
          <Button
            title={destructiveSignOut ? 'Понимаю, выйти и потерять историю' : 'Выйти'}
            variant={destructiveSignOut ? 'danger' : 'ghost'}
            onPress={() => run(signOut)}
            loading={busy}
          />
        )}
        {confirmSignOut ? (
          <Button title="Остаться" variant="ghost" onPress={() => setConfirmSignOut(false)} />
        ) : null}
      </Card>
    </Screen>
  );
}

const s = StyleSheet.create({
  mono: {
    ...font.small,
    fontFamily: typeface.body500,
    color: colors.cool,
    backgroundColor: colors.panelRaised,
    padding: spacing.md,
    borderRadius: radius.sm,
  },
  dump: {
    maxHeight: 260,
    backgroundColor: colors.panelRaised,
    borderRadius: radius.sm,
    padding: spacing.md,
  },
  dumpText: { ...font.small, color: colors.textMuted, fontFamily: typeface.body400 },
});
