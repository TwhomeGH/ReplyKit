/* 檔案檢視：行號、行跳轉、目標行高亮，以及 Swift／Markdown 語法上色（純前端、零依賴）。 */
(function () {
  const src = document.getElementById("src");
  if (!src) return;

  const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
  const span = (cls, text) => (cls ? `<span class="tok-${cls}">${esc(text)}</span>` : esc(text));

  const SWIFT_KEYWORDS = new Set(
    ("func var let class struct enum protocol extension init deinit subscript typealias associatedtype " +
      "import if else guard switch case default for while repeat return break continue throw throws rethrow " +
      "try catch defer do in where as is some any await async actor static self Self super nil true false " +
      "public private internal fileprivate open final override mutating nonmutating lazy weak unowned " +
      "indirect convenience required dynamic inout").split(/\s+/));

  /* Swift 逐字掃描：處理字串、註釋（含跨行）、數字、屬性/前置、關鍵字、型別與函式呼叫。 */
  function highlightSwift(line, state) {
    let out = "", i = 0;
    const n = line.length;
    while (i < n) {
      if (state.block) {
        const end = line.indexOf("*/", i);
        if (end === -1) { out += span("c", line.slice(i)); i = n; break; }
        out += span("c", line.slice(i, end + 2)); i = end + 2; state.block = false; continue;
      }
      const c = line[i];
      if (c === "/" && line[i + 1] === "/") { out += span("c", line.slice(i)); break; }
      if (c === "/" && line[i + 1] === "*") {
        const end = line.indexOf("*/", i + 2);
        if (end === -1) { out += span("c", line.slice(i)); state.block = true; break; }
        out += span("c", line.slice(i, end + 2)); i = end + 2; continue;
      }
      if (c === '"') {
        let j = i + 1;
        while (j < n) { if (line[j] === "\\") { j += 2; continue; } if (line[j] === '"') { j++; break; } j++; }
        out += span("s", line.slice(i, j)); i = j; continue;
      }
      if (c === "@" || c === "#") {
        const m = line.slice(i).match(/^[@#][A-Za-z_]\w*/);
        if (m) { out += span("a", m[0]); i += m[0].length; continue; }
      }
      if (/[0-9]/.test(c) && !/[A-Za-z0-9_]/.test(line[i - 1] || "")) {
        const m = line.slice(i).match(/^0[xX][0-9A-Fa-f_]+|^0[bB][01_]+|^\d[\d_.eExX]*/);
        out += span("n", m[0]); i += m[0].length; continue;
      }
      if (/[A-Za-z_]/.test(c)) {
        const m = line.slice(i).match(/^[A-Za-z_]\w*/)[0];
        const isCall = /^\s*\(/.test(line.slice(i + m.length));
        const cls = SWIFT_KEYWORDS.has(m) ? "k" : (/^[A-Z]/.test(m) ? "t" : (isCall ? "f" : ""));
        out += span(cls, m); i += m.length; continue;
      }
      const m = line.slice(i).match(/^[^\sA-Za-z0-9_@#"/]+|\s+/);
      if (m) { out += esc(m[0]); i += m[0].length; } else { out += esc(c); i += 1; }
    }
    return out;
  }

  /* Markdown 輕量上色：標題、引言、行內程式碼與連結。 */
  function highlightMarkdown(line) {
    if (/^\s{0,3}#{1,6}\s/.test(line)) return span("k", line);
    if (/^\s{0,3}>\s?/.test(line)) return span("c", line);
    return esc(line)
      .replace(/`([^`]+)`/g, '<span class="tok-s">`$1`</span>')
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<span class="tok-t">$1</span>($2)');
  }

  const isMarkdown = /\.(md|markdown)$/i.test(src.dataset.path || "");
  const state = { block: false };
  src.querySelectorAll(".code").forEach((el) => {
    const text = el.textContent;
    el.innerHTML = isMarkdown ? highlightMarkdown(text) : highlightSwift(text, state);
  });

  const lines = src.querySelectorAll(".ln");
  const total = lines.length;
  const initial = parseInt(src.dataset.line || "0", 10);

  function highlight(line) {
    if (!(line >= 1 && line <= total)) return;
    src.querySelectorAll(".ln.hit").forEach((el) => el.classList.remove("hit"));
    const el = document.getElementById("L" + line);
    if (el) { el.classList.add("hit"); el.scrollIntoView({ block: "center" }); }
  }
  function fromHash() {
    const m = (location.hash || "").match(/^#L(\d+)$/);
    return m ? parseInt(m[1], 10) : initial;
  }
  function go(line, push) {
    if (!(line >= 1 && line <= total)) return;
    if (push) history.replaceState(null, "", "#L" + line);
    highlight(line);
  }

  // 行號連結改為就地捲動（不整頁重載）。
  src.addEventListener("click", (e) => {
    const a = e.target.closest ? e.target.closest("a.no") : null;
    const href = a && a.getAttribute("href");
    if (href && href.indexOf("#L") === 0) { e.preventDefault(); go(parseInt(href.slice(2), 10), true); }
  });

  const jump = document.getElementById("jump");
  if (jump) {
    jump.max = total;
    jump.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); go(parseInt(jump.value, 10), true); }
    });
  }

  document.getElementById("copy")?.addEventListener("click", async (e) => {
    const path = src.dataset.path || "";
    try { await navigator.clipboard.writeText(path); e.currentTarget.textContent = "已複製"; }
    catch { e.currentTarget.textContent = path; }
    setTimeout(() => { e.currentTarget.textContent = "複製路徑"; }, 1500);
  });

  // 「返回索引」盡量回到上一個頁面（保留瀏覽位置）。
  document.getElementById("back")?.addEventListener("click", (e) => {
    if (history.length > 1) { e.preventDefault(); history.back(); }
  });

  window.addEventListener("hashchange", () => highlight(fromHash()));
  highlight(fromHash());
})();
