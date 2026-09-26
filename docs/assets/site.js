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
