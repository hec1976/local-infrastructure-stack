(() => {
  'use strict';

  function darkMode() {
    return String(document.documentElement.getAttribute('data-bs-theme') || '').toLowerCase() === 'dark';
  }

  function syncTheme(editor) {
    editor.setTheme(darkMode() ? 'ace/theme/tomorrow_night' : 'ace/theme/tomorrow');
  }

  function create(elementId) {
    if (!window.ace) throw new Error('Ace Editor ist nicht verfügbar.');
    const editor = window.ace.edit(elementId);
    editor.session.setMode('ace/mode/json');
    editor.setOptions({
      fontSize: '12px',
      tabSize: 2,
      useSoftTabs: true,
      wrap: true,
      showPrintMargin: false,
    });
    syncTheme(editor);

    try {
      const observer = new MutationObserver(() => syncTheme(editor));
      observer.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ['data-bs-theme'],
      });
    } catch (_) {}

    return editor;
  }

  window.MMBBConfigurationJsonEditor = Object.freeze({create, syncTheme});
})();
