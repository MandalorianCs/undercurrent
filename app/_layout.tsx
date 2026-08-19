// Импортируем каждое начертание отдельным путём, а не через index
// пакета. Бочка тянет все веса, включая те, которых в макете нет, —
// это лишние сотни килобайт шрифтов в бандле на каждой платформе.
import Fraunces_400Regular from '@expo-google-fonts/fraunces/400Regular/Fraunces_400Regular.ttf';
import Fraunces_600SemiBold from '@expo-google-fonts/fraunces/600SemiBold/Fraunces_600SemiBold.ttf';
import IBMPlexSans_400Regular from '@expo-google-fonts/ibm-plex-sans/400Regular/IBMPlexSans_400Regular.ttf';
import IBMPlexSans_500Medium from '@expo-google-fonts/ibm-plex-sans/500Medium/IBMPlexSans_500Medium.ttf';
import IBMPlexSans_600SemiBold from '@expo-google-fonts/ibm-plex-sans/600SemiBold/IBMPlexSans_600SemiBold.ttf';
import { useFonts } from 'expo-font';
import { Stack, useRouter, useSegments } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect } from 'react';
import { View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { Loading } from '../src/components/ui';
import { AuthProvider, useAuth } from '../src/lib/auth';
import { colors, typeface } from '../src/theme';

/**
 * Гейт входа. Держим его здесь, а не в каждом экране: если проверку
 * копировать по файлам, рано или поздно появится экран, куда можно
 * попасть без сессии.
 *
 * Промежуточные состояния (взял почту, но не билет; вошёл анонимно, но
 * не привязал) остаются на экране входа — там для них есть свои шаги.
 * Пустить их дальше значило бы показать чат без сессии, в которую можно
 * писать, и человек решил бы, что продукт сломан.
 */
function AuthGate({ children }: { children: React.ReactNode }) {
  const { viewer, loading } = useAuth();
  const segments = useSegments();
  const router = useRouter();

  useEffect(() => {
    if (loading) return;

    const seg = segments as string[];
    const onSignIn = seg[0] === 'sign-in';
    const ready = viewer.kind === 'anonymous' || viewer.kind === 'personal' || viewer.kind === 'hr';

    if (!ready && !onSignIn) router.replace('/sign-in');
    if (ready && onSignIn) router.replace('/');
  }, [viewer, loading, segments, router]);

  if (loading) return <Loading />;

  return <>{children}</>;
}

export default function RootLayout() {
  const [fontsReady] = useFonts({
    Fraunces_400Regular,
    Fraunces_600SemiBold,
    IBMPlexSans_400Regular,
    IBMPlexSans_500Medium,
    IBMPlexSans_600SemiBold,
  });

  // Пока шрифт не загружен, рисовать нельзя: иначе первый кадр уйдёт
  // системным шрифтом и текст прыгнет при подмене. Экран остаётся
  // фоновым цветом бренда, а не белым — подмены фона тоже не видно.
  if (!fontsReady) {
    return <View style={{ flex: 1, backgroundColor: colors.bg }} />;
  }

  return (
    <SafeAreaProvider>
      <AuthProvider>
        <StatusBar style="light" />
        <AuthGate>
          <Stack
            screenOptions={{
              headerStyle: { backgroundColor: colors.bg },
              headerTintColor: colors.text,
              headerTitleStyle: { fontFamily: typeface.display600 },
              headerShadowVisible: false,
              contentStyle: { backgroundColor: colors.bg },
            }}
          >
            <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
            <Stack.Screen name="sign-in" options={{ headerShown: false }} />
          </Stack>
        </AuthGate>
      </AuthProvider>
    </SafeAreaProvider>
  );
}
