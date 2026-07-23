// Wrapped in an IIFE so its declarations don't collide with main.js globals
// (both are plain <script>s sharing the global scope).
(function () {
  // Ordered list of doc pages, derived from the sidebar.
  const navLinks = Array.from(document.querySelectorAll(".sidebar__list a"));
  const pages = navLinks.map((a) => ({
    id: a.getAttribute("href").slice(1),
    title: a.dataset.title,
    link: a,
  }));
  const ids = new Set(pages.map((p) => p.id));

  const docNav = document.getElementById("docNav");
  const mobileCrumb = document.getElementById("mobileCrumb");
  const sidebar = document.getElementById("sidebar");
  const sidebarToggle = document.getElementById("sidebarToggle");

  function showPage(id) {
    let index = pages.findIndex((p) => p.id === id);
    if (index === -1) index = 0;
    const page = pages[index];

    document.querySelectorAll(".doc-page").forEach((el) => {
      el.classList.toggle("active", el.id === page.id);
    });
    navLinks.forEach((a) => a.classList.toggle("active", a === page.link));
    if (mobileCrumb) mobileCrumb.textContent = page.title;
    document.title = "Weave · " + page.title;

    // Prev / next
    const prev = pages[index - 1];
    const next = pages[index + 1];
    docNav.innerHTML =
      (prev ? `<a class="prev" href="#${prev.id}"><div class="doc-nav__dir">← Previous</div><div class="doc-nav__title">${prev.title}</div></a>` : "") +
      (next ? `<a class="next" href="#${next.id}"><div class="doc-nav__dir">Next →</div><div class="doc-nav__title">${next.title}</div></a>` : "");

    sidebar.classList.remove("open");
    // Jump to the top of the article, instantly (overriding the global
    // `scroll-behavior: smooth`). Deferred a frame so it wins over any
    // residual browser scroll restoration.
    requestAnimationFrame(() => window.scrollTo({ top: 0, left: 0, behavior: "auto" }));
  }

  function currentId() {
    const id = (location.hash || "#about").slice(1);
    return ids.has(id) ? id : "about";
  }

  // Intercept in-page navigation so the browser never performs its native
  // "scroll to #id" jump (which would fight our scroll-to-top). We update the
  // URL with pushState and drive the router ourselves.
  document.addEventListener("click", (e) => {
    const a = e.target.closest && e.target.closest('a[href^="#"]');
    if (!a) return;
    const id = a.getAttribute("href").slice(1);
    if (!ids.has(id)) return;
    e.preventDefault();
    if (currentId() !== id) history.pushState(null, "", "#" + id);
    showPage(id);
  });

  // Back / forward buttons and direct hash edits.
  window.addEventListener("popstate", () => showPage(currentId()));
  window.addEventListener("hashchange", () => showPage(currentId()));

  if (sidebarToggle) {
    sidebarToggle.addEventListener("click", () => sidebar.classList.toggle("open"));
  }

  // Syntax highlighting (highlight.js loads from CDN; degrade gracefully if blocked).
  if (window.hljs) {
    document.querySelectorAll("pre code").forEach((block) => {
      try { window.hljs.highlightElement(block); } catch (_) { /* ignore */ }
    });
  }

  showPage(currentId());
})();
