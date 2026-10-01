// Remembers the EN / 中 choice across the pages of the site. Without JavaScript the switch still works per page.
(function () {
  var box = document.getElementById('lang-toggle');
  if (!box) return;
  var stored = null;
  try { stored = localStorage.getItem('lint-lang'); } catch (e) {}
  if (stored === 'zh' || (stored === null && /^zh\b/i.test(navigator.language || ''))) box.checked = true;
  function mark() { document.documentElement.lang = box.checked ? 'zh-Hant' : 'en'; }
  mark();
  box.addEventListener('change', function () {
    mark();
    try { localStorage.setItem('lint-lang', box.checked ? 'zh' : 'en'); } catch (e) {}
  });
})();

// Light / dark theme. The page head has already set data-theme (the saved choice, else the system's); the button changes it.
// Until a choice is saved, the page follows the system when it switches.
(function () {
  var button = document.getElementById('theme-toggle');
  if (!button) return;
  var root = document.documentElement;
  var meta = document.querySelector('meta[name="theme-color"]');
  function show(theme) {
    root.setAttribute('data-theme', theme);
    button.setAttribute('aria-pressed', theme === 'light' ? 'true' : 'false');
    if (meta) meta.setAttribute('content', theme === 'light' ? '#faf9ff' : '#0b0a1a');
  }
  function saved() {
    try { var theme = localStorage.getItem('lint-theme'); return theme === 'light' || theme === 'dark' ? theme : null; } catch (e) { return null; }
  }
  show(root.getAttribute('data-theme') === 'light' ? 'light' : 'dark');
  button.hidden = false;
  button.addEventListener('click', function () {
    var next = root.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
    show(next);
    try { localStorage.setItem('lint-theme', next); } catch (e) {}
  });
  if (window.matchMedia) {
    var query = matchMedia('(prefers-color-scheme: light)');
    var follow = function (event) { if (saved() === null) show(event.matches ? 'light' : 'dark'); };
    if (query.addEventListener) query.addEventListener('change', follow);
  }
})();

// Screenshots open as a floating image on the page instead of a new tab.
// Close with the × button, Esc, or a click outside the image. Without JavaScript the link opens the image file.
(function () {
  var box = null, img = null, closeButton = null, opener = null;

  function build() {
    box = document.createElement('div');
    box.className = 'lightbox';
    box.setAttribute('role', 'dialog');
    box.setAttribute('aria-modal', 'true');
    box.hidden = true;
    img = document.createElement('img');
    img.className = 'lightbox-image';
    closeButton = document.createElement('button');
    closeButton.type = 'button';
    closeButton.className = 'lightbox-close';
    closeButton.setAttribute('aria-label', 'Close / 關閉');
    closeButton.innerHTML = '<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><path d="M1 1l12 12M13 1L1 13" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
    box.appendChild(img);
    box.appendChild(closeButton);
    document.body.appendChild(box);
    closeButton.addEventListener('click', close);
    box.addEventListener('click', function (event) { if (event.target === box) close(); });
  }

  function open(link) {
    if (!box) build();
    var thumb = link.querySelector('img');
    img.src = link.getAttribute('href');
    img.alt = thumb ? thumb.alt : '';
    box.setAttribute('aria-label', img.alt);
    opener = link;
    box.hidden = false;
    document.documentElement.classList.add('lightbox-open');
    closeButton.focus();
  }

  function close() {
    if (!box || box.hidden) return;
    box.hidden = true;
    img.removeAttribute('src');
    document.documentElement.classList.remove('lightbox-open');
    if (opener) opener.focus();
    opener = null;
  }

  document.addEventListener('click', function (event) {
    var link = event.target.closest && event.target.closest('a.shot');
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return;
    event.preventDefault();
    open(link);
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape') close();
  });
})();
