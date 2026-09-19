(function (root, factory) {
  'use strict';

  const api = factory();

  if (typeof module === 'object' && module.exports) {
    module.exports = api;
  } else {
    root.MMBBConfigDiff = api;
    if (root.document) {
      root.document.addEventListener('DOMContentLoaded', function () {
        api.init(root.document);
      });
    }
  }
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const MAX_BYTES = 5 * 1024 * 1024;
  const MAX_LINES = 20000;
  const INLINE_TOKEN_LIMIT = 1200;
  const MAX_EDIT_DISTANCE = 2500;
  const COMMENT_PREFIXES = ['#', ';', '//'];

  function normalizeText(text) {
    return String(text || '').replace(/\r\n?/g, '\n');
  }

  function isCommentLine(raw) {
    const value = String(raw || '').trimStart();
    return COMMENT_PREFIXES.some(function (prefix) {
      return value.startsWith(prefix);
    });
  }

  function normalizeLine(raw, options) {
    let value = String(raw || '');

    if (options.ignoreWhitespace) {
      value = value.replace(/[\t ]+/g, '');
    }
    if (options.ignoreCase) {
      value = value.toLocaleLowerCase();
    }

    return value;
  }

  function prepareLines(text, options) {
    const normalized = normalizeText(text);
    const source = normalized === '' ? [] : normalized.split('\n');
    const lines = [];
    let ignoredBlank = 0;
    let ignoredComments = 0;

    source.forEach(function (raw, index) {
      const key = normalizeLine(raw, options);

      if (options.ignoreBlankLines && key.trim() === '') {
        ignoredBlank += 1;
        return;
      }
      if (options.ignoreComments && isCommentLine(raw)) {
        ignoredComments += 1;
        return;
      }

      lines.push({
        raw: raw,
        key: key,
        number: index + 1,
        comment: isCommentLine(raw)
      });
    });

    return {
      lines: lines,
      sourceLineCount: source.length,
      ignoredBlank: ignoredBlank,
      ignoredComments: ignoredComments
    };
  }

  function mapValue(map, key, fallback) {
    return map.has(key) ? map.get(key) : fallback;
  }

  function myersDiff(left, right, equals, maxDepth) {
    const n = left.length;
    const m = right.length;
    const max = n + m;
    const depthLimit = Number.isInteger(maxDepth) ? Math.min(max, Math.max(0, maxDepth)) : max;
    const same = typeof equals === 'function' ? equals : function (a, b) { return a === b; };
    let frontier = new Map();
    const trace = [];

    frontier.set(1, 0);

    for (let depth = 0; depth <= depthLimit; depth += 1) {
      trace.push(new Map(frontier));

      for (let diagonal = -depth; diagonal <= depth; diagonal += 2) {
        const fromDown = mapValue(frontier, diagonal + 1, Number.NEGATIVE_INFINITY);
        const fromRight = mapValue(frontier, diagonal - 1, Number.NEGATIVE_INFINITY);
        let x;

        if (diagonal === -depth || (diagonal !== depth && fromRight < fromDown)) {
          x = Math.max(0, fromDown);
        } else {
          x = Math.max(0, fromRight + 1);
        }

        let y = x - diagonal;

        while (x < n && y < m && same(left[x], right[y])) {
          x += 1;
          y += 1;
        }

        frontier.set(diagonal, x);

        if (x >= n && y >= m) {
          return backtrackMyers(trace, left, right, same);
        }
      }
    }

    if (depthLimit < max) {
      const error = new Error('Die Konfigurationen unterscheiden sich an sehr vielen Stellen. Bitte in kleinere Abschnitte aufteilen.');
      error.code = 'DIFF_COMPLEXITY_LIMIT';
      throw error;
    }

    return [];
  }

  function backtrackMyers(trace, left, right, equals) {
    let x = left.length;
    let y = right.length;
    const operations = [];

    for (let depth = trace.length - 1; depth >= 0; depth -= 1) {
      const frontier = trace[depth];
      const diagonal = x - y;
      const fromDown = mapValue(frontier, diagonal + 1, Number.NEGATIVE_INFINITY);
      const fromRight = mapValue(frontier, diagonal - 1, Number.NEGATIVE_INFINITY);
      let previousDiagonal;

      if (diagonal === -depth || (diagonal !== depth && fromRight < fromDown)) {
        previousDiagonal = diagonal + 1;
      } else {
        previousDiagonal = diagonal - 1;
      }

      const previousX = Math.max(0, mapValue(frontier, previousDiagonal, 0));
      const previousY = previousX - previousDiagonal;

      while (x > previousX && y > previousY) {
        const leftValue = left[x - 1];
        const rightValue = right[y - 1];
        if (!equals(leftValue, rightValue)) {
          break;
        }
        operations.push({ type: 'equal', left: leftValue, right: rightValue });
        x -= 1;
        y -= 1;
      }

      if (depth === 0) {
        break;
      }

      if (x === previousX) {
        operations.push({ type: 'insert', right: right[y - 1] });
        y -= 1;
      } else {
        operations.push({ type: 'delete', left: left[x - 1] });
        x -= 1;
      }
    }

    while (x > 0 && y > 0) {
      operations.push({ type: 'equal', left: left[x - 1], right: right[y - 1] });
      x -= 1;
      y -= 1;
    }
    while (x > 0) {
      operations.push({ type: 'delete', left: left[x - 1] });
      x -= 1;
    }
    while (y > 0) {
      operations.push({ type: 'insert', right: right[y - 1] });
      y -= 1;
    }

    operations.reverse();
    return operations;
  }

  function alignOperations(operations) {
    const rows = [];
    let index = 0;

    while (index < operations.length) {
      const operation = operations[index];

      if (operation.type === 'equal') {
        rows.push({ type: 'equal', left: operation.left, right: operation.right });
        index += 1;
        continue;
      }

      const deletes = [];
      const inserts = [];

      while (index < operations.length && operations[index].type !== 'equal') {
        if (operations[index].type === 'delete') {
          deletes.push(operations[index].left);
        } else if (operations[index].type === 'insert') {
          inserts.push(operations[index].right);
        }
        index += 1;
      }

      const count = Math.max(deletes.length, inserts.length);
      for (let offset = 0; offset < count; offset += 1) {
        const left = deletes[offset] || null;
        const right = inserts[offset] || null;
        rows.push({
          type: left && right ? 'change' : (left ? 'delete' : 'insert'),
          left: left,
          right: right
        });
      }
    }

    return rows;
  }

  function tokenizeLine(value) {
    const text = String(value || '');
    return text.match(/\s+|[\p{L}\p{N}_.$:@/\\-]+|./gu) || [];
  }

  function inlineSegments(leftText, rightText) {
    const leftTokens = tokenizeLine(leftText);
    const rightTokens = tokenizeLine(rightText);

    if (leftTokens.length + rightTokens.length > INLINE_TOKEN_LIMIT) {
      return prefixSuffixSegments(leftText, rightText);
    }

    const operations = myersDiff(leftTokens, rightTokens);
    const left = [];
    const right = [];

    operations.forEach(function (operation) {
      if (operation.type === 'equal') {
        left.push({ text: operation.left, changed: false });
        right.push({ text: operation.right, changed: false });
      } else if (operation.type === 'delete') {
        left.push({ text: operation.left, changed: true });
      } else if (operation.type === 'insert') {
        right.push({ text: operation.right, changed: true });
      }
    });

    return { left: left, right: right };
  }

  function prefixSuffixSegments(leftText, rightText) {
    const left = String(leftText || '');
    const right = String(rightText || '');
    let prefix = 0;
    const min = Math.min(left.length, right.length);

    while (prefix < min && left[prefix] === right[prefix]) {
      prefix += 1;
    }

    let suffix = 0;
    while (
      suffix < (min - prefix) &&
      left[left.length - 1 - suffix] === right[right.length - 1 - suffix]
    ) {
      suffix += 1;
    }

    function build(value) {
      const segments = [];
      if (prefix > 0) {
        segments.push({ text: value.slice(0, prefix), changed: false });
      }
      const end = suffix > 0 ? value.length - suffix : value.length;
      if (end > prefix) {
        segments.push({ text: value.slice(prefix, end), changed: true });
      }
      if (suffix > 0) {
        segments.push({ text: value.slice(value.length - suffix), changed: false });
      }
      return segments;
    }

    return { left: build(left), right: build(right) };
  }

  function calculateDiff(leftText, rightText, options) {
    const leftBytes = new TextEncoder().encode(String(leftText || '')).length;
    const rightBytes = new TextEncoder().encode(String(rightText || '')).length;

    if (leftBytes > MAX_BYTES || rightBytes > MAX_BYTES) {
      throw new Error('Eine Eingabe ist grösser als 5 MiB. Bitte die Konfiguration aufteilen.');
    }

    const leftPrepared = prepareLines(leftText, options);
    const rightPrepared = prepareLines(rightText, options);

    if (leftPrepared.lines.length > MAX_LINES || rightPrepared.lines.length > MAX_LINES) {
      throw new Error("Eine Eingabe enthält mehr als 20'000 berücksichtigte Zeilen. Bitte die Konfiguration aufteilen.");
    }

    const operations = myersDiff(
      leftPrepared.lines,
      rightPrepared.lines,
      function (a, b) { return a.key === b.key; },
      MAX_EDIT_DISTANCE
    );
    const rows = alignOperations(operations);
    const summary = {
      equal: 0,
      change: 0,
      insert: 0,
      delete: 0,
      ignoredBlank: leftPrepared.ignoredBlank + rightPrepared.ignoredBlank,
      ignoredComments: leftPrepared.ignoredComments + rightPrepared.ignoredComments
    };

    rows.forEach(function (row) {
      summary[row.type] += 1;
      if (row.type === 'change') {
        row.inline = inlineSegments(row.left.raw, row.right.raw);
      }
    });

    return {
      rows: rows,
      summary: summary,
      left: leftPrepared,
      right: rightPrepared,
      identical: summary.change === 0 && summary.insert === 0 && summary.delete === 0
    };
  }

  function createCell(className, text) {
    const cell = document.createElement('td');
    if (className) {
      cell.className = className;
    }
    if (text !== undefined && text !== null) {
      cell.textContent = String(text);
    }
    return cell;
  }

  function appendSegments(cell, segments, type) {
    segments.forEach(function (segment) {
      if (!segment.changed) {
        cell.appendChild(document.createTextNode(segment.text));
        return;
      }
      const span = document.createElement('span');
      span.className = type === 'delete' ? 'configdiff-inline-delete' : 'configdiff-inline-insert';
      span.textContent = segment.text;
      cell.appendChild(span);
    });
  }

  function addCommentClass(cell, line) {
    if (line && line.comment) {
      cell.classList.add('configdiff-comment');
    }
  }

  function markerFor(type) {
    if (type === 'change') return '≠';
    if (type === 'delete') return '−';
    if (type === 'insert') return '+';
    return '';
  }

  function renderSideRows(body, rows) {
    const fragment = document.createDocumentFragment();
    let changeIndex = 0;

    rows.forEach(function (row) {
      const tr = document.createElement('tr');
      tr.className = 'configdiff-row-' + row.type;

      if (row.type !== 'equal') {
        tr.dataset.changeIndex = String(changeIndex);
        changeIndex += 1;
      }

      tr.appendChild(createCell('configdiff-line-number', row.left ? row.left.number : ''));

      const leftCode = createCell('configdiff-code configdiff-left-code');
      addCommentClass(leftCode, row.left);
      if (row.left) {
        if (row.type === 'change' && row.inline) {
          appendSegments(leftCode, row.inline.left, 'delete');
        } else {
          leftCode.textContent = row.left.raw;
        }
      }
      tr.appendChild(leftCode);

      tr.appendChild(createCell('configdiff-marker', markerFor(row.type)));
      tr.appendChild(createCell('configdiff-line-number', row.right ? row.right.number : ''));

      const rightCode = createCell('configdiff-code configdiff-right-code');
      addCommentClass(rightCode, row.right);
      if (row.right) {
        if (row.type === 'change' && row.inline) {
          appendSegments(rightCode, row.inline.right, 'insert');
        } else {
          rightCode.textContent = row.right.raw;
        }
      }
      tr.appendChild(rightCode);
      fragment.appendChild(tr);
    });

    body.replaceChildren(fragment);
  }

  function appendUnifiedRow(fragment, type, leftLine, rightLine, marker, line, segments, segmentType, extraClass) {
    const tr = document.createElement('tr');
    tr.className = 'configdiff-row-' + type + (extraClass ? ' ' + extraClass : '');
    tr.appendChild(createCell('configdiff-line-number', leftLine || ''));
    tr.appendChild(createCell('configdiff-line-number', rightLine || ''));
    tr.appendChild(createCell('configdiff-marker', marker));
    const code = createCell('configdiff-code');
    addCommentClass(code, line);

    if (segments) {
      appendSegments(code, segments, segmentType);
    } else if (line) {
      code.textContent = line.raw;
    }

    tr.appendChild(code);
    fragment.appendChild(tr);
  }

  function renderUnifiedRows(body, rows) {
    const fragment = document.createDocumentFragment();
    let changeIndex = 0;

    rows.forEach(function (row) {
      if (row.type === 'equal') {
        appendUnifiedRow(fragment, 'equal', row.left.number, row.right.number, ' ', row.left);
        return;
      }

      const anchor = changeIndex;
      changeIndex += 1;
      let firstRow = null;

      if (row.type === 'delete') {
        appendUnifiedRow(fragment, 'delete', row.left.number, '', '−', row.left);
        firstRow = fragment.lastChild;
      } else if (row.type === 'insert') {
        appendUnifiedRow(fragment, 'insert', '', row.right.number, '+', row.right);
        firstRow = fragment.lastChild;
      } else {
        appendUnifiedRow(
          fragment,
          'change',
          row.left.number,
          '',
          '−',
          row.left,
          row.inline ? row.inline.left : null,
          'delete',
          'configdiff-unified-delete'
        );
        firstRow = fragment.lastChild;
        appendUnifiedRow(
          fragment,
          'change',
          '',
          row.right.number,
          '+',
          row.right,
          row.inline ? row.inline.right : null,
          'insert',
          'configdiff-unified-insert'
        );
      }

      if (firstRow) {
        firstRow.dataset.changeIndex = String(anchor);
      }
    });

    body.replaceChildren(fragment);
  }

  function unifiedDiffText(result, leftName, rightName) {
    const output = [];
    output.push('--- ' + leftName);
    output.push('+++ ' + rightName);

    result.rows.forEach(function (row) {
      if (row.type === 'equal') {
        output.push(' ' + row.left.raw);
      } else if (row.type === 'delete') {
        output.push('-' + row.left.raw);
      } else if (row.type === 'insert') {
        output.push('+' + row.right.raw);
      } else {
        output.push('-' + row.left.raw);
        output.push('+' + row.right.raw);
      }
    });

    return output.join('\n') + '\n';
  }

  function safeFileName(value) {
    const name = String(value || 'config-diff')
      .trim()
      .replace(/[^A-Za-z0-9._-]+/g, '_')
      .replace(/^_+|_+$/g, '');
    return name || 'config-diff';
  }

  function inputMeta(text) {
    const value = normalizeText(text);
    const lines = value === '' ? 0 : value.split('\n').length;
    return lines.toLocaleString('de-CH') + ' Zeilen · ' + value.length.toLocaleString('de-CH') + ' Zeichen';
  }

  function init(doc) {
    const elements = {
      left: doc.getElementById('configdiffLeft'),
      right: doc.getElementById('configdiffRight'),
      leftName: doc.getElementById('configdiffLeftName'),
      rightName: doc.getElementById('configdiffRightName'),
      leftMeta: doc.getElementById('configdiffLeftMeta'),
      rightMeta: doc.getElementById('configdiffRightMeta'),
      compare: doc.getElementById('configdiffCompare'),
      swap: doc.getElementById('configdiffSwap'),
      clear: doc.getElementById('configdiffClear'),
      previous: doc.getElementById('configdiffPrevious'),
      next: doc.getElementById('configdiffNext'),
      exportButton: doc.getElementById('configdiffExport'),
      message: doc.getElementById('configdiffMessage'),
      summary: doc.getElementById('configdiffSummary'),
      empty: doc.getElementById('configdiffEmpty'),
      busy: doc.getElementById('configdiffBusy'),
      sideContainer: doc.getElementById('configdiffSideContainer'),
      unifiedContainer: doc.getElementById('configdiffUnifiedContainer'),
      sideBody: doc.getElementById('configdiffSideBody'),
      unifiedBody: doc.getElementById('configdiffUnifiedBody'),
      leftHeader: doc.getElementById('configdiffLeftHeader'),
      rightHeader: doc.getElementById('configdiffRightHeader'),
      sideView: doc.getElementById('configdiffSideView'),
      unifiedView: doc.getElementById('configdiffUnifiedView'),
      ignoreWhitespace: doc.getElementById('configdiffIgnoreWhitespace'),
      ignoreBlankLines: doc.getElementById('configdiffIgnoreBlankLines'),
      ignoreCase: doc.getElementById('configdiffIgnoreCase'),
      ignoreComments: doc.getElementById('configdiffIgnoreComments'),
      leftServer: doc.getElementById('configdiffLeftServer'),
      rightServer: doc.getElementById('configdiffRightServer'),
      leftConfig: doc.getElementById('configdiffLeftConfig'),
      rightConfig: doc.getElementById('configdiffRightConfig'),
      loadLeft: doc.getElementById('configdiffLoadLeft'),
      loadRight: doc.getElementById('configdiffLoadRight')
    };

    if (!elements.left || !elements.right || !elements.compare) {
      return;
    }

    let currentResult = null;
    let currentChange = -1;
    const endpoint = globalThis.CONFIGDIFF_ENDPOINT || globalThis.location.pathname;
    const servers = Array.isArray(globalThis.CONFIGDIFF_SERVERS) ? globalThis.CONFIGDIFF_SERVERS : [];

    function fillServerSelect(select, preferredIndex) {
      if (!select) return;
      select.replaceChildren();
      servers.forEach(function (server) {
        const option = doc.createElement('option');
        option.value = String(server.idx);
        option.textContent = String(server.name || ('Server ' + server.idx));
        select.appendChild(option);
      });
      if (servers.length > 0) {
        select.value = String(servers[Math.min(preferredIndex, servers.length - 1)].idx);
      }
    }

    async function requestJson(params) {
      const url = new URL(endpoint, globalThis.location.href);
      Object.keys(params).forEach(function (key) { url.searchParams.set(key, String(params[key])); });
      const response = await fetch(url.toString(), {
        method: 'GET',
        headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
        credentials: 'same-origin',
        cache: 'no-store'
      });
      const data = await response.json().catch(function () { return null; });
      if (!response.ok || !data || data.ok !== true) {
        throw new Error(data && data.error ? data.error : ('HTTP ' + response.status));
      }
      return data;
    }

    async function loadConfigList(serverSelect, configSelect) {
      if (!serverSelect || !configSelect || serverSelect.value === '') return;
      configSelect.disabled = true;
      configSelect.innerHTML = '<option value="">Dateien werden geladen …</option>';
      try {
        const data = await requestJson({ api: 'configs', server_idx: serverSelect.value });
        configSelect.replaceChildren();
        const empty = doc.createElement('option');
        empty.value = '';
        empty.textContent = 'Datei wählen …';
        configSelect.appendChild(empty);
        data.configs.forEach(function (item) {
          const option = doc.createElement('option');
          option.value = item.id;
          option.textContent = item.category ? (item.label + ' [' + item.category + ']') : item.label;
          configSelect.appendChild(option);
        });
      } catch (error) {
        configSelect.innerHTML = '<option value="">Laden fehlgeschlagen</option>';
        showMessage('danger', error instanceof Error ? error.message : 'Dateiliste konnte nicht geladen werden.');
      } finally {
        configSelect.disabled = false;
      }
    }

    async function loadRemote(side) {
      const isLeft = side === 'left';
      const serverSelect = isLeft ? elements.leftServer : elements.rightServer;
      const configSelect = isLeft ? elements.leftConfig : elements.rightConfig;
      const target = isLeft ? elements.left : elements.right;
      const name = isLeft ? elements.leftName : elements.rightName;
      const button = isLeft ? elements.loadLeft : elements.loadRight;
      if (!serverSelect || !configSelect || !configSelect.value) {
        showMessage('warning', 'Bitte zuerst einen Server und eine Datei auswählen.');
        return;
      }
      button.disabled = true;
      hideMessage();
      try {
        const data = await requestJson({ api: 'content', server_idx: serverSelect.value, config_id: configSelect.value });
        target.value = data.content || '';
        name.value = (data.server_name || 'Server') + ': ' + (data.config_id || configSelect.value);
        sourceChanged();
      } catch (error) {
        showMessage('danger', error instanceof Error ? error.message : 'Datei konnte nicht geladen werden.');
      } finally {
        button.disabled = false;
      }
    }

    function options() {
      return {
        ignoreWhitespace: elements.ignoreWhitespace.checked,
        ignoreBlankLines: elements.ignoreBlankLines.checked,
        ignoreCase: elements.ignoreCase.checked,
        ignoreComments: elements.ignoreComments.checked
      };
    }

    function updateMeta() {
      elements.leftMeta.textContent = inputMeta(elements.left.value);
      elements.rightMeta.textContent = inputMeta(elements.right.value);
    }

    function hideMessage() {
      elements.message.className = 'alert d-none';
      elements.message.textContent = '';
    }

    function showMessage(type, text) {
      elements.message.className = 'alert alert-' + type;
      elements.message.textContent = text;
    }

    function setBusy(value) {
      elements.compare.disabled = value;
      elements.busy.classList.toggle('d-none', !value);
      if (value) {
        elements.empty.classList.add('d-none');
        elements.sideContainer.classList.add('d-none');
        elements.unifiedContainer.classList.add('d-none');
      }
    }

    function selectedView() {
      return elements.unifiedView.checked ? 'unified' : 'side';
    }

    function applyView() {
      const hasResult = currentResult !== null;
      const side = selectedView() === 'side';
      elements.sideContainer.classList.toggle('d-none', !hasResult || !side);
      elements.unifiedContainer.classList.toggle('d-none', !hasResult || side);
    }

    function updateSummary(result) {
      const summary = result.summary;
      const badges = [];

      function badge(label, value, style) {
        const span = doc.createElement('span');
        span.className = 'badge text-bg-' + style;
        span.textContent = label + ': ' + value.toLocaleString('de-CH');
        badges.push(span);
      }

      if (result.identical) {
        badge('Identisch', summary.equal, 'success');
      } else {
        badge('Geändert', summary.change, 'warning');
        badge('Nur links', summary.delete, 'danger');
        badge('Nur rechts', summary.insert, 'success');
        badge('Unverändert', summary.equal, 'secondary');
      }

      if (summary.ignoredBlank > 0) {
        badge('Ignorierte Leerzeilen', summary.ignoredBlank, 'info');
      }
      if (summary.ignoredComments > 0) {
        badge('Ignorierte Kommentare', summary.ignoredComments, 'info');
      }

      elements.summary.replaceChildren.apply(elements.summary, badges);
    }

    function changeRowsForCurrentView() {
      const container = selectedView() === 'side' ? elements.sideBody : elements.unifiedBody;
      return Array.from(container.querySelectorAll('tr[data-change-index]'));
    }

    function clearCurrentHighlight() {
      doc.querySelectorAll('.configdiff-current-change').forEach(function (row) {
        row.classList.remove('configdiff-current-change');
      });
    }

    function focusChange(index) {
      const rows = changeRowsForCurrentView();
      if (rows.length === 0) {
        currentChange = -1;
        return;
      }

      currentChange = ((index % rows.length) + rows.length) % rows.length;
      clearCurrentHighlight();
      const row = rows[currentChange];
      row.classList.add('configdiff-current-change');

      if (selectedView() === 'unified') {
        const next = row.nextElementSibling;
        if (next && next.classList.contains('configdiff-unified-insert')) {
          next.classList.add('configdiff-current-change');
        }
      }

      row.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }

    function runComparison() {
      hideMessage();
      setBusy(true);

      globalThis.setTimeout(function () {
        try {
          currentResult = calculateDiff(elements.left.value, elements.right.value, options());
          currentChange = -1;

          renderSideRows(elements.sideBody, currentResult.rows);
          renderUnifiedRows(elements.unifiedBody, currentResult.rows);

          elements.leftHeader.textContent = elements.leftName.value.trim() || 'Konfiguration A';
          elements.rightHeader.textContent = elements.rightName.value.trim() || 'Konfiguration B';
          updateSummary(currentResult);

          const changes = currentResult.summary.change + currentResult.summary.delete + currentResult.summary.insert;
          elements.previous.disabled = changes === 0;
          elements.next.disabled = changes === 0;
          elements.exportButton.disabled = false;
          elements.empty.classList.add('d-none');
          applyView();

          if (currentResult.identical) {
            showMessage('success', 'Die beiden Konfigurationen sind mit den gewählten Optionen identisch.');
          }
        } catch (error) {
          currentResult = null;
          elements.previous.disabled = true;
          elements.next.disabled = true;
          elements.exportButton.disabled = true;
          elements.summary.innerHTML = '<span class="badge text-bg-danger">Vergleich fehlgeschlagen</span>';
          elements.empty.classList.remove('d-none');
          showMessage('danger', error instanceof Error ? error.message : 'Der Vergleich konnte nicht durchgeführt werden.');
        } finally {
          setBusy(false);
          applyView();
        }
      }, 20);
    }

    function resetResult() {
      currentResult = null;
      currentChange = -1;
      elements.sideBody.replaceChildren();
      elements.unifiedBody.replaceChildren();
      elements.sideContainer.classList.add('d-none');
      elements.unifiedContainer.classList.add('d-none');
      elements.empty.classList.remove('d-none');
      elements.summary.innerHTML = '<span class="badge text-bg-secondary">Noch kein Vergleich</span>';
      elements.previous.disabled = true;
      elements.next.disabled = true;
      elements.exportButton.disabled = true;
      hideMessage();
    }

    function sourceChanged() {
      updateMeta();
      if (currentResult) {
        resetResult();
      }
    }

    elements.left.addEventListener('input', sourceChanged);
    elements.right.addEventListener('input', sourceChanged);
    elements.compare.addEventListener('click', runComparison);

    if (elements.leftServer && elements.rightServer) {
      fillServerSelect(elements.leftServer, 0);
      fillServerSelect(elements.rightServer, servers.length > 1 ? 1 : 0);
      loadConfigList(elements.leftServer, elements.leftConfig);
      loadConfigList(elements.rightServer, elements.rightConfig);
      elements.leftServer.addEventListener('change', function () { loadConfigList(elements.leftServer, elements.leftConfig); });
      elements.rightServer.addEventListener('change', function () { loadConfigList(elements.rightServer, elements.rightConfig); });
      elements.loadLeft.addEventListener('click', function () { loadRemote('left'); });
      elements.loadRight.addEventListener('click', function () { loadRemote('right'); });
    }

    [elements.left, elements.right].forEach(function (input) {
      input.addEventListener('keydown', function (event) {
        if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
          event.preventDefault();
          runComparison();
        }
      });
    });

    elements.swap.addEventListener('click', function () {
      const leftValue = elements.left.value;
      const leftName = elements.leftName.value;
      const leftServerValue = elements.leftServer ? elements.leftServer.value : '';
      const leftConfigValue = elements.leftConfig ? elements.leftConfig.value : '';
      elements.left.value = elements.right.value;
      elements.leftName.value = elements.rightName.value;
      elements.right.value = leftValue;
      elements.rightName.value = leftName;
      if (elements.leftServer && elements.rightServer) {
        const rightServerValue = elements.rightServer.value;
        const rightConfigValue = elements.rightConfig.value;
        elements.leftServer.value = rightServerValue;
        elements.rightServer.value = leftServerValue;
        Promise.all([
          loadConfigList(elements.leftServer, elements.leftConfig),
          loadConfigList(elements.rightServer, elements.rightConfig)
        ]).then(function () {
          elements.leftConfig.value = rightConfigValue;
          elements.rightConfig.value = leftConfigValue;
        });
      }
      updateMeta();
      if (currentResult) {
        runComparison();
      }
    });

    elements.clear.addEventListener('click', function () {
      elements.left.value = '';
      elements.right.value = '';
      updateMeta();
      resetResult();
      elements.left.focus();
    });

    elements.previous.addEventListener('click', function () {
      focusChange(currentChange - 1);
    });

    elements.next.addEventListener('click', function () {
      focusChange(currentChange + 1);
    });

    elements.sideView.addEventListener('change', function () {
      applyView();
      clearCurrentHighlight();
      currentChange = -1;
    });

    elements.unifiedView.addEventListener('change', function () {
      applyView();
      clearCurrentHighlight();
      currentChange = -1;
    });

    elements.exportButton.addEventListener('click', function () {
      if (!currentResult) {
        return;
      }
      const leftName = elements.leftName.value.trim() || 'config-a';
      const rightName = elements.rightName.value.trim() || 'config-b';
      const content = unifiedDiffText(currentResult, leftName, rightName);
      const blob = new Blob([content], { type: 'text/x-diff;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const link = doc.createElement('a');
      link.href = url;
      link.download = safeFileName(leftName + '_vs_' + rightName) + '.diff';
      doc.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    });

    [
      elements.ignoreWhitespace,
      elements.ignoreBlankLines,
      elements.ignoreCase,
      elements.ignoreComments
    ].forEach(function (input) {
      input.addEventListener('change', function () {
        if (currentResult) {
          runComparison();
        }
      });
    });

    updateMeta();
  }

  return {
    MAX_BYTES: MAX_BYTES,
    MAX_LINES: MAX_LINES,
    MAX_EDIT_DISTANCE: MAX_EDIT_DISTANCE,
    normalizeText: normalizeText,
    isCommentLine: isCommentLine,
    prepareLines: prepareLines,
    myersDiff: myersDiff,
    alignOperations: alignOperations,
    inlineSegments: inlineSegments,
    calculateDiff: calculateDiff,
    unifiedDiffText: unifiedDiffText,
    init: init
  };
}));
