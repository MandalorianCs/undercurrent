import type { Session } from '@supabase/supabase-js';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { bindAccessGrant, fetchHrAccount, fetchMySession, issueAccessGrant, startPersonalSession } from './api';
import { supabase } from './supabase';
import type { Viewer } from './types';

type AuthState = {
  session: Session | null;
  viewer: Viewer;
  loading: boolean;

  /** B2B, шаг 1: код подтверждения на корпоративную почту. */
  sendEmailCode: (email: string) => Promise<void>;
  verifyEmailCode: (email: string, code: string) => Promise<void>;

  /** B2B, шаг 2: взять билет, находясь в корпоративной сессии. */
  takeGrant: () => Promise<string>;

  /** B2B, шаг 3: выйти, войти анонимно, погасить билет. */
  becomeAnonymous: (code: string) => Promise<void>;

  /** B2C. */
  signUpPersonal: (email: string, password: string) => Promise<void>;
  signInPersonal: (email: string, password: string) => Promise<void>;

  signOut: () => Promise<void>;
  refresh: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: React.ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [viewer, setViewer] = useState<Viewer>({ kind: 'guest' });
  const [loading, setLoading] = useState(true);

  /**
   * Кем считать текущую сессию.
   *
   * Порядок проверок важен. Сначала признак анонимности: анонимный вход
   * не может оказаться ни HR, ни B2C-подписчиком, и лишние запросы к их
   * таблицам вернули бы пустоту, но потратили бы время на старте чата.
   */
  const resolveViewer = useCallback(async (next: Session | null): Promise<Viewer> => {
    if (!next) return { kind: 'guest' };

    const userId = next.user.id;

    if (next.user.is_anonymous) {
      const own = await fetchMySession(userId);
      return own
        ? { kind: 'anonymous', sessionId: own.id, companyId: own.company_id }
        : { kind: 'anonymous_unbound', userId };
    }

    const hr = await fetchHrAccount(userId);
    if (hr) return { kind: 'hr', userId, companyId: hr.company_id };

    const own = await fetchMySession(userId);
    if (own) return { kind: 'personal', userId, sessionId: own.id };

    return { kind: 'awaiting_grant', userId };
  }, []);

  useEffect(() => {
    let alive = true;

    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return;
      setSession(data.session);
      setViewer(await resolveViewer(data.session));
      setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange(async (_event, next) => {
      if (!alive) return;
      setSession(next);
      setViewer(await resolveViewer(next));
    });

    return () => {
      alive = false;
      sub.subscription.unsubscribe();
    };
  }, [resolveViewer]);

  const refresh = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    setSession(data.session);
    setViewer(await resolveViewer(data.session));
  }, [resolveViewer]);

  const value = useMemo<AuthState>(
    () => ({
      session,
      viewer,
      loading,

      sendEmailCode: async (email) => {
        const { error } = await supabase.auth.signInWithOtp({
          email: email.trim().toLowerCase(),
          // Код в письме, а не ссылка. Ссылка открылась бы в браузере
          // телефона отдельной сессией, а нам нужно, чтобы человек
          // остался в приложении: следующий шаг — выход и повторный
          // вход, и потерять его на переключении между приложениями
          // проще простого.
          options: { shouldCreateUser: true },
        });
        if (error) throw error;
      },

      verifyEmailCode: async (email, code) => {
        const { error } = await supabase.auth.verifyOtp({
          email: email.trim().toLowerCase(),
          token: code.trim(),
          type: 'email',
        });
        if (error) throw error;
      },

      takeGrant: async () => issueAccessGrant(),

      /**
       * Тот самый разрыв.
       *
       * Между signOut и signInAnonymously учётная запись меняется
       * полностью: у новой нет ни адреса, ни истории входов старой.
       * Код билета — единственное, что переходит границу, и после
       * привязки он перестаёт существовать.
       *
       * Порядок операций здесь не переставляется: если сначала войти
       * анонимно, не выйдя, Supabase просто заменит сессию, и в
       * хранилище на мгновение окажутся обе — а на вебе это состояние
       * переживёт перезагрузку вкладки.
       */
      becomeAnonymous: async (code) => {
        await supabase.auth.signOut();

        const { error: anonError } = await supabase.auth.signInAnonymously();
        if (anonError) throw anonError;

        await bindAccessGrant(code);
        await refresh();
      },

      signUpPersonal: async (email, password) => {
        const { error } = await supabase.auth.signUp({
          email: email.trim().toLowerCase(),
          password,
        });
        if (error) throw error;
        await startPersonalSession();
        await refresh();
      },

      signInPersonal: async (email, password) => {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim().toLowerCase(),
          password,
        });
        if (error) throw error;
        // Идемпотентно: если сессия уже есть, функция ничего не делает.
        // Нужно на случай входа с нового устройства.
        await startPersonalSession();
        await refresh();
      },

      signOut: async () => {
        await supabase.auth.signOut();
        setViewer({ kind: 'guest' });
      },

      refresh,
    }),
    [session, viewer, loading, refresh],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth вызван вне AuthProvider');
  return ctx;
}

/**
 * Из анонимной сессии выход необратим.
 *
 * У анонимного аккаунта нет ни почты, ни пароля — восстановить его
 * нечем. Выйти из него значит потерять всю переписку и дневник
 * навсегда, и человек об этом не догадывается: везде в интернете выход
 * обратим. Экран настроек обязан предупредить об этом прямо, поэтому
 * признак вынесен сюда, а не проверяется по месту.
 */
export function signOutIsDestructive(viewer: Viewer): boolean {
  return viewer.kind === 'anonymous' || viewer.kind === 'anonymous_unbound';
}
