import 'dart:convert';

/// Page-side extractor injected into the education-system WebView.
///
/// The script runs inside the already logged-in page, so every `fetch` /
/// jQuery request reuses the user's campus cookies. It has exactly one sink:
/// the `CoursePlannerBridge.onExtracted` Java interface registered by the
/// native activity. Nothing is uploaded anywhere.
///
/// Capabilities:
///  * vendor fingerprints plus active pulls for Zhengfang (`kbcx/xskbcx_*`),
///    Qiangzhi Vue (`div.el-table.__vue__.data`), Shuwei/EAMS (`print-data` /
///    `get-data`) and Jinzhi WIS (`getMyScheduleDetail.do`);
///  * recursive traversal of every same-origin `iframe` / `frame`;
///  * `findTables` / `getWeight` / `compressHtml`, ported from the
///    reverse-engineered production parser, which selects the single most
///    timetable-like `<table>` and strips it down to `class` / `title` /
///    `rowspan` / `colspan`;
///  * a plain-text fallback (`bestTableHtml` then carries `body.innerText`)
///    when the page renders its timetable with `<div>`s instead of a table.
///
/// Payload delivered to the bridge:
/// `{status, pageUrl, schoolName, vendor, dataJson, extractedData, rawHtml,
/// bestTableHtml, pageText, message}`.
const String webviewExtractorScript = r'''(function () {
  'use strict';

  var HINT = window.__CP_EDU_HINT__ || {};
  var MAX_RAW_HTML = 400000;
  var MAX_TABLE_HTML = 60000;
  var MAX_DATA = 400000;
  var MAX_TEXT = 12000;
  var MAX_MESSAGE = 300;

  function safeString(value) {
    if (value === null || value === undefined) return '';
    try {
      return String(value);
    } catch (e) {
      return '';
    }
  }

  function safeUrl() {
    try {
      return safeString(window.location.href);
    } catch (e) {
      return '';
    }
  }

  function safePath() {
    try {
      return safeString(window.location.pathname);
    } catch (e) {
      return '';
    }
  }

  function truncate(text, limit) {
    var value = safeString(text);
    return value.length > limit ? value.slice(0, limit) : value;
  }

  function jsonText(value) {
    try {
      var text = JSON.stringify(value);
      return typeof text === 'string' ? text : '';
    } catch (e) {
      return '';
    }
  }

  function toAbsolute(raw) {
    try {
      return new URL(raw, window.location.href).href;
    } catch (e) {
      return raw;
    }
  }

  function formBody(params) {
    var parts = [];
    Object.keys(params).forEach(function (key) {
      var value = params[key];
      var text = value === null || value === undefined ? '' : String(value);
      parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(text));
    });
    return parts.join('&');
  }

  function fetchText(url, options) {
    return fetch(url, options).then(function (response) {
      if (!response || !response.ok) {
        throw new Error('HTTP ' + (response ? response.status : 0));
      }
      return response.text();
    });
  }

  function parseJsonText(text) {
    var raw = safeString(text).trim();
    if (!raw) return null;
    if (raw.charAt(0) === '<') return null;
    try {
      return JSON.parse(raw);
    } catch (e) {
      return null;
    }
  }

  function ajaxRequest(options) {
    return new Promise(function (resolve, reject) {
      var jq = window.jQuery || window.$;
      if (!jq || typeof jq.ajax !== 'function') {
        reject(new Error('jquery is not available'));
        return;
      }
      jq.ajax(options)
        .done(function (data) {
          resolve(data);
        })
        .fail(function (xhr, statusText) {
          reject(new Error('jquery request failed: ' + safeString(statusText)));
        });
    });
  }

  // ---- document traversal -------------------------------------------------

  function collectDocuments() {
    var list = [];

    function visit(doc, depth) {
      if (!doc || depth > 4 || list.length >= 24) return;
      if (!doc.documentElement) return;
      list.push(doc);
      var frames = [];
      try {
        frames = doc.querySelectorAll('iframe,frame');
      } catch (e) {
        frames = [];
      }
      for (var i = 0; i < frames.length; i++) {
        var child = null;
        try {
          child = frames[i].contentDocument;
        } catch (e) {
          child = null;
        }
        if (child) visit(child, depth + 1);
      }
    }

    try {
      visit(document, 0);
    } catch (e) {
      // Keep whatever was collected before the failure.
    }
    if (list.length === 0) list.push(document);
    return list;
  }

  function findField(docs, selector) {
    for (var i = 0; i < docs.length; i++) {
      var element = null;
      try {
        element = docs[i].querySelector(selector);
      } catch (e) {
        element = null;
      }
      if (element) return element;
    }
    return null;
  }

  function frameWindow(doc) {
    try {
      return doc.defaultView;
    } catch (e) {
      return null;
    }
  }

  // ---- table scoring (ported from the production AI parser) ---------------

  function findTables(doc) {
    var found = [];
    var tables = [];
    try {
      tables = doc.querySelectorAll('table');
    } catch (e) {
      tables = [];
    }
    if (!tables || tables.length === 0) return found;

    for (var i = 0; i < tables.length; i++) {
      var table = tables[i];
      if (table.offsetWidth === 0) continue;
      var rows = table.querySelectorAll('tr');
      if (!rows || rows.length < 2) continue;
      var columnCount = 0;
      for (var r = 0; r < rows.length; r++) {
        var cells = rows[r].cells || [];
        var width = 0;
        for (var c = 0; c < cells.length; c++) {
          width += cells[c].colSpan || 1;
        }
        if (width > columnCount) columnCount = width;
      }
      if (columnCount < 4) continue;
      found.push({ tableEl: table, weight: getWeight(table, columnCount) });
    }
    return found;
  }

  function getWeight(table, columnCount) {
    var weight = [0, 0, 0, 0, 0, 0];
    var rows = table.querySelectorAll('tr');
    var cells = table.querySelectorAll('td,th');
    if (rows.length >= 2 && columnCount >= 4) weight[3] = 1;

    var keywords = [/课程/, /教师|老师|教授/, /地点|教室|楼|校区/, /周|星期/, /节次/];
    var hits = 0;
    for (var i = 0; i < cells.length; i++) {
      var cellText = cells[i].textContent || '';
      for (var k = 0; k < keywords.length; k++) {
        if (new RegExp(keywords[k]).test(cellText)) hits++;
      }
    }
    if (hits > 0) weight[2] = Math.min(hits, 6);

    var header = table.querySelector('thead tr') || table.querySelector('tr');
    var headerHits = 0;
    if (header) {
      var headerCells = header.querySelectorAll('th,td');
      for (var h = 0; h < headerCells.length; h++) {
        var headerText = headerCells[h].textContent || '';
        for (var hk = 0; hk < keywords.length; hk++) {
          if (new RegExp(keywords[hk]).test(headerText)) headerHits++;
        }
      }
    }
    if (headerHits > 0) weight[1] = Math.min(headerHits, 6);

    var hasWeekdays = false;
    var hasPeriods = false;
    if (header) {
      var labels = header.querySelectorAll('th,td');
      var weekdayCount = 0;
      for (var l = 0; l < labels.length; l++) {
        var label = labels[l].textContent || '';
        if (/星期[一二三四五六日天1234567]/.test(label)) weekdayCount++;
      }
      if (weekdayCount >= 3) hasWeekdays = true;
    }

    var periodRows = 0;
    for (var pr = 0; pr < rows.length; pr++) {
      var firstCell = rows[pr].querySelector('th,td');
      if (!firstCell) continue;
      var firstText = firstCell.textContent || '';
      if (
        /节次|节|周\/?节/.test(firstText) ||
        /^[一二三四五六七八九十1234567890]+节/.test(firstText) ||
        /\d{1,2}[：:]\d{2}\s*[-~—至]\s*\d{1,2}[：:]\d{2}/.test(firstText) ||
        /上午|下午|晚上/.test(firstText)
      ) {
        periodRows++;
      }
    }
    if (periodRows >= Math.floor(rows.length / 2)) hasPeriods = true;
    if (hasWeekdays || hasPeriods) weight[0] = 1;

    var bodyCells = 0;
    var filledCells = 0;
    for (var br = 0; br < rows.length; br++) {
      if (br === 0) continue;
      var bodyRow = rows[br].querySelectorAll('td,th');
      for (var bc = 0; bc < bodyRow.length; bc++) {
        if (bc === 0) continue;
        bodyCells++;
        if ((bodyRow[bc].textContent || '').trim().length > 0) filledCells++;
      }
    }
    if (bodyCells > 0 && filledCells / bodyCells < 0.05) return '000000';

    return weight.join('');
  }

  function compressHtml(html) {
    var cleaned = safeString(html)
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<svg[\s\S]*?<\/svg>/gi, '')
      .replace(/<!--[\s\S]*?-->/g, '');

    return cleaned.replace(/<(\w+)([^>]*)>/g, function (match, tag, attrs) {
      var kept = '';
      var classMatch = attrs.match(/class\s*=\s*(["'][^"']*["'])/);
      var titleMatch = attrs.match(/title\s*=\s*(["'][^"']*["'])/);
      var rowspanMatch = attrs.match(/rowspan\s*=\s*(["'][^"']*["'])/);
      var colspanMatch = attrs.match(/colspan\s*=\s*(["'][^"']*["'])/);
      if (classMatch) kept += ' class=' + classMatch[1];
      if (titleMatch) kept += ' title=' + titleMatch[1];
      if (rowspanMatch) kept += ' rowspan=' + rowspanMatch[1];
      if (colspanMatch) kept += ' colspan=' + colspanMatch[1];
      return '<' + tag + kept + '>';
    });
  }

  function chooseTable(docs) {
    var candidates = [];
    for (var i = 0; i < docs.length; i++) {
      var found = findTables(docs[i]);
      for (var f = 0; f < found.length; f++) candidates.push(found[f]);
    }
    if (candidates.length === 0) return null;
    candidates.sort(function (left, right) {
      if (left.weight === right.weight) return 0;
      return left.weight < right.weight ? 1 : -1;
    });
    return candidates[0];
  }

  // ---- vendor fingerprints and active pulls ------------------------------

  function looksLikeZf(docs) {
    if (findField(docs, 'meta[content="zfsoft"]')) return true;
    return !!(findField(docs, '#xnm') && findField(docs, '#xqm'));
  }

  function zfBasePath() {
    var path = safePath();
    var markers = ['/kbcx/', '/xsxxx/'];
    for (var i = 0; i < markers.length; i++) {
      var index = path.indexOf(markers[i]);
      if (index >= 0) return path.slice(0, index);
    }
    if (path.indexOf('/jwglxt') === 0) return '/jwglxt';
    return '';
  }

  async function pullZf(docs) {
    var xnmField = findField(docs, '#xnm');
    var xqmField = findField(docs, '#xqm');
    var xsdmField = findField(docs, '#xsdm') || findField(docs, 'input[name="xsdm"]');
    var params = {
      xnm: xnmField ? xnmField.value : '',
      xqm: xqmField ? xqmField.value : '',
      xsdm: xsdmField ? xsdmField.value : '',
      kzlx: 'ck'
    };
    var url = toAbsolute(zfBasePath() + '/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151');
    var text = '';
    try {
      text = await fetchText(url, {
        method: 'POST',
        credentials: 'include',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: formBody(params)
      });
    } catch (fetchError) {
      try {
        text = await ajaxRequest({
          url: url,
          type: 'POST',
          dataType: 'json',
          data: params,
          xhrFields: { withCredentials: true }
        });
      } catch (ajaxError) {
        return '';
      }
    }
    var payload = typeof text === 'string' ? parseJsonText(text) : text;
    if (!payload) return '';
    if (payload.kbList || payload.sjkList || payload.xsxxkg) return jsonText(payload);
    return '';
  }

  function readVueTableData(element) {
    var sources = [];
    var vm = null;
    try {
      vm = element.__vue__;
    } catch (e) {
      vm = null;
    }
    if (vm) sources.push(vm.data, vm.tableData, vm.list, vm.rows);

    var parent = null;
    try {
      parent = element.__vueParentComponent;
    } catch (e) {
      parent = null;
    }
    if (parent) {
      var proxy = parent.proxy || parent.ctx || null;
      if (proxy) sources.push(proxy.data, proxy.tableData, proxy.list, proxy.rows);
    }

    for (var i = 0; i < sources.length; i++) {
      var candidate = sources[i];
      if (Array.isArray(candidate) && candidate.length > 0) return candidate;
      if (candidate && Array.isArray(candidate.data) && candidate.data.length > 0) {
        return candidate.data;
      }
      if (candidate && Array.isArray(candidate.rows) && candidate.rows.length > 0) {
        return candidate.rows;
      }
    }
    return null;
  }

  function pullQzVue(docs) {
    for (var i = 0; i < docs.length; i++) {
      var tables = [];
      try {
        tables = docs[i].querySelectorAll('div.el-table');
      } catch (e) {
        tables = [];
      }
      for (var t = 0; t < tables.length; t++) {
        var data = readVueTableData(tables[t]);
        if (data) return jsonText(data);
      }
    }
    return '';
  }

  function looksLikeShuwei(docs) {
    if (safePath().indexOf('/for-std/course-table') >= 0) return true;
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      if (win && (win.CONTEXT_PATH !== undefined || win.semesters)) return true;
    }
    return false;
  }

  function shuweiContextPath(docs) {
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      if (win && typeof win.CONTEXT_PATH === 'string' && win.CONTEXT_PATH.length > 0) {
        return win.CONTEXT_PATH.replace(/\/+$/, '');
      }
    }
    var path = safePath();
    var index = path.indexOf('/for-std');
    return index > 0 ? path.slice(0, index) : '';
  }

  function shuweiSemesterId(docs) {
    var select = findField(docs, '#allSemesters');
    if (select && select.value) return safeString(select.value);
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      if (win && Array.isArray(win.semesters) && win.semesters.length > 0) {
        var first = win.semesters[0];
        if (first && first.id !== undefined && first.id !== null) {
          return safeString(first.id);
        }
      }
    }
    var match = safeUrl().match(/[?&](?:semesterId|semester)=(\d+)/);
    return match ? match[1] : '';
  }

  async function pullShuwei(docs) {
    var contextPath = shuweiContextPath(docs);
    var semesterId = shuweiSemesterId(docs);
    var urls = [];
    if (semesterId) {
      urls.push(
        contextPath + '/for-std/course-table/semester/' + semesterId +
          '/print-data?hasExperiment=true'
      );
    }
    urls.push(contextPath + '/for-std/course-table/print-data?hasExperiment=true');
    if (semesterId) {
      urls.push(
        contextPath + '/for-std/course-table/get-data?bizTypeId=2&semesterId=' + semesterId
      );
    }

    for (var i = 0; i < urls.length; i++) {
      var target = toAbsolute(urls[i]);
      var payload = null;
      try {
        payload = parseJsonText(await fetchText(target, {
          method: 'GET',
          credentials: 'include',
          headers: { 'X-Requested-With': 'XMLHttpRequest' }
        }));
      } catch (fetchError) {
        payload = null;
      }
      if (!payload) {
        try {
          payload = await ajaxRequest({
            url: target,
            type: 'GET',
            dataType: 'json',
            xhrFields: { withCredentials: true }
          });
        } catch (ajaxError) {
          payload = null;
        }
      }
      if (payload && (payload.studentTableVms || payload.lessons)) {
        return jsonText(payload);
      }
    }
    return '';
  }

  function looksLikeJinzhi(docs) {
    if (safePath().indexOf('/jwapp/sys/') >= 0) return true;
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      if (win && win.WIS_CONFIG) return true;
    }
    return false;
  }

  function jinzhiBase(docs) {
    var path = safePath();
    var index = path.indexOf('/jwapp/');
    if (index >= 0) return path.slice(0, index);
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      var service = win && win.WIS_EMAP_SERV;
      if (service && typeof service.getAbsPath === 'function') {
        try {
          return safeString(service.getAbsPath('/')).replace(/\/+$/, '');
        } catch (e) {
          // Fall through to the next frame.
        }
      }
    }
    return '';
  }

  function jinzhiTermCode(docs) {
    var select = findField(docs, '#myXnxqSelect');
    if (select && select.value) return safeString(select.value);
    try {
      var stored = window.localStorage.getItem('termCode');
      if (stored) return safeString(stored);
    } catch (e) {
      // Storage can be blocked; the empty term still lets the server fall back.
    }
    for (var i = 0; i < docs.length; i++) {
      var win = frameWindow(docs[i]);
      var config = win && win.WIS_CONFIG;
      if (!config || typeof config === 'string') continue;
      if (config.termCode) return safeString(config.termCode);
      if (config.XNXQDM) return safeString(config.XNXQDM);
    }
    return '';
  }

  async function pullJinzhi(docs) {
    var url = toAbsolute(
      jinzhiBase(docs) + '/jwapp/sys/homeapp/api/home/student/getMyScheduleDetail.do'
    );
    var params = { termCode: jinzhiTermCode(docs), type: 'term' };
    var text = '';
    try {
      text = await fetchText(url, {
        method: 'POST',
        credentials: 'include',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest'
        },
        body: formBody(params)
      });
    } catch (fetchError) {
      try {
        text = await ajaxRequest({
          url: url,
          type: 'POST',
          dataType: 'json',
          data: params,
          xhrFields: { withCredentials: true }
        });
      } catch (ajaxError) {
        return '';
      }
    }
    var payload = typeof text === 'string' ? parseJsonText(text) : text;
    if (!payload) return '';
    var detail = payload.datas || payload.data || payload;
    if (detail && detail.getMyScheduleDetail) {
      var inner = detail.getMyScheduleDetail;
      if (inner.arrangedList || inner.rows) return jsonText(payload);
    }
    if (detail && (detail.arrangedList || detail.rows)) return jsonText(payload);
    return '';
  }

  function looksLikeChaoxing() {
    var host = '';
    try {
      host = safeString(window.location.hostname);
    } catch (e) {
      host = '';
    }
    var path = safePath();
    return (
      host.indexOf('chaoxing') >= 0 ||
      path.indexOf('/pkgl/xskb/') >= 0 ||
      path.indexOf('sdpkkb') >= 0
    );
  }

  function hintVendor() {
    var hint = safeString(HINT.parserType).toLowerCase();
    if (!hint) return '';
    if (hint.indexOf('zf') >= 0 || hint.indexOf('zhengfang') >= 0) return 'zf';
    if (hint.indexOf('qz') >= 0 || hint.indexOf('qiangzhi') >= 0) return 'qz-vue';
    if (hint.indexOf('shuwei') >= 0 || hint.indexOf('eams') >= 0) return 'shuwei';
    if (hint.indexOf('jinzhi') >= 0 || hint.indexOf('wis') >= 0) return 'jinzhi';
    if (hint.indexOf('chaoxing') >= 0 || hint.indexOf('xuexitong') >= 0) {
      return 'chaoxing';
    }
    return '';
  }

  async function extractVendorData(docs) {
    var vendor = 'unknown';
    var dataJson = '';

    if (looksLikeZf(docs)) {
      vendor = 'zf';
      dataJson = await pullZf(docs);
    }
    if (!dataJson) {
      var qzData = pullQzVue(docs);
      if (qzData) {
        vendor = 'qz-vue';
        dataJson = qzData;
      }
    }
    if (!dataJson && looksLikeShuwei(docs)) {
      vendor = 'shuwei';
      dataJson = await pullShuwei(docs);
    }
    if (!dataJson && looksLikeJinzhi(docs)) {
      vendor = 'jinzhi';
      dataJson = await pullJinzhi(docs);
    }
    if (!dataJson && looksLikeChaoxing()) {
      vendor = 'chaoxing';
    }
    if (vendor === 'unknown') {
      var hinted = hintVendor();
      if (hinted) vendor = hinted;
    }
    return { vendor: vendor, dataJson: dataJson };
  }

  // ---- raw HTML and plain-text fallback ----------------------------------

  function buildRawHtml(docs) {
    var parts = [];
    var total = 0;
    for (var i = 0; i < docs.length; i++) {
      var html = '';
      try {
        var root = docs[i].documentElement;
        html = root ? safeString(root.outerHTML) : '';
      } catch (e) {
        html = '';
      }
      if (!html) continue;
      parts.push(html);
      total += html.length;
      if (total >= MAX_RAW_HTML) break;
    }
    return truncate(parts.join('\n'), MAX_RAW_HTML);
  }

  function pageText(docs) {
    for (var i = 0; i < docs.length; i++) {
      var body = null;
      try {
        body = docs[i].body;
      } catch (e) {
        body = null;
      }
      if (!body) continue;
      var text = safeString(body.innerText || body.textContent)
        .replace(/\s+/g, ' ')
        .trim();
      if (text.length > 20) return truncate(text, MAX_TEXT);
    }
    return '';
  }

  // ---- bridge delivery ----------------------------------------------------

  function deliver(payload) {
    try {
      var text = jsonText(payload);
      if (!text) return false;
      var bridge = window.CoursePlannerBridge;
      if (!bridge || typeof bridge.onExtracted !== 'function') return false;
      bridge.onExtracted(text);
      return true;
    } catch (e) {
      return false;
    }
  }

  function baseReport(status) {
    return {
      status: status,
      pageUrl: safeUrl(),
      schoolName: safeString(HINT.schoolName),
      vendor: 'unknown',
      dataJson: '',
      extractedData: '',
      rawHtml: '',
      bestTableHtml: '',
      pageText: '',
      message: ''
    };
  }

  async function run() {
    var docs = collectDocuments();
    var rawHtml = buildRawHtml(docs);

    var vendorData = { vendor: 'unknown', dataJson: '' };
    try {
      vendorData = await extractVendorData(docs);
    } catch (e) {
      vendorData = { vendor: 'unknown', dataJson: '' };
    }

    var bestTableHtml = '';
    var table = chooseTable(docs);
    if (table) {
      try {
        bestTableHtml = truncate(compressHtml(table.tableEl.outerHTML), MAX_TABLE_HTML);
      } catch (e) {
        bestTableHtml = '';
      }
    }

    var fallbackText = bestTableHtml ? '' : pageText(docs);
    var dataJson = truncate(vendorData.dataJson, MAX_DATA);

    var report = baseReport('ok');
    report.vendor = vendorData.vendor || 'unknown';
    report.dataJson = dataJson;
    report.extractedData = dataJson;
    report.rawHtml = rawHtml;
    report.bestTableHtml = bestTableHtml || fallbackText;
    report.pageText = fallbackText;
    deliver(report);
  }

  run().catch(function (error) {
    var message = '';
    try {
      message = safeString(error && error.message ? error.message : error);
    } catch (e) {
      message = '';
    }
    var report = baseReport('error');
    report.message = truncate(message, MAX_MESSAGE);
    deliver(report);
  });
})();
''';

/// Prepends the school / parser hint read by the page script as
/// `window.__CP_EDU_HINT__`, then returns the extractor.
///
/// Both values are JSON-encoded, so quotes and newlines in a school name can
/// never break out of the assignment or corrupt the IIFE that follows.
String buildWebviewExtractorScript({String? parserType, String? schoolName}) {
  final hint = <String, String>{
    'parserType': parserType?.trim() ?? '',
    'schoolName': schoolName?.trim() ?? '',
  };
  return 'window.__CP_EDU_HINT__ = ${jsonEncode(hint)};\n$webviewExtractorScript';
}
