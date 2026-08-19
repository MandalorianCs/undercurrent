// Шрифты импортируются как модули (`import Font from '….ttf'`), и без
// этого объявления TypeScript считает такой импорт ошибкой. Metro при
// этом собирает проект нормально — то есть падает только typecheck,
// и выглядит это как «tsc врёт», хотя врёт отсутствие типа.
declare module '*.ttf' {
  const asset: number;
  export default asset;
}

declare module '*.otf' {
  const asset: number;
  export default asset;
}

declare module '*.png' {
  const asset: number;
  export default asset;
}
