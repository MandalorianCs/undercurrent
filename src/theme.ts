/**
 * Палитра перенесена один в один с лендинга и деки Undercurrent
 * («Сайт презентация приложение/index.html»), включая имена ролей.
 * Инвестор, открывший сайт и приложение подряд, должен увидеть один
 * продукт, а не два похожих.
 *
 * Тема тёмная, и это не мода. Продуктом пользуются вечером и ночью —
 * ровно тогда, когда человек остаётся один на один с тем, что накопил
 * за день. Светлый экран в темноте читается как «рабочий инструмент»,
 * а этот разговор не рабочий.
 */
export const colors = {
  bg: '#12151C',
  panel: '#1A1E27',
  panelRaised: '#20242F',
  hairline: '#2A2F3B',
  text: '#ECE8DF',
  textMuted: '#8B90A0',
  /** Тёплый акцент — человек, его состояние, его реплики. */
  warm: '#D9A15B',
  warmSoft: '#3A311F',
  /** Холодный акцент — система, аналитика, «всё в порядке». */
  cool: '#6FA98C',
  coolSoft: '#1D2B26',
  /** Риск: не красный. Красный в продукте про выгорание читается как */
  /** тревога и подталкивает HR к резким решениям. Приглушённая охра */
  /** говорит «посмотрите сюда», а не «горит». */
  alert: '#C4703F',
  alertSoft: '#312014',
} as const;

export const spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 } as const;

export const radius = { sm: 8, md: 12, lg: 16, pill: 999 } as const;

/**
 * Тень задаётся токеном, а не по месту: карточка отдела на дашборде и
 * пузырь сообщения в чате должны лежать на одной высоте, иначе интерфейс
 * выглядит собранным из кусков.
 *
 * shadow* работает на iOS и в вебе (react-native-web переводит их в
 * box-shadow), elevation — на Android. Нужны оба набора, одного мало.
 */
export const elevation = {
  card: {
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.35,
    shadowRadius: 16,
    elevation: 2,
  },
  raised: {
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.45,
    shadowRadius: 22,
    elevation: 6,
  },
} as const;

/**
 * Начертания те же, что на лендинге: Fraunces для заголовков, IBM Plex
 * Sans для текста.
 *
 * Важно: со своим шрифтом `fontWeight` работать перестаёт. На Android он
 * игнорируется, на iOS и в вебе рисуется синтетическая жирность — кривая
 * и разная на разных платформах. Поэтому вес выбирается именем файла,
 * а не числом: fontFamily: typeface.body600 вместо fontWeight: '600'.
 */
export const typeface = {
  display400: 'Fraunces_400Regular',
  display600: 'Fraunces_600SemiBold',
  body400: 'IBMPlexSans_400Regular',
  body500: 'IBMPlexSans_500Medium',
  body600: 'IBMPlexSans_600SemiBold',
} as const;

export const font = {
  h1: { fontSize: 28, fontFamily: typeface.display600 },
  h2: { fontSize: 20, fontFamily: typeface.display600 },
  /** Заголовок-цитата: Fraunces обычного веса, крупно и с воздухом. */
  quote: { fontSize: 22, fontFamily: typeface.display400, lineHeight: 32 },
  body: { fontSize: 15, fontFamily: typeface.body400, lineHeight: 22 },
  small: { fontSize: 13, fontFamily: typeface.body400 },
  label: { fontSize: 12, fontFamily: typeface.body600 },
} as const;

/**
 * Цвет уровня риска для дашборда HR.
 *
 * Порогов три, а не пять: HR принимает по этой цифре одно из трёх
 * решений — не трогать, присмотреться, вмешаться. Шкала с большим числом
 * градаций создаёт видимость точности, которой в оценке по текстовым
 * маркерам нет.
 */
export function riskTone(score: number): { fg: string; bg: string; label: string } {
  if (score >= 60) return { fg: colors.alert, bg: colors.alertSoft, label: 'Высокий' };
  if (score >= 35) return { fg: colors.warm, bg: colors.warmSoft, label: 'Повышенный' };
  return { fg: colors.cool, bg: colors.coolSoft, label: 'Спокойно' };
}
