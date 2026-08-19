import { Ionicons } from '@expo/vector-icons';
import { Tabs } from 'expo-router';
import { useAuth } from '../../src/lib/auth';
import { colors, typeface } from '../../src/theme';

/**
 * Вкладки разные у сотрудника и у HR.
 *
 * Скрытые вкладки помечены href: null — маршрут перестаёт быть
 * достижимым, а не просто исчезает из панели. Разница видна, если
 * набрать адрес руками в веб-версии: спрятанная кнопка от этого не
 * защищает, отсутствующий маршрут защищает.
 *
 * Настоящая же граница всё равно не здесь, а в политиках RLS: даже
 * дойдя до экрана дашборда, HR получит из базы только те срезы, которые
 * ему полагаются, а сотрудник — ничего.
 */
export default function TabsLayout() {
  const { viewer } = useAuth();
  const isHr = viewer.kind === 'hr';

  return (
    <Tabs
      screenOptions={{
        headerStyle: { backgroundColor: colors.bg },
        headerTintColor: colors.text,
        headerTitleStyle: { fontFamily: typeface.display600 },
        headerShadowVisible: false,
        sceneStyle: { backgroundColor: colors.bg },
        tabBarStyle: { backgroundColor: colors.panel, borderTopColor: colors.hairline },
        tabBarActiveTintColor: colors.warm,
        tabBarInactiveTintColor: colors.textMuted,
        tabBarLabelStyle: { fontFamily: typeface.body500, fontSize: 11 },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: 'Разговор',
          href: isHr ? null : '/',
          tabBarIcon: ({ color, size }) => <Ionicons name="chatbubble-outline" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="diary"
        options={{
          title: 'Дневник',
          href: isHr ? null : '/diary',
          tabBarIcon: ({ color, size }) => <Ionicons name="pulse-outline" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="dashboard"
        options={{
          title: 'Риски',
          href: isHr ? '/dashboard' : null,
          tabBarIcon: ({ color, size }) => <Ionicons name="analytics-outline" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="tariff"
        options={{
          title: 'Тариф',
          href: isHr ? '/tariff' : null,
          tabBarIcon: ({ color, size }) => <Ionicons name="card-outline" color={color} size={size} />,
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Настройки',
          tabBarIcon: ({ color, size }) => <Ionicons name="settings-outline" color={color} size={size} />,
        }}
      />
    </Tabs>
  );
}
