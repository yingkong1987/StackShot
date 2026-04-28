/* ═══════════════════════════════════════════════════════════════
   StackShot  ·  i18n + Language Dropdown  ·  2026
   Global TOP 15 languages
   ═══════════════════════════════════════════════════════════════ */

/* ── Language metadata ─────────────────────────────────────── */
const LANGUAGES = [
  { code: "en",      label: "English",            native: "English" },
  { code: "zh-Hans", label: "Simplified Chinese",  native: "简体中文" },
  { code: "zh-Hant", label: "Traditional Chinese", native: "繁體中文" },
  { code: "es-ES",   label: "Spanish",             native: "Español" },
  { code: "hi",      label: "Hindi",               native: "हिन्दी" },
  { code: "ar",      label: "Arabic",              native: "العربية" },
  { code: "pt-BR",   label: "Portuguese",          native: "Português" },
  { code: "fr",      label: "French",              native: "Français" },
  { code: "ru",      label: "Russian",             native: "Русский" },
  { code: "de",      label: "German",              native: "Deutsch" },
  { code: "ja",      label: "Japanese",            native: "日本語" },
  { code: "ko",      label: "Korean",              native: "한국어" },
  { code: "id",      label: "Indonesian",          native: "Bahasa Indonesia" },
  { code: "it",      label: "Italian",             native: "Italiano" },
  { code: "nl",      label: "Dutch",               native: "Nederlands" }
];

const SUPPORTED_CODES = LANGUAGES.map(l => l.code);

/* Maps browser locale → panel code */
const languagePanelMap = {
  en: "en", "en-US": "en", "en-GB": "en", "en-AU": "en", "en-CA": "en",
  "zh-Hans": "zh-Hans", "zh-CN": "zh-Hans",
  "zh-Hant": "zh-Hant", "zh-TW": "zh-Hant", "zh-HK": "zh-Hant",
  "es-ES": "es-ES", "es-MX": "es-ES", "es-AR": "es-ES", "es-CO": "es-ES",
  hi: "hi",
  ar: "ar",
  "pt-BR": "pt-BR", "pt-PT": "pt-BR",
  fr: "fr", "fr-CA": "fr", "fr-BE": "fr",
  ru: "ru",
  de: "de", "de-AT": "de", "de-CH": "de",
  ja: "ja",
  ko: "ko",
  id: "id",
  it: "it",
  nl: "nl", "nl-BE": "nl"
};

/* html lang attr */
const htmlLangCodes = {
  en: "en", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
  "es-ES": "es", hi: "hi", ar: "ar", "pt-BR": "pt-BR",
  fr: "fr", ru: "ru", de: "de", ja: "ja", ko: "ko",
  id: "id", it: "it", nl: "nl"
};

const rtlLanguages = new Set(["ar", "hi"]);

/* ── UI copy (nav labels & footer) ─────────────────────────── */
const uiCopy = {
  "zh-Hans": { home: "主页", privacy: "隐私政策", support: "支持",
    footer: "StackShot 是一款面向 macOS 的本地优先截图工具，覆盖捕获、标注与 OCR 工作流。",
    langLabel: "语言" },
  "zh-Hant": { home: "首頁", privacy: "隱私政策", support: "支援",
    footer: "StackShot 是一款面向 macOS 的本機優先截圖工具，涵蓋擷取、標註與 OCR 工作流。",
    langLabel: "語言" },
  en: { home: "Home", privacy: "Privacy", support: "Support",
    footer: "StackShot is a local-first macOS screenshot tool for capture, annotation, and OCR workflows.",
    langLabel: "Language" },
  "es-ES": { home: "Inicio", privacy: "Privacidad", support: "Soporte",
    footer: "StackShot es una herramienta de capturas para macOS centrada en el procesamiento local.",
    langLabel: "Idioma" },
  hi: { home: "मुख्य पृष्ठ", privacy: "गोपनीयता", support: "सहायता",
    footer: "StackShot macOS के लिए एक लोकल-फर्स्ट स्क्रीनशॉट टूल है।",
    langLabel: "भाषा" },
  ar: { home: "الرئيسية", privacy: "الخصوصية", support: "الدعم",
    footer: "StackShot أداة لقطات شاشة محلية أولًا على macOS.",
    langLabel: "اللغة" },
  "pt-BR": { home: "Início", privacy: "Privacidade", support: "Suporte",
    footer: "StackShot é uma ferramenta de captura de tela para macOS com abordagem local-first.",
    langLabel: "Idioma" },
  fr: { home: "Accueil", privacy: "Confidentialité", support: "Assistance",
    footer: "StackShot est un outil de capture d'écran macOS orienté local.",
    langLabel: "Langue" },
  ru: { home: "Главная", privacy: "Конфиденциальность", support: "Поддержка",
    footer: "StackShot — локальный инструмент macOS для снимков экрана и OCR.",
    langLabel: "Язык" },
  de: { home: "Startseite", privacy: "Datenschutz", support: "Support",
    footer: "StackShot ist ein lokal orientiertes macOS-Screenshot-Tool.",
    langLabel: "Sprache" },
  ja: { home: "ホーム", privacy: "プライバシー", support: "サポート",
    footer: "StackShot はキャプチャ、注釈、OCR をひとつにまとめた macOS 向けローカル優先ツールです。",
    langLabel: "言語" },
  ko: { home: "홈", privacy: "개인정보", support: "지원",
    footer: "StackShot은 캡처, 주석, OCR 작업을 위한 로컬 우선 macOS 스크린샷 도구입니다.",
    langLabel: "언어" },
  id: { home: "Beranda", privacy: "Privasi", support: "Dukungan",
    footer: "StackShot adalah alat tangkapan layar macOS yang mengutamakan lokal.",
    langLabel: "Bahasa" },
  it: { home: "Home", privacy: "Privacy", support: "Supporto",
    footer: "StackShot è uno strumento screenshot per macOS con elaborazione locale.",
    langLabel: "Lingua" },
  nl: { home: "Home", privacy: "Privacybeleid", support: "Ondersteuning",
    footer: "StackShot is een lokaal-first screenshot-tool voor macOS.",
    langLabel: "Taal" }
};

/* ── Helper functions ──────────────────────────────────────── */
function resolvePanelLanguage(lang) {
  return languagePanelMap[lang] || "en";
}

function resolveUiCopy(lang) {
  return uiCopy[lang] || uiCopy[resolvePanelLanguage(lang)] || uiCopy.en;
}

function normalizeLanguage(raw) {
  const v = (raw || "").toLowerCase();

  if (v.startsWith("zh-hant") || v.startsWith("zh-tw") || v.startsWith("zh-hk") || v.startsWith("zh-mo"))
    return "zh-Hant";
  if (v.startsWith("zh")) return "zh-Hans";
  if (v.startsWith("es")) return "es-ES";
  if (v.startsWith("hi")) return "hi";
  if (v.startsWith("ar")) return "ar";
  if (v.startsWith("pt")) return "pt-BR";
  if (v.startsWith("fr")) return "fr";
  if (v.startsWith("ru")) return "ru";
  if (v.startsWith("de")) return "de";
  if (v.startsWith("ja")) return "ja";
  if (v.startsWith("ko")) return "ko";
  if (v.startsWith("id")) return "id";
  if (v.startsWith("it")) return "it";
  if (v.startsWith("nl")) return "nl";
  return "en";
}

function buildLanguageUrl(lang) {
  const url = new URL(window.location.href);
  url.searchParams.set("lang", lang);
  return url;
}

function updateLanguageLinks(lang) {
  document.querySelectorAll("[data-lang-link]").forEach(anchor => {
    const rawHref = anchor.getAttribute("data-raw-href") || anchor.getAttribute("href");
    if (!anchor.hasAttribute("data-raw-href")) {
      anchor.setAttribute("data-raw-href", rawHref);
    }
    const url = new URL(rawHref, window.location.href);
    url.searchParams.set("lang", lang);
    anchor.href = url.toString();
  });
}

function applyUiCopy(lang) {
  const copy = resolveUiCopy(lang);
  const panelLang = resolvePanelLanguage(lang);

  document.querySelectorAll("[data-copy-key]").forEach(node => {
    const key = node.getAttribute("data-copy-key");
    if (copy[key]) node.textContent = copy[key];
  });

  const title =
    document.body.getAttribute(`data-title-${lang}`) ||
    document.body.getAttribute(`data-title-${panelLang}`) ||
    document.body.getAttribute("data-title-en");
  if (title) document.title = title;

  const langCode = htmlLangCodes[lang] || htmlLangCodes[panelLang] || "en";
  document.documentElement.lang = langCode;
  document.documentElement.dir = rtlLanguages.has(panelLang) ? "rtl" : "ltr";
  document.body.setAttribute("data-current-language", panelLang);

  // Update dropdown trigger label
  const trigger = document.querySelector(".lang-trigger-label");
  if (trigger) {
    const meta = LANGUAGES.find(l => l.code === lang || l.code === panelLang);
    trigger.textContent = meta ? meta.native : "Language";
  }

  // Update active state in dropdown
  document.querySelectorAll(".lang-option").forEach(opt => {
    const isActive = opt.getAttribute("data-set-lang") === lang ||
                     opt.getAttribute("data-set-lang") === panelLang;
    opt.classList.toggle("active", isActive);
    opt.setAttribute("aria-selected", isActive ? "true" : "false");
  });
}

/* ── Core setLanguage ──────────────────────────────────────── */
function setLanguage(lang, options = {}) {
  const { shouldReload = false } = options;
  const resolved = SUPPORTED_CODES.includes(lang) ? lang : "en";
  const panelLang = resolvePanelLanguage(resolved);
  localStorage.setItem("stackshot-site-language", resolved);

  const url = buildLanguageUrl(resolved);

  if (shouldReload) {
    window.location.assign(url.toString());
    return;
  }

  document.querySelectorAll("[data-lang-panel]").forEach(panel => {
    const isActive = panel.getAttribute("data-lang-panel") === panelLang;
    panel.classList.toggle("is-active", isActive);
    panel.hidden = !isActive;
  });

  applyUiCopy(resolved);
  updateLanguageLinks(resolved);
  window.history.replaceState({}, "", url.toString());
}

/* ── Initial language detection ───────────────────────────── */
function chooseInitialLanguage() {
  // Prefer the inline-preloaded result (avoids re-parsing)
  const preloaded = document.documentElement.getAttribute("data-preload-lang");
  if (SUPPORTED_CODES.includes(preloaded)) return preloaded;

  const params = new URLSearchParams(window.location.search);
  const paramLang = params.get("lang");
  if (SUPPORTED_CODES.includes(paramLang)) return paramLang;

  const remembered = localStorage.getItem("stackshot-site-language");
  if (SUPPORTED_CODES.includes(remembered)) return remembered;

  // Try browser language preferences
  const langs = navigator.languages || [navigator.language || "en"];
  for (const l of langs) {
    const normalized = normalizeLanguage(l);
    if (SUPPORTED_CODES.includes(normalized)) return normalized;
  }

  return "en";
}

/* ── Build dropdown ────────────────────────────────────────── */
function buildDropdown() {
  const wrappers = document.querySelectorAll("[data-language-switcher]");
  if (!wrappers.length) return;

  wrappers.forEach(wrapper => {
    // Clear existing content (old button list)
    wrapper.innerHTML = "";
    wrapper.className = "lang-dropdown-wrap";
    wrapper.removeAttribute("role");
    wrapper.removeAttribute("aria-label");

    // Build trigger button
    const trigger = document.createElement("button");
    trigger.type = "button";
    trigger.className = "lang-trigger";
    trigger.setAttribute("aria-haspopup", "listbox");
    trigger.setAttribute("aria-expanded", "false");
    trigger.innerHTML = `
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <circle cx="7" cy="7" r="6" stroke="currentColor" stroke-width="1.2"/>
        <path d="M1 7h12M7 1c-1.5 2-2.5 3.8-2.5 6s1 4 2.5 6M7 1c1.5 2 2.5 3.8 2.5 6S8.5 11 7 13" stroke="currentColor" stroke-width="1.2"/>
      </svg>
      <span class="lang-trigger-label">Language</span>
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
        <path d="M2 3.5l3 3 3-3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>`;

    // Build menu
    const menu = document.createElement("div");
    menu.className = "lang-menu";
    menu.setAttribute("role", "listbox");

    LANGUAGES.forEach(lang => {
      const opt = document.createElement("button");
      opt.type = "button";
      opt.className = "lang-option";
      opt.setAttribute("role", "option");
      opt.setAttribute("aria-selected", "false");
      opt.setAttribute("data-set-lang", lang.code);
      opt.innerHTML = `
        <span>${lang.native}</span>
        <span class="lang-native">${lang.label}</span>`;
      opt.addEventListener("click", () => {
        setLanguage(lang.code, { shouldReload: true });
        closeMenu();
      });
      menu.appendChild(opt);
    });

    wrapper.appendChild(trigger);
    wrapper.appendChild(menu);

    // Toggle open/close
    let isOpen = false;

    function openMenu() {
      isOpen = true;
      menu.classList.add("open");
      trigger.classList.add("open");
      trigger.setAttribute("aria-expanded", "true");
    }

    function closeMenu() {
      isOpen = false;
      menu.classList.remove("open");
      trigger.classList.remove("open");
      trigger.setAttribute("aria-expanded", "false");
    }

    trigger.addEventListener("click", e => {
      e.stopPropagation();
      isOpen ? closeMenu() : openMenu();
    });

    // Close on outside click
    document.addEventListener("click", e => {
      if (!wrapper.contains(e.target)) closeMenu();
    });

    // Close on Escape
    document.addEventListener("keydown", e => {
      if (e.key === "Escape") closeMenu();
    });
  });
}

/* ── Scroll reveal ─────────────────────────────────────────── */
function initScrollReveal() {
  const targets = document.querySelectorAll(
    ".feature-panel, .workflow-step, .trust-card, .resource-card, " +
    ".stat-card, .support-card, .faq-card, .policy-block"
  );
  targets.forEach((el, i) => {
    el.classList.add("reveal");
    el.style.transitionDelay = `${(i % 6) * 0.06}s`;
  });

  const observer = new IntersectionObserver(
    entries => entries.forEach(e => {
      if (e.isIntersecting) {
        e.target.classList.add("visible");
        observer.unobserve(e.target);
      }
    }),
    { threshold: 0.1 }
  );

  targets.forEach(el => observer.observe(el));
}

/* ── Canvas particle effect (hero background) ──────────────── */
function initParticles() {
  const hero = document.querySelector(".hero");
  if (!hero) return;

  const canvas = document.createElement("canvas");
  canvas.style.cssText = "position:absolute;inset:0;pointer-events:none;opacity:.35;";
  canvas.style.borderRadius = "inherit";
  hero.style.position = "relative";
  hero.style.overflow = "hidden";
  hero.insertBefore(canvas, hero.firstChild);

  const ctx = canvas.getContext("2d");
  let W, H, particles;

  function resize() {
    W = canvas.width = hero.offsetWidth;
    H = canvas.height = hero.offsetHeight;
  }

  function createParticles() {
    const count = Math.min(60, Math.floor(W * H / 14000));
    return Array.from({ length: count }, () => ({
      x: Math.random() * W,
      y: Math.random() * H,
      r: Math.random() * 1.8 + 0.4,
      vx: (Math.random() - 0.5) * 0.3,
      vy: (Math.random() - 0.5) * 0.3,
      opacity: Math.random() * 0.5 + 0.2
    }));
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);
    particles.forEach(p => {
      ctx.beginPath();
      ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(0, 212, 255, ${p.opacity})`;
      ctx.fill();

      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0) p.x = W;
      if (p.x > W) p.x = 0;
      if (p.y < 0) p.y = H;
      if (p.y > H) p.y = 0;
    });

    // Draw connecting lines
    for (let i = 0; i < particles.length; i++) {
      for (let j = i + 1; j < particles.length; j++) {
        const dx = particles[i].x - particles[j].x;
        const dy = particles[i].y - particles[j].y;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < 100) {
          ctx.beginPath();
          ctx.moveTo(particles[i].x, particles[i].y);
          ctx.lineTo(particles[j].x, particles[j].y);
          ctx.strokeStyle = `rgba(0, 212, 255, ${0.08 * (1 - dist / 100)})`;
          ctx.lineWidth = 0.5;
          ctx.stroke();
        }
      }
    }

    requestAnimationFrame(draw);
  }

  resize();
  particles = createParticles();
  draw();

  window.addEventListener("resize", () => {
    resize();
    particles = createParticles();
  });
}

/* ── Boot ──────────────────────────────────────────────────── */
document.addEventListener("DOMContentLoaded", () => {
  buildDropdown();
  setLanguage(chooseInitialLanguage());
  initScrollReveal();
  initParticles();
});
