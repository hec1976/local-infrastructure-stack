(function () {
  'use strict';

  function esc(value) {
    return String(value == null ? '' : value).replace(/[&<>'"]/g, function (c) {
      return {'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c];
    });
  }

  function ensureHost() {
    var host = document.getElementById('mmbbFeedbackHost');
    if (host) return host;
    host = document.createElement('div');
    host.id = 'mmbbFeedbackHost';
    host.className = 'toast-container position-fixed top-0 end-0 p-3 mmbb-feedback-host';
    host.setAttribute('aria-live', 'polite');
    host.setAttribute('aria-atomic', 'true');
    document.body.appendChild(host);
    return host;
  }

  function normalizeType(type) {
    type = String(type || 'info').toLowerCase();
    if (type === 'error' || type === 'danger') return 'danger';
    if (type === 'warn' || type === 'warning') return 'warning';
    if (type === 'success' || type === 'ok') return 'success';
    return 'info';
  }

  function iconFor(type) {
    return {success:'bi-check-circle-fill', danger:'bi-x-circle-fill', warning:'bi-exclamation-triangle-fill', info:'bi-info-circle-fill'}[type] || 'bi-info-circle-fill';
  }

  function titleFor(type) {
    return {success:'Erfolgreich', danger:'Fehler', warning:'Warnung', info:'Hinweis'}[type] || 'Hinweis';
  }

  window.mmbbNotify = function (type, message, details) {
    type = normalizeType(type);
    var host = ensureHost();
    var el = document.createElement('div');
    el.className = 'toast mmbb-feedback-toast border-0';
    el.setAttribute('role', type === 'danger' ? 'alert' : 'status');
    el.setAttribute('aria-live', type === 'danger' ? 'assertive' : 'polite');
    el.setAttribute('aria-atomic', 'true');
    var detailHtml = '';
    if (details !== undefined && details !== null && String(details) !== '') {
      detailHtml = '<details class="mt-2"><summary>Details</summary><pre class="mmbb-feedback-details mt-2 mb-0">' + esc(typeof details === 'string' ? details : JSON.stringify(details, null, 2)) + '</pre></details>';
    }
    el.innerHTML =
      '<div class="toast-header mmbb-feedback-header mmbb-feedback-' + type + '">' +
        '<i class="bi ' + iconFor(type) + ' me-2"></i>' +
        '<strong class="me-auto">' + titleFor(type) + '</strong>' +
        '<button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="Schliessen"></button>' +
      '</div>' +
      '<div class="toast-body"><div class="mmbb-feedback-message">' + esc(message) + '</div>' + detailHtml + '</div>';
    host.appendChild(el);

    if (window.bootstrap && window.bootstrap.Toast) {
      var toast = window.bootstrap.Toast.getOrCreateInstance(el, {autohide: type !== 'danger', delay: type === 'warning' ? 8500 : 6000});
      el.addEventListener('hidden.bs.toast', function () { el.remove(); }, {once:true});
      toast.show();
    } else {
      el.classList.add('show');
      if (type !== 'danger') setTimeout(function () { el.remove(); }, 6000);
    }
    return el;
  };

  window.mmbbNotifyFromResponse = function (payload, fallbackSuccess) {
    payload = payload || {};
    var ok = payload.ok === true || payload.ok === 1;
    var msg = payload.message || payload.error || fallbackSuccess || (ok ? 'Aktion erfolgreich.' : 'Aktion fehlgeschlagen.');
    return window.mmbbNotify(ok ? 'success' : 'danger', msg, payload.details || payload.response || '');
  };


  // -----------------------------------------------------------------------
  // Portalweiter Lade-/Aktivitaetsindikator
  // -----------------------------------------------------------------------
  // Token statt eines einfachen Counters: jeder Request beendet exakt den
  // Busy-State, den er selbst gestartet hat. Dadurch kann ein abgebrochener
  // oder parallel laufender Request den Spinner nicht mehr dauerhaft stehen
  // lassen.
  var busySeq = 0;
  var busyOps = new Map();
  var busyTimer = null;
  var busyVisibleSince = 0;
  var busyMinVisibleMs = 260;
  var busyDelayMs = 220;
  var busyMaxNetworkMs = 45000;
  var busyMaxNavigationMs = 15000;
  var busyMaxManualMs = 90000;

  function ensureBusyIndicator() {
    var el = document.getElementById('mmbbBusyIndicator');
    if (el) return el;
    el = document.createElement('div');
    el.id = 'mmbbBusyIndicator';
    el.className = 'mmbb-busy-indicator';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.setAttribute('aria-busy', 'true');
    el.innerHTML =
      '<span class="mmbb-busy-spinner" aria-hidden="true"></span>' +
      '<span class="mmbb-busy-copy">' +
        '<span class="mmbb-busy-title">Bitte warten</span>' +
        '<span class="mmbb-busy-message">Daten werden geladen ...</span>' +
      '</span>';
    document.body.appendChild(el);
    return el;
  }

  function setBusyMessage(message) {
    var el = ensureBusyIndicator();
    var msg = el.querySelector('.mmbb-busy-message');
    if (msg) msg.textContent = message || 'Daten werden geladen ...';
  }

  function newestBusyMessage() {
    var message = 'Daten werden geladen ...';
    busyOps.forEach(function (op) { if (op && op.message) message = op.message; });
    return message;
  }

  function revealBusy() {
    busyTimer = null;
    if (busyOps.size < 1) return;
    setBusyMessage(newestBusyMessage());
    var el = ensureBusyIndicator();
    busyVisibleSince = Date.now();
    el.classList.add('is-visible');
  }

  function hideBusy() {
    var el = document.getElementById('mmbbBusyIndicator');
    if (!el) return;
    var remaining = busyMinVisibleMs - (Date.now() - busyVisibleSince);
    if (el.classList.contains('is-visible') && remaining > 0) {
      window.setTimeout(function () {
        if (busyOps.size === 0) el.classList.remove('is-visible');
      }, remaining);
    } else {
      el.classList.remove('is-visible');
    }
  }

  function resetBusy() {
    busyOps.forEach(function (op) { if (op && op.timer) window.clearTimeout(op.timer); });
    busyOps.clear();
    if (busyTimer !== null) window.clearTimeout(busyTimer);
    busyTimer = null;
    document.body.classList.remove('mmbb-page-leaving');
    hideBusy();
  }

  window.mmbbBusyStart = function (message, options) {
    options = options || {};
    var token = 'busy-' + (++busySeq);
    var kind = options.kind || 'manual';
    var maxAge = Number(options.maxAge || (kind === 'navigation' ? busyMaxNavigationMs : ((kind === 'fetch' || kind === 'xhr') ? busyMaxNetworkMs : busyMaxManualMs)));
    var op = {message: message || 'Daten werden geladen ...', started: Date.now(), kind: kind, timer: null};
    if (maxAge > 0) {
      op.timer = window.setTimeout(function () {
        // Failsafe: ein verlorenes loadend/finally darf die Portal-UI niemals
        // dauerhaft im Busy-Zustand lassen. Der eigentliche Request wird nicht
        // abgebrochen; lediglich die Anzeige wird freigegeben.
        window.mmbbBusyStop(token);
      }, maxAge);
    }
    busyOps.set(token, op);
    setBusyMessage(op.message);
    var currentBusy = document.getElementById('mmbbBusyIndicator');
    if (busyTimer === null && !(currentBusy && currentBusy.classList.contains('is-visible'))) {
      busyTimer = window.setTimeout(revealBusy, options.immediate ? 0 : busyDelayMs);
    }
    return token;
  };

  window.mmbbBusyStop = function (token) {
    var op = null;
    if (token && busyOps.has(token)) {
      op = busyOps.get(token);
      busyOps.delete(token);
    } else if (!token && busyOps.size) {
      // Rueckwaertskompatibilitaet: genau den zuletzt gestarteten Eintrag beenden.
      var keys = Array.from(busyOps.keys());
      var key = keys[keys.length - 1];
      op = busyOps.get(key);
      busyOps.delete(key);
    }
    if (op && op.timer) window.clearTimeout(op.timer);
    if (busyOps.size > 0) {
      setBusyMessage(newestBusyMessage());
      return busyOps.size;
    }
    if (busyTimer !== null) {
      window.clearTimeout(busyTimer);
      busyTimer = null;
    }
    hideBusy();
    return 0;
  };

  window.mmbbBusyReset = resetBusy;
  window.mmbbBusySetMessage = function (message) { setBusyMessage(message); };

  // fetch() zentral erfassen. Seiten koennen mit {mmbbBusy:false} bewusst
  // aussteigen, falls sie selbst einen spezialisierten Progress-Indikator haben.
  if (window.fetch && !window.mmbbNativeFetch) {
    window.mmbbNativeFetch = window.fetch.bind(window);
    window.fetch = function (input, init) {
      init = init || {};
      var showBusy = init.mmbbBusy !== false;
      var message = init.mmbbBusyMessage || 'Daten werden geladen ...';
      var token = showBusy ? window.mmbbBusyStart(message, {kind:'fetch'}) : null;
      var cleanInit = Object.assign({}, init);
      delete cleanInit.mmbbBusy;
      delete cleanInit.mmbbBusyMessage;
      try {
        var request = window.mmbbNativeFetch(input, cleanInit);
        // finally garantiert die Freigabe sowohl bei Erfolg als auch Fehler.
        return request.finally(function () { if (token) window.mmbbBusyStop(token); });
      } catch (err) {
        if (token) window.mmbbBusyStop(token);
        throw err;
      }
    };
  }

  // XMLHttpRequest erfasst auch jQuery/DataTables und aeltere Portalmodule.
  if (window.XMLHttpRequest && !window.mmbbNativeXhrSend) {
    window.mmbbNativeXhrSend = window.XMLHttpRequest.prototype.send;
    window.XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      var tracked = xhr.mmbbBusy !== false;
      var token = tracked ? window.mmbbBusyStart(xhr.mmbbBusyMessage || 'Daten werden geladen ...', {kind:'xhr'}) : null;
      if (tracked) {
        // loadend wird bei Erfolg, Fehler, Abort und Timeout genau einmal ausgeloest.
        xhr.addEventListener('loadend', function () { if (token) window.mmbbBusyStop(token); }, {once:true});
      }
      try {
        return window.mmbbNativeXhrSend.apply(xhr, arguments);
      } catch (err) {
        if (token) window.mmbbBusyStop(token);
        throw err;
      }
    };
  }

  function actionLabel(target) {
    if (!target) return 'Aktion wird ausgefuehrt ...';
    var text = (target.getAttribute && (target.getAttribute('data-busy-message') || target.getAttribute('aria-label'))) || target.textContent || '';
    text = String(text).replace(/\s+/g, ' ').trim();
    return text ? text + ' ...' : 'Aktion wird ausgefuehrt ...';
  }

  // Klassische Formulare: nur fuer echte Vollseiten-Submits markieren. Wenn
  // JavaScript den Submit verhindert, wird der Navigations-Token sofort wieder
  // beendet; fetch/XHR besitzen ihren eigenen Token.
  document.addEventListener('submit', function (ev) {
    var form = ev.target;
    if (!form || (form.getAttribute && form.getAttribute('data-no-global-busy') === '1')) return;
    var submitter = ev.submitter || null;
    document.body.classList.add('mmbb-page-leaving');
    var token = window.mmbbBusyStart(actionLabel(submitter || form), {immediate:true, kind:'navigation'});
    window.setTimeout(function () {
      if (ev.defaultPrevented) {
        document.body.classList.remove('mmbb-page-leaving');
        window.mmbbBusyStop(token);
      }
    }, 0);
  }, true);

  // Interne Vollseiten-Navigation bekommt ebenfalls sofort sichtbares Feedback.
  document.addEventListener('click', function (ev) {
    if (ev.defaultPrevented || ev.button !== 0 || ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey) return;
    var link = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
    if (!link || link.target === '_blank' || link.hasAttribute('download') || link.getAttribute('data-no-global-busy') === '1') return;
    var href = link.getAttribute('href') || '';
    if (!href || href.charAt(0) === '#' || href.indexOf('javascript:') === 0) return;
    try {
      var url = new URL(link.href, window.location.href);
      if (url.origin !== window.location.origin) return;
      document.body.classList.add('mmbb-page-leaving');
      var token = window.mmbbBusyStart('Seite wird geladen ...', {immediate:true, kind:'navigation'});
      window.setTimeout(function () {
        if (ev.defaultPrevented) {
          document.body.classList.remove('mmbb-page-leaving');
          window.mmbbBusyStop(token);
        }
      }, 0);
    } catch (ignore) {}
  }, true);

  // Navigation/BFCache und wieder sichtbare Tabs duerfen niemals einen alten
  // Busy-State aus einer vorherigen Seite behalten.
  window.addEventListener('pageshow', resetBusy);
  window.addEventListener('pagehide', resetBusy);
  window.addEventListener('load', function () { if (!document.body.classList.contains('mmbb-page-leaving')) resetBusy(); });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') {
      var stale = [];
      busyOps.forEach(function (op, key) { if (Date.now() - op.started > 120000 && op.kind !== 'fetch' && op.kind !== 'xhr') stale.push(key); });
      stale.forEach(function (key) { busyOps.delete(key); });
      if (busyOps.size === 0) resetBusy();
    }
  });

  // Letzte Sicherheitsleine fuer UI-Leaks: ein einzelner Navigations-/Manual-
  // Token darf nicht minutenlang in der Ecke stehen, wenn gar kein Seitenwechsel
  // stattgefunden hat. Netzwerk-Requests werden nicht vorzeitig beendet.
  window.setInterval(function () {
    // Zweite Sicherheitsleine gegen inkonsistente Browser-/Library-Events.
    // Jeder Token besitzt zusaetzlich bereits seinen eigenen Timeout.
    var stale = [];
    var now = Date.now();
    busyOps.forEach(function (op, key) {
      var age = now - op.started;
      var limit = (op.kind === 'navigation') ? busyMaxNavigationMs : ((op.kind === 'fetch' || op.kind === 'xhr') ? busyMaxNetworkMs : busyMaxManualMs);
      if (age > limit + 5000) stale.push(key);
    });
    stale.forEach(function (key) { window.mmbbBusyStop(key); });
    if (busyOps.size === 0 && stale.length) resetBusy();
  }, 5000);

  // Bestehende Portalmodule verwenden teilweise noch window.alert(). Statt
  // Browser-Popups erhalten sie dadurch ohne invasive Seitenaenderungen dieselbe
  // visuelle Rueckmeldung wie neue Module. confirm()/prompt() bleiben unveraendert.
  if (!window.mmbbNativeAlert) {
    window.mmbbNativeAlert = window.alert.bind(window);
    window.alert = function (message) { window.mmbbNotify('info', String(message == null ? '' : message)); };
  }
})();
