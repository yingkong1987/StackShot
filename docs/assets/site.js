const supportedLanguages = [
  "zh-Hans", "zh-Hant", "en", "en-US", "en-GB", "en-AU", "en-CA", "ja",
  "ar", "bn", "ca", "hr", "cs", "da", "nl", "fi", "fr", "fr-CA", "de", "el",
  "gu", "he", "hi", "hu", "id", "it", "kn", "ko", "ms", "mr", "no", "or", "pl",
  "pt-BR", "pt-PT", "pa", "ro", "ru", "sk", "sl", "es-MX", "es-ES", "sv", "th",
  "tr", "uk", "ur", "vi"
];

const languagePanelMap = {
  "zh-Hans": "zh-Hans",
  "zh-Hant": "zh-Hant",
  en: "en",
  "en-US": "en",
  "en-GB": "en",
  "en-AU": "en",
  "en-CA": "en",
  ja: "ja",
  ar: "en",
  bn: "en",
  ca: "en",
  hr: "en",
  cs: "en",
  da: "en",
  nl: "en",
  fi: "en",
  fr: "en",
  "fr-CA": "en",
  de: "en",
  el: "en",
  gu: "en",
  he: "en",
  hi: "en",
  hu: "en",
  id: "en",
  it: "en",
  kn: "en",
  ko: "en",
  ms: "en",
  mr: "en",
  no: "en",
  or: "en",
  pl: "en",
  "pt-BR": "en",
  "pt-PT": "en",
  pa: "en",
  ro: "en",
  ru: "en",
  sk: "en",
  sl: "en",
  "es-MX": "en",
  "es-ES": "en",
  sv: "en",
  th: "en",
  tr: "en",
  uk: "en",
  ur: "en",
  vi: "en"
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
  ja: {
    home: "ホーム",
    privacy: "プライバシー",
    support: "サポート",
    footer: "StackShot はキャプチャ、注釈、OCR をひとつにまとめた macOS 向けローカル優先ツールです。",
    languageLabel: "言語を切り替える"
  },
  fr: {
    home: "Accueil",
    privacy: "Confidentialite",
    support: "Support",
    footer: "StackShot est un outil macOS local-first pour la capture, l'annotation et les workflows OCR.",
    languageLabel: "Changer de langue"
  },
  de: {
    home: "Start",
    privacy: "Datenschutz",
    support: "Support",
    footer: "StackShot ist ein lokales macOS-Screenshot-Tool fur Aufnahme, Annotation und OCR-Workflows.",
    languageLabel: "Sprache wechseln"
  },
  "es-ES": {
    home: "Inicio",
    privacy: "Privacidad",
    support: "Soporte",
    footer: "StackShot es una herramienta de capturas para macOS local-first con flujo de captura, anotacion y OCR.",
    languageLabel: "Cambiar idioma"
  },
  "pt-BR": {
    home: "Inicio",
    privacy: "Privacidade",
    support: "Suporte",
    footer: "StackShot e uma ferramenta macOS local-first para captura de tela, anotacao e OCR.",
    languageLabel: "Trocar idioma"
  },
  ru: {
    home: "Glavnaya",
    privacy: "Konfidentsialnost",
    support: "Podderzhka",
    footer: "StackShot - lokalnyi instrument macOS dlya snimkov ekrana, annotatsii i OCR.",
    languageLabel: "Smenit yazyk"
  },
  ko: {
    home: "Home",
    privacy: "Privacy",
    support: "Support",
    footer: "StackShot is a local-first macOS screenshot tool for capture, annotation, and OCR workflows.",
    languageLabel: "Switch language"
  },
  ar: {
    home: "Home",
    privacy: "Privacy",
    support: "Support",
    footer: "StackShot is a local-first macOS screenshot tool for capture, annotation, and OCR workflows.",
    languageLabel: "Switch language"
  }
};

const htmlLangCodes = {
  "zh-Hans": "zh-CN",
  "zh-Hant": "zh-TW",
  en: "en",
  "en-US": "en-US",
  "en-GB": "en-GB",
  "en-AU": "en-AU",
  "en-CA": "en-CA",
  ja: "ja",
  ar: "ar",
  fr: "fr",
  de: "de",
  "es-ES": "es",
  "es-MX": "es-MX",
  "pt-BR": "pt-BR",
  "pt-PT": "pt-PT",
  ru: "ru",
  ko: "ko"
};

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

  if (value.startsWith("ja")) {
    return "ja";
  }

  if (value.startsWith("ko")) {
    return "ko";
  }

  if (value.startsWith("fr")) {
    return "fr";
  }

  if (value.startsWith("de")) {
    return "de";
  }

  if (value.startsWith("ru")) {
    return "ru";
  }

  if (value.startsWith("ar")) {
    return "ar";
  }

  if (value.startsWith("pt-br")) {
    return "pt-BR";
  }

  if (value.startsWith("pt")) {
    return "pt-PT";
  }

  if (value.startsWith("es-mx")) {
    return "es-MX";
  }

  if (value.startsWith("es")) {
    return "es-ES";
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

  const switcher = document.querySelector("[data-language-switcher]");
  if (switcher) {
    switcher.setAttribute("aria-label", copy.languageLabel);
  }
}

function setLanguage(language) {
  const resolved = supportedLanguages.includes(language) ? language : "en";
  const panelLanguage = resolvePanelLanguage(resolved);
  localStorage.setItem("stackshot-site-language", resolved);

  document.querySelectorAll("[data-lang-panel]").forEach((panel) => {
    const isActive = panel.getAttribute("data-lang-panel") === panelLanguage;
    panel.classList.toggle("is-active", isActive);
    panel.hidden = !isActive;
  });

  document.querySelectorAll("[data-set-lang]").forEach((button) => {
    const isActive = button.getAttribute("data-set-lang") === resolved;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-pressed", isActive ? "true" : "false");
  });

  const select = document.querySelector("[data-language-select]");
  if (select) {
    select.value = resolved;
  }

  applyUiCopy(resolved);
  updateLanguageLinks(resolved);

  const url = new URL(window.location.href);
  url.searchParams.set("lang", resolved);
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
      setLanguage(button.getAttribute("data-set-lang"));
    });
  });

  const select = document.querySelector("[data-language-select]");
  if (select) {
    select.addEventListener("change", (event) => {
      setLanguage(event.target.value);
    });
  }

  setLanguage(chooseInitialLanguage());
});