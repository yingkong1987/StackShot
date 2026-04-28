const supportedLanguages = [
  "en", "en-US", "en-GB", "en-AU", "en-CA",
  "zh-Hans", "zh-Hant",
  "es-ES", "es-MX",
  "ja",
  "de",
  "fr", "fr-CA",
  "ko",
  "pt-BR", "pt-PT",
  "ru",
  "ar"
];

const languagePanelMap = {
  en: "en",
  "en-US": "en",
  "en-GB": "en",
  "en-AU": "en",
  "en-CA": "en",
  "zh-Hans": "zh-Hans",
  "zh-Hant": "zh-Hant",
  "es-ES": "es-ES",
  "es-MX": "es-ES",
  ja: "ja",
  de: "de",
  fr: "fr",
  "fr-CA": "fr",
  ko: "ko",
  "pt-BR": "pt-BR",
  "pt-PT": "pt-BR",
  ru: "ru",
  ar: "ar"
};

const uiCopy = {
  "zh-Hans": {
    home: "主页",
    privacy: "隐私政策",
    support: "支持",
    footer: "StackShot 是一款面向 macOS 的本地优先截图工具，覆盖捕获、标注与 OCR 工作流。",
    languageLabel: "切换语言"
  },
  "zh-Hant": {
    home: "首頁",
    privacy: "隱私政策",
    support: "支援",
    footer: "StackShot 是一款面向 macOS 的本機優先截圖工具，涵蓋擷取、標註與 OCR 工作流。",
    languageLabel: "切換語言"
  },
  en: {
    home: "Home",
    privacy: "Privacy",
    support: "Support",
    footer: "StackShot is a local-first macOS screenshot tool for capture, annotation, and OCR workflows.",
    languageLabel: "Switch language"
  },
  "es-ES": {
    home: "Inicio",
    privacy: "Privacidad",
    support: "Soporte",
    footer: "StackShot es una herramienta de capturas para macOS centrada en el procesamiento local, con flujos de captura, anotación y OCR.",
    languageLabel: "Cambiar idioma"
  },
  ja: {
    home: "ホーム",
    privacy: "プライバシー",
    support: "サポート",
    footer: "StackShot はキャプチャ、注釈、OCR をひとつにまとめた macOS 向けローカル優先ツールです。",
    languageLabel: "言語を切り替える"
  },
  de: {
    home: "Startseite",
    privacy: "Datenschutz",
    support: "Support",
    footer: "StackShot ist ein lokal orientiertes macOS-Screenshot-Tool für Aufnahme, Annotation und OCR.",
    languageLabel: "Sprache wechseln"
  },
  fr: {
    home: "Accueil",
    privacy: "Confidentialité",
    support: "Assistance",
    footer: "StackShot est un outil de capture d’écran macOS orienté local pour la capture, l’annotation et l’OCR.",
    languageLabel: "Changer de langue"
  },
  ko: {
    home: "홈",
    privacy: "개인정보 처리방침",
    support: "지원",
    footer: "StackShot은 캡처, 주석, OCR 작업을 위한 로컬 우선 macOS 스크린샷 도구입니다.",
    languageLabel: "언어 전환"
  },
  "pt-BR": {
    home: "Início",
    privacy: "Privacidade",
    support: "Suporte",
    footer: "StackShot é uma ferramenta de captura de tela para macOS com abordagem local-first para captura, anotação e OCR.",
    languageLabel: "Mudar idioma"
  },
  ru: {
    home: "Главная",
    privacy: "Конфиденциальность",
    support: "Поддержка",
    footer: "StackShot — локальный инструмент macOS для снимков экрана, аннотаций и OCR.",
    languageLabel: "Сменить язык"
  },
  ar: {
    home: "الرئيسية",
    privacy: "الخصوصية",
    support: "الدعم",
    footer: "StackShot أداة لقطات شاشة محلية أولًا على macOS لالتقاط الشاشة والشرح وOCR.",
    languageLabel: "تبديل اللغة"
  }
};

const htmlLangCodes = {
  en: "en",
  "en-US": "en-US",
  "en-GB": "en-GB",
  "en-AU": "en-AU",
  "en-CA": "en-CA",
  "zh-Hans": "zh-CN",
  "zh-Hant": "zh-TW",
  "es-ES": "es",
  "es-MX": "es-MX",
  ja: "ja",
  de: "de",
  fr: "fr",
  "fr-CA": "fr-CA",
  ko: "ko",
  "pt-BR": "pt-BR",
  "pt-PT": "pt-PT",
  ru: "ru",
  ar: "ar"
};

const rtlLanguages = new Set(["ar"]);

function resolvePanelLanguage(language) {
  return languagePanelMap[language] || "en";
}

function resolveUiCopy(language) {
  return uiCopy[language] || uiCopy[resolvePanelLanguage(language)] || uiCopy.en;
}

function normalizeLanguage(rawLanguage) {
  const value = (rawLanguage || "").toLowerCase();

  if (value.startsWith("zh-hant") || value.startsWith("zh-tw") || value.startsWith("zh-hk") || value.startsWith("zh-mo")) {
    return "zh-Hant";
  }

  if (value.startsWith("zh")) {
    return "zh-Hans";
  }

  if (value.startsWith("es-mx")) {
    return "es-MX";
  }

  if (value.startsWith("es")) {
    return "es-ES";
  }

  if (value.startsWith("ja")) {
    return "ja";
  }

  if (value.startsWith("de")) {
    return "de";
  }

  if (value.startsWith("fr-ca")) {
    return "fr-CA";
  }

  if (value.startsWith("fr")) {
    return "fr";
  }

  if (value.startsWith("ko")) {
    return "ko";
  }

  if (value.startsWith("pt-br")) {
    return "pt-BR";
  }

  if (value.startsWith("pt")) {
    return "pt-PT";
  }

  if (value.startsWith("ru")) {
    return "ru";
  }

  if (value.startsWith("ar")) {
    return "ar";
  }

  if (value.startsWith("en-us")) {
    return "en-US";
  }

  if (value.startsWith("en-gb")) {
    return "en-GB";
  }

  if (value.startsWith("en-au")) {
    return "en-AU";
  }

  if (value.startsWith("en-ca")) {
    return "en-CA";
  }

  return "en";
}

function updateLanguageLinks(language) {
  document.querySelectorAll("[data-lang-link]").forEach((anchor) => {
    const rawHref = anchor.getAttribute("data-raw-href") || anchor.getAttribute("href");
    if (!anchor.hasAttribute("data-raw-href")) {
      anchor.setAttribute("data-raw-href", rawHref);
    }

    const url = new URL(rawHref, window.location.href);
    url.searchParams.set("lang", language);
    anchor.href = url.toString();
  });
}

function applyUiCopy(language) {
  const copy = resolveUiCopy(language);
  const panelLanguage = resolvePanelLanguage(language);

  document.querySelectorAll("[data-copy-key]").forEach((node) => {
    const key = node.getAttribute("data-copy-key");
    if (copy[key]) {
      node.textContent = copy[key];
    }
  });

  const title =
    document.body.getAttribute(`data-title-${language}`) ||
    document.body.getAttribute(`data-title-${panelLanguage}`) ||
    document.body.getAttribute("data-title-en");
  if (title) {
    document.title = title;
  }

  const langCode = htmlLangCodes[language] || htmlLangCodes[panelLanguage] || "en";

  document.documentElement.lang = langCode;
  document.documentElement.dir = rtlLanguages.has(panelLanguage) ? "rtl" : "ltr";
  document.body.setAttribute("data-current-language", panelLanguage);

  const switcher = document.querySelector("[data-language-switcher]");
  if (switcher) {
    switcher.setAttribute("aria-label", copy.languageLabel);
  }
}

function buildLanguageUrl(language) {
  const url = new URL(window.location.href);
  url.searchParams.set("lang", language);
  return url;
}

function setLanguage(language, options = {}) {
  const { shouldReload = false } = options;
  const resolved = supportedLanguages.includes(language) ? language : "en";
  const panelLanguage = resolvePanelLanguage(resolved);
  localStorage.setItem("stackshot-site-language", resolved);

  const url = buildLanguageUrl(resolved);

  if (shouldReload) {
    window.location.assign(url.toString());
    return;
  }

  document.querySelectorAll("[data-lang-panel]").forEach((panel) => {
    const isActive = panel.getAttribute("data-lang-panel") === panelLanguage;
    panel.classList.toggle("is-active", isActive);
    panel.hidden = !isActive;
  });

  document.querySelectorAll("[data-set-lang]").forEach((button) => {
    const buttonLanguage = button.getAttribute("data-set-lang");
    const isActive = buttonLanguage === resolved || buttonLanguage === panelLanguage;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-pressed", isActive ? "true" : "false");
  });

  const select = document.querySelector("[data-language-select]");
  if (select) {
    select.value = resolved;
  }

  applyUiCopy(resolved);
  updateLanguageLinks(resolved);
  window.history.replaceState({}, "", url.toString());
}

function chooseInitialLanguage() {
  const params = new URLSearchParams(window.location.search);
  const paramLanguage = params.get("lang");
  if (supportedLanguages.includes(paramLanguage)) {
    return paramLanguage;
  }

  const remembered = localStorage.getItem("stackshot-site-language");
  if (supportedLanguages.includes(remembered)) {
    return remembered;
  }

  return normalizeLanguage(navigator.language);
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-set-lang]").forEach((button) => {
    button.addEventListener("click", () => {
      setLanguage(button.getAttribute("data-set-lang"), { shouldReload: true });
    });
  });

  const select = document.querySelector("[data-language-select]");
  if (select) {
    select.addEventListener("change", (event) => {
      setLanguage(event.target.value, { shouldReload: true });
    });
  }

  setLanguage(chooseInitialLanguage());
});
