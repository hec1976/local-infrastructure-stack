/*
 * TEKO offline Ace-compatible adapter.
 * Provides the subset of the Ace API used by Config Manager, backed by
 * the locally bundled CodeMirror editor. No network requests are made.
 */
(function (global) {
  'use strict';

  if (!global.CodeMirror) {
    throw new Error('Local CodeMirror backend is missing.');
  }

  const modeMap = {
    'ace/mode/json': {name: 'javascript', json: true},
    'ace/mode/yaml': 'yaml',
    'ace/mode/ini': 'properties',
    'ace/mode/properties': 'properties',
    'ace/mode/xml': 'xml',
    'ace/mode/sh': 'shell',
    'ace/mode/text': null
  };

  const themeMap = {
    'ace/theme/monokai': 'monokai',
    'ace/theme/tomorrow_night': 'tomorrow-night',
    'ace/theme/tomorrow': 'default'
  };

  function offsetToPos(text, offset) {
    const before = text.slice(0, Math.max(0, offset));
    const lines = before.split('\n');
    return {row: lines.length - 1, column: lines[lines.length - 1].length};
  }

  function createEditor(target) {
    const el = typeof target === 'string' ? document.getElementById(target) : target;
    if (!el) throw new Error('Editor target not found');

    // Keep the original container and replace only its visual content.
    const textarea = document.createElement('textarea');
    textarea.value = el.textContent || '';
    textarea.setAttribute('aria-label', 'Konfigurationseditor');
    el.textContent = '';
    el.appendChild(textarea);

    const cm = global.CodeMirror.fromTextArea(textarea, {
      lineNumbers: true,
      mode: null,
      theme: 'default',
      lineWrapping: true,
      indentUnit: 2,
      tabSize: 2,
      indentWithTabs: false
    });

    cm.setSize('100%', '100%');

    const changeHandlers = [];
    cm.on('change', function () {
      changeHandlers.forEach(fn => {
        try { fn(); } catch (_) {}
      });
    });

    const session = {
      setMode(mode) {
        cm.setOption('mode', modeMap[mode] ?? null);
      },
      setUseWorker() {},
      on(event, fn) {
        if (event === 'change' && typeof fn === 'function') changeHandlers.push(fn);
      },
      getScrollTop() {
        return cm.getScrollInfo().top;
      },
      setScrollTop(value) {
        cm.scrollTo(null, Number(value) || 0);
      }
    };

    const editor = {
      container: el,
      session,
      setTheme(theme) {
        cm.setOption('theme', themeMap[theme] || 'default');
      },
      setOptions(opts) {
        opts = opts || {};
        if (opts.wrap !== undefined) cm.setOption('lineWrapping', !!opts.wrap);
        if (opts.tabSize !== undefined) cm.setOption('tabSize', Number(opts.tabSize) || 2);
        if (opts.useSoftTabs !== undefined) cm.setOption('indentWithTabs', !opts.useSoftTabs);
        if (opts.fontSize) cm.getWrapperElement().style.fontSize = String(opts.fontSize);
        if (opts.showPrintMargin !== undefined) {
          // CodeMirror has no print margin by default.
        }
        cm.refresh();
      },
      getValue() {
        return cm.getValue();
      },
      setValue(value, cursor) {
        cm.setValue(String(value ?? ''));
        if (cursor === -1) cm.setCursor({line: 0, ch: 0});
      },
      setReadOnly(value) {
        cm.setOption('readOnly', !!value);
      },
      focus() {
        cm.focus();
      },
      resize() {
        cm.refresh();
      },
      getCursorPosition() {
        const p = cm.getCursor();
        return {row: p.line, column: p.ch};
      },
      moveCursorToPosition(pos) {
        if (!pos) return;
        cm.setCursor({line: Number(pos.row) || 0, ch: Number(pos.column) || 0});
      },
      _cm: cm
    };

    return editor;
  }

  global.ace = {
    edit: createEditor,
    config: {
      set: function () {},
      setModuleUrl: function () {}
    }
  };
})(window);
