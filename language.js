// Edit both data-en and data-zh values in index.html to update bilingual content.
(() => {
  const button = document.getElementById('language-toggle');
  const key = 'baisha-villa-language';
  let language = 'en';
  try { if (localStorage.getItem(key) === 'zh') language = 'zh'; } catch (_) {}
  function applyLanguage() {
    document.documentElement.lang = language === 'zh' ? 'zh-Hant' : 'en';
    document.querySelectorAll('[data-en][data-zh]').forEach(element => {
      element.textContent = element.getAttribute('data-' + language);
    });
    ['alt', 'aria-label', 'content'].forEach(attribute => {
      document.querySelectorAll('[data-en-' + attribute + ']').forEach(element => {
        element.setAttribute(attribute, element.getAttribute('data-' + language + '-' + attribute));
      });
    });
    button.textContent = language === 'en' ? '繁體中文' : 'English';
    button.lang = language === 'en' ? 'zh-Hant' : 'en';
    button.setAttribute('aria-label', language === 'en' ? 'Switch to Traditional Chinese' : '切換為英文');
  }
  button.hidden = false;
  button.addEventListener('click', () => {
    language = language === 'en' ? 'zh' : 'en';
    applyLanguage();
    try { localStorage.setItem(key, language); } catch (_) {}
  });
  applyLanguage();
})();
