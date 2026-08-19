import React from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  type TextInputProps,
  View,
} from 'react-native';
import { colors, elevation, font, radius, spacing, typeface } from '../theme';

export function Button({
  title,
  onPress,
  variant = 'primary',
  disabled,
  loading,
}: {
  title: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
  disabled?: boolean;
  loading?: boolean;
}) {
  const palette = {
    primary: { bg: colors.warm, fg: '#1A140A' },
    secondary: { bg: colors.coolSoft, fg: colors.cool },
    ghost: { bg: 'transparent', fg: colors.textMuted },
    danger: { bg: colors.alertSoft, fg: colors.alert },
  }[variant];

  const blocked = disabled || loading;

  return (
    <Pressable
      onPress={onPress}
      disabled={blocked}
      style={({ pressed }) => [
        s.button,
        { backgroundColor: palette.bg, opacity: blocked ? 0.45 : pressed ? 0.85 : 1 },
        variant === 'ghost' && { borderWidth: 1, borderColor: colors.hairline },
      ]}
    >
      {loading ? (
        <ActivityIndicator color={palette.fg} />
      ) : (
        <Text style={[s.buttonText, { color: palette.fg }]}>{title}</Text>
      )}
    </Pressable>
  );
}

export function Card({ children, style }: { children: React.ReactNode; style?: object }) {
  return <View style={[s.card, style]}>{children}</View>;
}

export function Badge({ label, fg, bg }: { label: string; fg: string; bg: string }) {
  return (
    <View style={[s.badge, { backgroundColor: bg }]}>
      <Text style={[s.badgeText, { color: fg }]}>{label}</Text>
    </View>
  );
}

export function Field({
  label,
  hint,
  ...props
}: TextInputProps & { label?: string; hint?: string }) {
  return (
    <View style={{ gap: spacing.xs }}>
      {label ? <Text style={s.label}>{label}</Text> : null}
      <TextInput
        placeholderTextColor={colors.textMuted}
        {...props}
        style={[s.input, props.multiline && { minHeight: 96, textAlignVertical: 'top' }, props.style]}
      />
      {hint ? <Text style={s.hint}>{hint}</Text> : null}
    </View>
  );
}

/** Выбор из немногих вариантов: отдел, оценка настроения, период оплаты. */
export function Chip({
  label,
  active,
  onPress,
}: {
  label: string;
  active: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        s.chip,
        active && { backgroundColor: colors.coolSoft, borderColor: colors.cool },
        pressed && { opacity: 0.8 },
      ]}
    >
      <Text style={[s.chipText, active && { color: colors.cool }]}>{label}</Text>
    </Pressable>
  );
}

export function Screen({
  children,
  scroll = true,
}: {
  children: React.ReactNode;
  scroll?: boolean;
}) {
  if (!scroll) return <View style={s.screen}>{children}</View>;
  return (
    <ScrollView
      style={{ backgroundColor: colors.bg }}
      contentContainerStyle={s.screenContent}
      keyboardShouldPersistTaps="handled"
    >
      {children}
    </ScrollView>
  );
}

export function H1({ children }: { children: React.ReactNode }) {
  return <Text style={s.h1}>{children}</Text>;
}

export function H2({ children }: { children: React.ReactNode }) {
  return <Text style={s.h2}>{children}</Text>;
}

export function P({ children, muted }: { children: React.ReactNode; muted?: boolean }) {
  return <Text style={[s.p, muted && { color: colors.textMuted }]}>{children}</Text>;
}

/**
 * Сообщение об ошибке.
 *
 * Отдельный компонент, а не Text с красным цветом: ошибка в этом
 * продукте часто означает «так и задумано» (нет доступа к чужим данным),
 * и её оформление не должно выглядеть как поломка.
 */
export function Notice({ text, tone = 'warn' }: { text: string; tone?: 'warn' | 'info' }) {
  if (!text) return null;
  const palette =
    tone === 'info'
      ? { fg: colors.cool, bg: colors.coolSoft }
      : { fg: colors.alert, bg: colors.alertSoft };
  return (
    <View style={[s.notice, { backgroundColor: palette.bg }]}>
      <Text style={[s.noticeText, { color: palette.fg }]}>{text}</Text>
    </View>
  );
}

export function Empty({ title, hint }: { title: string; hint?: string }) {
  return (
    <View style={s.empty}>
      <Text style={s.emptyTitle}>{title}</Text>
      {hint ? <Text style={s.emptyHint}>{hint}</Text> : null}
    </View>
  );
}

export function Loading() {
  return (
    <View style={s.loading}>
      <ActivityIndicator color={colors.warm} />
    </View>
  );
}

const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.bg },
  screenContent: { padding: spacing.lg, gap: spacing.lg, paddingBottom: spacing.xxl },

  button: {
    height: 50,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: spacing.lg,
  },
  buttonText: { fontSize: 15, fontFamily: typeface.body600 },

  card: {
    backgroundColor: colors.panel,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.hairline,
    padding: spacing.lg,
    gap: spacing.md,
    ...elevation.card,
  },

  badge: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.xs,
    borderRadius: radius.pill,
    alignSelf: 'flex-start',
  },
  badgeText: { ...font.label },

  label: { ...font.label, color: colors.textMuted, textTransform: 'uppercase', letterSpacing: 0.6 },
  input: {
    backgroundColor: colors.panelRaised,
    borderWidth: 1,
    borderColor: colors.hairline,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.md,
    color: colors.text,
    fontFamily: typeface.body400,
    fontSize: 15,
  },
  hint: { ...font.small, color: colors.textMuted },

  chip: {
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.hairline,
    backgroundColor: colors.panel,
  },
  chipText: { ...font.small, color: colors.textMuted },

  h1: { ...font.h1, color: colors.text },
  h2: { ...font.h2, color: colors.text },
  p: { ...font.body, color: colors.text },

  notice: { borderRadius: radius.md, padding: spacing.md },
  noticeText: { ...font.small, lineHeight: 20 },

  empty: { paddingVertical: spacing.xxl, gap: spacing.sm, alignItems: 'center' },
  emptyTitle: { ...font.body, color: colors.text, textAlign: 'center' },
  emptyHint: { ...font.small, color: colors.textMuted, textAlign: 'center' },

  loading: { flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg },
});
