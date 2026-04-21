const supportedLanguages = ["zh-Hans", "zh-Hant", "en", "ja"];

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
  }
};

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
  const copy = uiCopy[language];

  document.querySelectorAll("[data-copy-key]").forEach((node) => {
    const key = node.getAttribute("data-copy-key");
    if (copy[key]) {
      node.textContent = copy[key];
    }
  });

  const title = document.body.getAttribute(`data-title-${language}`);
  if (title) {
    document.title = title;
  }

  const langCode = {
    "zh-Hans": "zh-CN",
    "zh-Hant": "zh-TW",
    en: "en",
    ja: "ja"
  }[language];

  document.documentElement.lang = langCode;

  const switcher = document.querySelector("[data-language-switcher]");
  if (switcher) {
    switcher.setAttribute("aria-label", copy.languageLabel);
  }
}

function setLanguage(language) {
  const resolved = supportedLanguages.includes(language) ? language : "en";
  localStorage.setItem("stackshot-site-language", resolved);

  document.querySelectorAll("[data-lang-panel]").forEach((panel) => {
    const isActive = panel.getAttribute("data-lang-panel") === resolved;
    panel.classList.toggle("is-active", isActive);
    panel.hidden = !isActive;
  });

  document.querySelectorAll("[data-set-lang]").forEach((button) => {
    const isActive = button.getAttribute("data-set-lang") === resolved;
    button.classList.toggle("is-active", isActive);
    button.setAttribute("aria-pressed", isActive ? "true" : "false");
  });

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

  setLanguage(chooseInitialLanguage());
});