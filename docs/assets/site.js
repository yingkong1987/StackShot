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

const rtlLanguages = new Set(["ar"]);

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

/* ── Product update copy (StackShot 1.5) ───────────────────── */
const releaseCopy = {
  "zh-Hans": {
    releaseTitle: "截一次，让信息继续流动。",
    releaseIntro: "最近几轮更新把截图变成了真正的工作台：提取二维码、置顶参考、保留 HDR 细节，也让长截图和导出更稳定。",
    cards: [
      ["二维码，截完就能用", "自动识别截图里的二维码，裁出清晰码图，并可复制内容；网址还能直接打开。"],
      ["长页面，收进一张图", "重构后的滚动拼接流程让网页、文档和聊天记录保持连续，减少断层与重复。"],
      ["参考图，始终在眼前", "把任意截图置顶悬浮，边写、边对照、边整理，不必来回切换窗口。"],
      ["颜色更真，标注更准", "兼容设备上支持 HDR 捕获，并新增局部高亮、多格式导出与更稳定的编辑窗口。"]
    ],
    localBadge: "二维码识别在本机完成",
    detected: "已识别二维码",
    actions: "复制内容  ·  打开链接",
    supportTitle: "二维码没有被识别？",
    supportBody: "请尽量让二维码完整、清晰地出现在截图中。StackShot 会在本机识别并裁出二维码；识别成功后可复制内容、复制码图、保存图片，网址也可直接打开。",
    privacyTitle: "二维码提取",
    privacyBody: "二维码检测、解码与裁切都在当前 Mac 上完成。只有当你主动选择复制、保存或打开链接时，结果才会写入剪贴板、磁盘或交给默认浏览器。"
  },
  "zh-Hant": {
    releaseTitle: "擷取一次，讓資訊繼續流動。",
    releaseIntro: "近期更新把截圖變成真正的工作台：提取 QR Code、釘選參考、保留 HDR 細節，也讓捲動截圖與匯出更穩定。",
    cards: [
      ["QR Code，截完就能用", "自動辨識截圖中的 QR Code、裁出清晰碼圖並複製內容；網址也可直接開啟。"],
      ["長頁面，收進一張圖", "重構後的捲動拼接流程讓網頁、文件與聊天記錄保持連續，減少斷層與重複。"],
      ["參考圖，始終在眼前", "把任意截圖釘選浮動，邊寫、邊比對、邊整理，不必反覆切換視窗。"],
      ["色彩更真，標註更準", "相容裝置支援 HDR 擷取，並加入局部高亮、多格式匯出與更穩定的編輯視窗。"]
    ],
    localBadge: "QR Code 辨識在本機完成",
    detected: "已辨識 QR Code",
    actions: "複製內容  ·  開啟連結",
    supportTitle: "無法辨識 QR Code？",
    supportBody: "請讓 QR Code 完整、清晰地出現在截圖中。StackShot 會在本機辨識並裁出碼圖；成功後可複製內容、複製碼圖、儲存圖片，網址也能直接開啟。",
    privacyTitle: "QR Code 提取",
    privacyBody: "QR Code 的偵測、解碼與裁切都在目前這台 Mac 上完成。只有當你主動選擇複製、儲存或開啟連結時，結果才會寫入剪貼簿、磁碟或交給預設瀏覽器。"
  },
  en: {
    releaseTitle: "Capture once. Keep everything moving.",
    releaseIntro: "Recent updates turn a screenshot into a working surface: extract QR links, pin references, preserve HDR detail, and move through long captures and export with less friction.",
    cards: [
      ["QR codes, ready to use", "Detect a QR code inside a capture, isolate a clean code image, copy its content, or open a web link directly."],
      ["Long pages, one clean image", "A rebuilt scrolling-stitching flow keeps web pages, documents, and conversations continuous with fewer seams."],
      ["Keep references in view", "Pin any capture above your work while you write, compare, rebuild, or collect details from it."],
      ["More faithful, more precise", "HDR-aware capture on compatible Macs, local highlight, multi-format export, and steadier editing windows."]
    ],
    localBadge: "QR recognition stays on-device",
    detected: "QR code detected",
    actions: "Copy content  ·  Open link",
    supportTitle: "QR code not detected?",
    supportBody: "Keep the full code sharp and visible in the capture. StackShot detects and crops it on-device; once recognized, you can copy the content or code image, save it, or open web links directly.",
    privacyTitle: "QR code extraction",
    privacyBody: "QR detection, decoding, and cropping happen on the current Mac. Results reach the clipboard, disk, or default browser only when you explicitly choose Copy, Save, or Open Link."
  },
  ja: {
    releaseTitle: "一度のキャプチャから、次の作業へ。",
    releaseIntro: "最近のアップデートで、QR コード抽出、参照画像のピン留め、HDR の保持、より安定したスクロールキャプチャと書き出しに対応しました。",
    cards: [
      ["QR コードを、その場で活用", "キャプチャ内の QR コードを検出してきれいに切り出し、内容のコピーや Web リンクの直接表示ができます。"],
      ["長いページを一枚に", "再構築したスクロール合成により、Web ページ、書類、会話を継ぎ目の少ない一枚にまとめます。"],
      ["参照画像を常に手前に", "キャプチャをピン留めして、文章作成や比較、確認をしながら手元に置いておけます。"],
      ["より忠実で、より精密に", "対応 Mac での HDR キャプチャ、部分ハイライト、複数形式の書き出し、安定した編集画面を追加しました。"]
    ],
    localBadge: "QR 認識はデバイス上で完結",
    detected: "QR コードを検出",
    actions: "内容をコピー  ·  リンクを開く",
    supportTitle: "QR コードを検出できない場合",
    supportBody: "QR コード全体が鮮明に見える状態でキャプチャしてください。認識と切り出しはデバイス上で行われ、内容や画像のコピー、保存、Web リンクの表示ができます。",
    privacyTitle: "QR コード抽出",
    privacyBody: "QR コードの検出、デコード、切り出しは現在の Mac 上で完結します。コピー、保存、リンクを開く操作を明示的に選んだ場合にのみ、結果がクリップボード、ディスク、または既定のブラウザへ渡されます。"
  },
  ko: {
    releaseTitle: "한 번 캡처하고, 흐름을 계속 이어가세요.",
    releaseIntro: "최근 업데이트로 QR 코드 추출, 참조 이미지 고정, HDR 디테일 유지, 더 안정적인 스크롤 캡처와 내보내기를 지원합니다.",
    cards: [
      ["QR 코드를 바로 활용", "캡처 속 QR 코드를 감지해 깔끔하게 잘라내고, 내용을 복사하거나 웹 링크를 바로 열 수 있습니다."],
      ["긴 페이지를 한 장에", "새로 다듬은 스크롤 스티칭이 웹 페이지, 문서, 대화를 끊김이 적은 한 장으로 연결합니다."],
      ["참조 이미지를 항상 위에", "캡처를 고정해 글쓰기, 비교, 확인 중에도 작업 위에 띄워 둘 수 있습니다."],
      ["더 정확한 색과 편집", "호환 Mac의 HDR 캡처, 부분 강조, 다양한 형식 내보내기와 안정적인 편집 창을 지원합니다."]
    ],
    localBadge: "QR 인식은 기기에서 처리",
    detected: "QR 코드 감지됨",
    actions: "내용 복사  ·  링크 열기",
    supportTitle: "QR 코드가 감지되지 않나요?",
    supportBody: "코드 전체가 선명하게 보이도록 캡처하세요. StackShot은 기기에서 코드를 감지하고 잘라내며, 인식 후 내용이나 코드 이미지를 복사하고 저장하거나 웹 링크를 열 수 있습니다.",
    privacyTitle: "QR 코드 추출",
    privacyBody: "QR 감지, 디코딩, 자르기는 현재 Mac에서 처리됩니다. 사용자가 복사, 저장 또는 링크 열기를 직접 선택한 경우에만 결과가 클립보드, 디스크 또는 기본 브라우저로 전달됩니다."
  },
  "es-ES": {
    releaseTitle: "Captura una vez. Sigue trabajando.",
    releaseIntro: "Las últimas mejoras convierten cada captura en una superficie de trabajo: extrae códigos QR, fija referencias, conserva detalle HDR y crea capturas largas con más estabilidad.",
    cards: [
      ["Códigos QR listos para usar", "Detecta un código QR, recorta una imagen limpia, copia su contenido o abre directamente un enlace web."],
      ["Páginas largas en una imagen", "El flujo de unión renovado mantiene páginas web, documentos y conversaciones continuos y con menos cortes."],
      ["Referencias siempre visibles", "Fija cualquier captura sobre tu trabajo mientras escribes, comparas o consultas sus detalles."],
      ["Más fidelidad y precisión", "Captura HDR en Mac compatibles, resaltado local, exportación multiformato y ventanas de edición más estables."]
    ],
    localBadge: "El reconocimiento QR ocurre en el dispositivo",
    detected: "Código QR detectado",
    actions: "Copiar contenido  ·  Abrir enlace",
    supportTitle: "¿No se detecta el código QR?",
    supportBody: "Procura que el código completo aparezca nítido en la captura. StackShot lo detecta y recorta en el dispositivo; después puedes copiar contenido o imagen, guardarlo o abrir enlaces web.",
    privacyTitle: "Extracción de códigos QR",
    privacyBody: "La detección, decodificación y el recorte se realizan en el Mac actual. El resultado solo pasa al portapapeles, disco o navegador cuando eliges Copiar, Guardar o Abrir enlace."
  },
  de: {
    releaseTitle: "Einmal aufnehmen. Direkt weiterarbeiten.",
    releaseIntro: "Die neuesten Updates machen Screenshots zur Arbeitsfläche: QR-Codes extrahieren, Referenzen anheften, HDR-Details erhalten und lange Inhalte stabiler erfassen.",
    cards: [
      ["QR-Codes sofort verwenden", "Erkennt einen QR-Code im Screenshot, schneidet ihn sauber aus, kopiert den Inhalt oder öffnet Weblinks direkt."],
      ["Lange Seiten in einem Bild", "Der überarbeitete Stitching-Ablauf verbindet Webseiten, Dokumente und Chats mit weniger Übergängen."],
      ["Referenzen immer im Blick", "Hefte jeden Screenshot über deiner Arbeit an, während du schreibst, vergleichst oder Details übernimmst."],
      ["Mehr Treue und Präzision", "HDR-Aufnahme auf kompatiblen Macs, lokales Hervorheben, Export in mehrere Formate und stabilere Editorfenster."]
    ],
    localBadge: "QR-Erkennung bleibt auf dem Gerät",
    detected: "QR-Code erkannt",
    actions: "Inhalt kopieren  ·  Link öffnen",
    supportTitle: "QR-Code wird nicht erkannt?",
    supportBody: "Der vollständige Code sollte scharf und sichtbar sein. StackShot erkennt und beschneidet ihn lokal; danach kannst du Inhalt oder Bild kopieren, speichern oder Weblinks öffnen.",
    privacyTitle: "QR-Code-Extraktion",
    privacyBody: "Erkennung, Decodierung und Zuschnitt erfolgen auf dem aktuellen Mac. Nur bei einer ausdrücklichen Aktion werden Ergebnisse in Zwischenablage, Datei oder Standardbrowser übergeben."
  },
  fr: {
    releaseTitle: "Une capture, puis tout continue.",
    releaseIntro: "Les dernières mises à jour transforment la capture en espace de travail : extraction de QR code, référence épinglée, détail HDR et captures défilantes plus stables.",
    cards: [
      ["Des QR codes prêts à servir", "Détectez un QR code, isolez une image nette, copiez son contenu ou ouvrez directement un lien web."],
      ["Les longues pages en une image", "Le nouvel assemblage relie pages web, documents et conversations avec moins de ruptures."],
      ["Gardez vos références visibles", "Épinglez une capture au-dessus de votre travail pendant que vous écrivez, comparez ou consultez ses détails."],
      ["Plus fidèle, plus précis", "Capture HDR sur les Mac compatibles, surbrillance locale, export multiformat et fenêtres d’édition plus stables."]
    ],
    localBadge: "La reconnaissance QR reste sur l’appareil",
    detected: "QR code détecté",
    actions: "Copier le contenu  ·  Ouvrir le lien",
    supportTitle: "QR code non détecté ?",
    supportBody: "Veillez à ce que le code soit entier, net et visible. StackShot le détecte et le recadre sur l’appareil, puis permet de copier le contenu ou l’image, d’enregistrer ou d’ouvrir un lien.",
    privacyTitle: "Extraction de QR code",
    privacyBody: "La détection, le décodage et le recadrage ont lieu sur le Mac actuel. Le résultat n’est transmis au presse-papiers, au disque ou au navigateur qu’après une action explicite."
  },
  "pt-BR": {
    releaseTitle: "Capture uma vez. Continue o trabalho.",
    releaseIntro: "As melhorias recentes transformam a captura em área de trabalho: extraia QR Codes, fixe referências, preserve detalhes HDR e produza capturas longas com mais estabilidade.",
    cards: [
      ["QR Codes prontos para usar", "Detecte um QR Code, recorte uma imagem limpa, copie o conteúdo ou abra links da web diretamente."],
      ["Páginas longas em uma imagem", "O fluxo de junção renovado mantém páginas, documentos e conversas contínuos e com menos emendas."],
      ["Referências sempre visíveis", "Fixe qualquer captura sobre o trabalho enquanto escreve, compara ou consulta detalhes."],
      ["Mais fidelidade e precisão", "Captura HDR em Macs compatíveis, destaque local, exportação em vários formatos e janelas mais estáveis."]
    ],
    localBadge: "Reconhecimento de QR no dispositivo",
    detected: "QR Code detectado",
    actions: "Copiar conteúdo  ·  Abrir link",
    supportTitle: "O QR Code não foi detectado?",
    supportBody: "Mantenha o código inteiro, nítido e visível. O StackShot detecta e recorta no dispositivo; depois você pode copiar conteúdo ou imagem, salvar ou abrir links.",
    privacyTitle: "Extração de QR Code",
    privacyBody: "Detecção, decodificação e recorte acontecem no Mac atual. O resultado só vai para a área de transferência, disco ou navegador quando você escolhe uma ação."
  },
  ru: {
    releaseTitle: "Один снимок — и работа продолжается.",
    releaseIntro: "Последние обновления превращают снимок в рабочую поверхность: извлечение QR-кодов, закрепление ссылок, детали HDR и более стабильные длинные снимки.",
    cards: [
      ["QR-коды сразу готовы", "Найдите QR-код на снимке, получите чистое изображение, скопируйте содержимое или сразу откройте ссылку."],
      ["Длинная страница одним кадром", "Обновлённая склейка соединяет сайты, документы и переписки с меньшим числом швов."],
      ["Ссылки всегда перед глазами", "Закрепите снимок поверх работы, пока пишете, сравниваете или переносите детали."],
      ["Точнее цвет и разметка", "HDR на совместимых Mac, локальная подсветка, экспорт в разные форматы и более стабильные окна редактора."]
    ],
    localBadge: "Распознавание QR выполняется на устройстве",
    detected: "QR-код распознан",
    actions: "Копировать  ·  Открыть ссылку",
    supportTitle: "QR-код не распознаётся?",
    supportBody: "Код должен быть полностью виден и оставаться чётким. StackShot распознаёт и обрезает его на устройстве, затем позволяет скопировать, сохранить или открыть ссылку.",
    privacyTitle: "Извлечение QR-кодов",
    privacyBody: "Распознавание, декодирование и обрезка выполняются на текущем Mac. Результат передаётся в буфер, файл или браузер только по вашему явному действию."
  },
  ar: {
    releaseTitle: "التقط مرة واحدة، وواصل العمل.",
    releaseIntro: "تحوّل التحديثات الأخيرة اللقطة إلى مساحة عمل: استخراج رمز QR، تثبيت المراجع، الحفاظ على تفاصيل HDR، ولقطات تمرير أكثر ثباتًا.",
    cards: [
      ["رموز QR جاهزة للاستخدام", "اكتشف رمز QR داخل اللقطة، واقتص صورة واضحة، وانسخ المحتوى أو افتح رابط الويب مباشرة."],
      ["صفحات طويلة في صورة واحدة", "يجمع مسار الدمج الجديد صفحات الويب والمستندات والمحادثات مع فواصل أقل."],
      ["المراجع دائمًا أمامك", "ثبّت أي لقطة فوق عملك أثناء الكتابة أو المقارنة أو مراجعة التفاصيل."],
      ["دقة ووفاء أكبر", "التقاط HDR على أجهزة Mac المتوافقة، وإبراز موضعي، وتصدير بصيغ متعددة، ونوافذ تحرير أكثر ثباتًا."]
    ],
    localBadge: "يتم التعرف على QR على الجهاز",
    detected: "تم اكتشاف رمز QR",
    actions: "نسخ المحتوى  ·  فتح الرابط",
    supportTitle: "لم يتم اكتشاف رمز QR؟",
    supportBody: "اجعل الرمز كاملًا وواضحًا في اللقطة. يكتشفه StackShot ويقصه على الجهاز، ثم يمكنك نسخ المحتوى أو الصورة أو حفظها أو فتح الرابط.",
    privacyTitle: "استخراج رمز QR",
    privacyBody: "يتم الاكتشاف وفك الترميز والقص على جهاز Mac الحالي. لا تنتقل النتيجة إلى الحافظة أو القرص أو المتصفح إلا عند اختيارك إجراءً صريحًا."
  },
  hi: {
    releaseTitle: "एक बार कैप्चर करें, काम आगे बढ़ाते रहें।",
    releaseIntro: "नए अपडेट स्क्रीनशॉट को काम की सतह बनाते हैं: QR निकालें, संदर्भ पिन करें, HDR विवरण बचाएँ और लंबे कैप्चर अधिक स्थिरता से बनाएँ।",
    cards: [
      ["QR कोड तुरंत उपयोग करें", "कैप्चर में QR कोड पहचानें, साफ़ कोड इमेज काटें, सामग्री कॉपी करें या वेब लिंक सीधे खोलें।"],
      ["लंबा पेज, एक साफ़ इमेज", "नया स्क्रॉल स्टिचिंग वेब पेज, दस्तावेज़ और चैट को कम जोड़ के साथ एक तस्वीर में रखता है।"],
      ["संदर्भ हमेशा सामने", "लिखते, तुलना करते या विवरण देखते समय किसी कैप्चर को काम के ऊपर पिन रखें।"],
      ["अधिक सटीक रंग और संपादन", "संगत Mac पर HDR, लोकल हाइलाइट, कई फ़ॉर्मैट में एक्सपोर्ट और अधिक स्थिर एडिटर विंडो।"]
    ],
    localBadge: "QR पहचान डिवाइस पर होती है",
    detected: "QR कोड मिला",
    actions: "सामग्री कॉपी  ·  लिंक खोलें",
    supportTitle: "QR कोड नहीं मिला?",
    supportBody: "पूरा कोड साफ़ और दिखाई देने योग्य रखें। StackShot इसे डिवाइस पर पहचानकर काटता है; फिर सामग्री या इमेज कॉपी, सेव या लिंक खोल सकते हैं।",
    privacyTitle: "QR कोड निकालना",
    privacyBody: "QR पहचान, डिकोड और क्रॉप मौजूदा Mac पर होते हैं। परिणाम केवल आपके Copy, Save या Open Link चुनने पर क्लिपबोर्ड, डिस्क या ब्राउज़र तक जाता है।"
  },
  id: {
    releaseTitle: "Tangkap sekali. Lanjutkan pekerjaan.",
    releaseIntro: "Pembaruan terbaru menjadikan tangkapan sebagai ruang kerja: ekstrak QR, sematkan referensi, pertahankan detail HDR, dan buat tangkapan gulir lebih stabil.",
    cards: [
      ["Kode QR siap digunakan", "Deteksi QR dalam tangkapan, potong gambar kode yang bersih, salin isinya, atau buka tautan web langsung."],
      ["Halaman panjang, satu gambar", "Alur stitching baru menyatukan halaman web, dokumen, dan percakapan dengan lebih sedikit sambungan."],
      ["Referensi selalu terlihat", "Sematkan tangkapan di atas pekerjaan saat menulis, membandingkan, atau membaca detail."],
      ["Lebih setia dan presisi", "Tangkap HDR pada Mac kompatibel, sorotan lokal, ekspor multi-format, dan jendela editor yang lebih stabil."]
    ],
    localBadge: "Pengenalan QR diproses di perangkat",
    detected: "Kode QR terdeteksi",
    actions: "Salin isi  ·  Buka tautan",
    supportTitle: "Kode QR tidak terdeteksi?",
    supportBody: "Pastikan seluruh kode tajam dan terlihat. StackShot mendeteksi dan memotongnya di perangkat; setelah itu Anda dapat menyalin, menyimpan, atau membuka tautan.",
    privacyTitle: "Ekstraksi kode QR",
    privacyBody: "Deteksi, penguraian, dan pemotongan terjadi di Mac saat ini. Hasil hanya menuju clipboard, disk, atau browser setelah Anda memilih tindakan."
  },
  it: {
    releaseTitle: "Cattura una volta. Continua a lavorare.",
    releaseIntro: "Gli ultimi aggiornamenti trasformano lo screenshot in uno spazio di lavoro: estrai QR, fissa riferimenti, conserva dettagli HDR e crea catture scorrevoli più stabili.",
    cards: [
      ["QR Code pronti all’uso", "Rileva un QR Code, ritaglia un’immagine pulita, copia il contenuto o apri direttamente un link web."],
      ["Pagine lunghe in un’immagine", "Il nuovo flusso di unione mantiene continui siti, documenti e conversazioni con meno giunture."],
      ["Riferimenti sempre visibili", "Fissa una cattura sopra il lavoro mentre scrivi, confronti o consulti i dettagli."],
      ["Più fedele e preciso", "Cattura HDR sui Mac compatibili, evidenziazione locale, export multi-formato e finestre più stabili."]
    ],
    localBadge: "Il riconoscimento QR resta sul dispositivo",
    detected: "QR Code rilevato",
    actions: "Copia contenuto  ·  Apri link",
    supportTitle: "QR Code non rilevato?",
    supportBody: "Assicurati che il codice sia intero, nitido e visibile. StackShot lo rileva e ritaglia sul dispositivo; poi puoi copiare, salvare o aprire il link.",
    privacyTitle: "Estrazione QR Code",
    privacyBody: "Rilevamento, decodifica e ritaglio avvengono sul Mac corrente. Il risultato passa ad appunti, disco o browser solo dopo una scelta esplicita."
  },
  nl: {
    releaseTitle: "Eén keer vastleggen. Meteen verder.",
    releaseIntro: "De nieuwste updates maken van een screenshot een werkvlak: haal QR-codes eruit, pin referenties, behoud HDR-detail en maak stabielere scrollopnames.",
    cards: [
      ["QR-codes direct bruikbaar", "Detecteer een QR-code, snijd een schoon codebeeld uit, kopieer de inhoud of open een weblink meteen."],
      ["Lange pagina’s in één beeld", "De vernieuwde samenvoeging houdt websites, documenten en gesprekken doorlopend met minder naden."],
      ["Referenties altijd in beeld", "Pin een opname boven je werk terwijl je schrijft, vergelijkt of details overneemt."],
      ["Getrouwer en preciezer", "HDR-opname op compatibele Macs, lokale markering, export in meerdere formaten en stabielere vensters."]
    ],
    localBadge: "QR-herkenning gebeurt op het apparaat",
    detected: "QR-code gedetecteerd",
    actions: "Inhoud kopiëren  ·  Link openen",
    supportTitle: "QR-code niet gedetecteerd?",
    supportBody: "Zorg dat de volledige code scherp en zichtbaar is. StackShot herkent en snijdt hem lokaal uit; daarna kun je inhoud of beeld kopiëren, opslaan of een link openen.",
    privacyTitle: "QR-code-extractie",
    privacyBody: "Detectie, decodering en uitsnijden gebeuren op de huidige Mac. Alleen na een expliciete keuze gaat het resultaat naar klembord, schijf of browser."
  }
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

function getReleaseCopy(lang) {
  return releaseCopy[lang] || releaseCopy[resolvePanelLanguage(lang)] || releaseCopy.en;
}

function ensureBrandVersion() {
  document.querySelectorAll(".brand").forEach(brand => {
    if (brand.querySelector(".brand-version")) return;
    const version = document.createElement("span");
    version.className = "brand-version";
    version.textContent = "1.5";
    version.setAttribute("aria-label", "Version 1.5");
    brand.appendChild(version);
  });
}

function updateHeroForRelease(panel, copy) {
  const eyebrow = panel.querySelector(".hero .eyebrow");
  if (eyebrow && !eyebrow.querySelector(".version-chip")) {
    const chip = document.createElement("span");
    chip.className = "version-chip";
    chip.textContent = "1.5 · NEW";
    eyebrow.appendChild(chip);
  }

  const stats = panel.querySelectorAll(".hero-stats .stat-card");
  const statCards = [copy.cards[1], copy.cards[0], copy.cards[2]];
  const statLabels = ["SCROLL", "QR EXTRACT", "PIN"];
  stats.forEach((card, index) => {
    if (!statCards[index]) return;
    const label = card.querySelector(".stat-label");
    const title = card.querySelector("strong");
    const body = card.querySelector("p");
    if (label) label.textContent = statLabels[index];
    if (title) title.textContent = statCards[index][0];
    if (body) body.textContent = statCards[index][1];
  });
}

function enhanceProductStage(panel, copy) {
  const stage = panel.querySelector(".product-stage");
  if (!stage || stage.hasAttribute("data-release-enhanced")) return;
  stage.setAttribute("data-release-enhanced", "true");

  const status = stage.querySelector(".stage-status");
  if (status) status.textContent = "VERSION 1.5";

  const chips = stage.querySelectorAll(".stage-chip");
  ["Capture", "QR", "Pin"].forEach((text, index) => {
    if (chips[index]) chips[index].textContent = text;
  });

  const note = stage.querySelector(".stage-floating-note");
  if (note) {
    note.classList.add("qr-result-note");
    note.innerHTML =
      '<span class="mini-qr" aria-hidden="true"></span>' +
      '<span class="qr-result-copy"><strong>' + copy.detected + '</strong>' +
      '<p>' + copy.actions + '</p></span>';
  }

  const rail = document.createElement("div");
  rail.className = "stage-feature-rail";
  rail.setAttribute("aria-hidden", "true");
  rail.innerHTML = "<span>SCROLL</span><span>HDR</span><span>PIN</span>";
  stage.appendChild(rail);
}

function buildReleaseShowcase(panel, copy, lang) {
  if (panel.querySelector(".release-section")) return;
  const section = document.createElement("section");
  const headingId = "release-heading-" + lang.replace(/[^a-zA-Z0-9]/g, "-");
  section.className = "home-section release-section";
  section.setAttribute("aria-labelledby", headingId);
  section.innerHTML =
    '<div class="release-heading">' +
      '<div><p class="section-kicker">STACKSHOT 1.5 · WHAT’S NEW</p>' +
      '<h2 id="' + headingId + '">' + copy.releaseTitle + '</h2></div>' +
      '<p>' + copy.releaseIntro + '</p>' +
    '</div>' +
    '<div class="release-grid">' +
      '<article class="release-card release-card-qr">' +
        '<div class="release-card-copy"><span class="release-label">QR EXTRACTOR · NEW</span>' +
        '<h3>' + copy.cards[0][0] + '</h3><p>' + copy.cards[0][1] + '</p>' +
        '<span class="local-badge"><i></i>' + copy.localBadge + '</span></div>' +
        '<div class="qr-console" aria-hidden="true">' +
          '<div class="qr-symbol"><i class="qr-finder qr-finder-a"></i><i class="qr-finder qr-finder-b"></i><i class="qr-finder qr-finder-c"></i><i class="qr-pixels"></i></div>' +
          '<div class="qr-console-copy"><span><i></i>' + copy.detected + '</span><strong>https://stackshot.app</strong><small>' + copy.actions + '</small></div>' +
        '</div>' +
      '</article>' +
      '<article class="release-card release-card-scroll">' +
        '<span class="release-label">SCROLL CAPTURE</span><h3>' + copy.cards[1][0] + '</h3><p>' + copy.cards[1][1] + '</p>' +
        '<div class="scroll-demo" aria-hidden="true"><span class="scroll-page"><i></i><i></i><i></i><i></i><i></i></span><span class="scroll-rail"><i></i></span></div>' +
      '</article>' +
      '<article class="release-card release-card-pin">' +
        '<span class="release-label">PIN TO SCREEN</span><h3>' + copy.cards[2][0] + '</h3><p>' + copy.cards[2][1] + '</p>' +
        '<div class="pin-demo" aria-hidden="true"><span class="pin-window"><i></i><i></i><i></i></span><span class="pin-badge">⌖</span></div>' +
      '</article>' +
      '<article class="release-card release-card-quality">' +
        '<span class="release-label">IMAGE FIDELITY</span><h3>' + copy.cards[3][0] + '</h3><p>' + copy.cards[3][1] + '</p>' +
        '<div class="quality-tags" aria-label="HDR, HEIC, PNG, Local Highlight"><span>HDR</span><span>HEIC</span><span>PNG</span><span>LOCAL HIGHLIGHT</span></div>' +
      '</article>' +
    '</div>' +
    '<p class="release-platform">macOS 13+ <span>·</span> HDR capture &amp; in-app translation require compatible macOS 15 features.</p>';

  const hero = panel.querySelector(".hero");
  if (hero) hero.insertAdjacentElement("afterend", section);
}

function enhanceSupportPanel(panel, copy) {
  const layout = panel.querySelector(".page-layout");
  if (layout && !layout.querySelector(".version-callout")) {
    const callout = document.createElement("article");
    callout.className = "callout version-callout";
    callout.innerHTML = '<strong>StackShot 1.5</strong><p>' + copy.releaseIntro + '</p>';
    layout.prepend(callout);
  }

  const faq = panel.querySelector(".faq-grid");
  if (faq && !faq.querySelector(".qr-support-card")) {
    const card = document.createElement("article");
    card.className = "faq-card qr-support-card";
    card.innerHTML = '<span class="release-label">QR EXTRACTOR</span><h3>' +
      copy.supportTitle + '</h3><p>' + copy.supportBody + '</p>';
    faq.prepend(card);
  }
}

function enhancePrivacyPanel(panel, copy) {
  const grid = panel.querySelector(".policy-grid");
  if (!grid || grid.querySelector(".qr-privacy-block")) return;
  const block = document.createElement("article");
  block.className = "policy-block qr-privacy-block";
  block.innerHTML = '<span class="release-label">ON-DEVICE</span><h2>' +
    copy.privacyTitle + '</h2><p>' + copy.privacyBody + '</p>';
  grid.prepend(block);
}

function syncPageEnhancements(lang) {
  ensureBrandVersion();
  const panel = document.querySelector('[data-lang-panel="' + lang + '"]');
  if (!panel) return;
  const copy = getReleaseCopy(lang);
  const page = document.body.getAttribute("data-page");

  if (page === "home") {
    updateHeroForRelease(panel, copy);
    enhanceProductStage(panel, copy);
    buildReleaseShowcase(panel, copy, lang);
  } else if (page === "support") {
    enhanceSupportPanel(panel, copy);
  } else if (page === "privacy") {
    enhancePrivacyPanel(panel, copy);
  }

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

  syncPageEnhancements(panelLang);
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
        setLanguage(lang.code);
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
    ".stat-card, .support-card, .faq-card, .policy-block, .release-card"
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
});
