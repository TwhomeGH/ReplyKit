/* 檔案檢視：以 hash（#Lnnn）或 data-line 決定高亮行；行號連結就地捲動不重載。 */
(function () {
  const src = document.getElementById("src");
  if (!src) return;
  const initial = parseInt(src.dataset.line || "0", 10);
  const total = src.querySelectorAll("span").length;

  function highlight(line) {
    if (!(line >= 1 && line <= total)) return;
    src.querySelectorAll("span.hit").forEach((el) => el.classList.remove("hit"));
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
    const a = e.target.closest ? e.target.closest("a") : null;
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
