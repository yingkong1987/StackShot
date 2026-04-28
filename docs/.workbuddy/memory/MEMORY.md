# StackShot 项目长期记忆

## 网站技术栈
- 静态站点，托管于 GitHub Pages
- 零依赖，纯 HTML + CSS + JS
- 多语言：TOP15 语言，JS 动态构建下拉菜单，三层语言检测（URL 参数 > localStorage > navigator.languages）
- 文件结构：docs/ (index.html, assets/site.css, assets/site.js, privacy/index.html, support/index.html)

## 视觉风格（2026-04-28 重设计）
- 科技感深色主题：#070b12 背景 + #00d4ff 青色霓虹主色调
- 动态网格背景 + 粒子效果（Canvas）+ 悬浮动画
- 之前是 Vermeer 暖象牙风格（已替换）

## 支持语言列表（TOP15）
en, zh-Hans, zh-Hant, es-ES, hi, ar, pt-BR, fr, ru, de, ja, ko, id, it, nl

## 开发注意事项
- privacy/index.html 和 support/index.html 需要保持与 index.html 相同的语言切换器结构
- 添加新语言需要：① JS 的 LANGUAGES 数组 ② uiCopy ③ languagePanelMap ④ htmlLangCodes ⑤ normalizeLanguage ⑥ 各页面 data-title-xxx 属性 ⑦ lang-panel 内容块
