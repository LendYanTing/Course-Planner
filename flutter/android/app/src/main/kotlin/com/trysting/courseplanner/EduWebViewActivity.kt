package com.trysting.courseplanner

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.http.SslError
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject

/**
 * Built-in education-system browser used by the "select school -> log in ->
 * extract timetable" flow.
 *
 * The activity is deliberately built from the plain Android SDK: no third-party
 * Gradle dependency, so the Flutter build stays unchanged. It exists because a
 * Flutter `WebView` plugin cannot (a) trust a campus self-signed certificate,
 * (b) keep `http://` pages usable on Android 9+, and (c) inject one large
 * extraction script into an already authenticated session without extra
 * dependencies.
 *
 * Contract:
 *  * extras in: `url`, `schoolName`, `parserType`, `desktopMode`;
 *  * extra out on `RESULT_OK`: `result` = the JSON payload produced by
 *    [WEBVIEW_EXTRACTOR_SCRIPT] and handed back through the
 *    `CoursePlannerBridge.onExtracted` JavaScript interface.
 *
 * [WEBVIEW_EXTRACTOR_SCRIPT] is a verbatim copy of
 * `flutter/lib/domain/edu_import/webview_extractor_script.dart`; the Dart copy
 * is the tested one, keep the two in sync when editing.
 */
class EduWebViewActivity : Activity() {
    private companion object {
        const val BRIDGE_NAME = "CoursePlannerBridge"
        const val EXTRA_RESULT = "result"
        const val EXTRACTION_TIMEOUT_MS = 30_000L
        const val DEFAULT_ADDRESS = "about:blank"
        const val DESKTOP_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

        // Injected page script (mirror of webview_extractor_script.dart).
        const val WEBVIEW_EXTRACTOR_SCRIPT = """(function () {
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
"""
    }

    private lateinit var webView: WebView
    private lateinit var addressBar: EditText
    private lateinit var extractButton: Button

    private val handler = Handler(Looper.getMainLooper())
    private val clearExtractingState = Runnable { setExtracting(false) }

    private var mobileUserAgent: String = ""
    private var schoolName: String = ""
    private var parserType: String = ""
    private var desktopMode: Boolean = false
    private var extracting: Boolean = false
    private var delivered: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        schoolName = intent.getStringExtra("schoolName").orEmpty()
        parserType = intent.getStringExtra("parserType").orEmpty()
        desktopMode = intent.getBooleanExtra("desktopMode", false)

        buildLayout()
        configureWebView()

        val initialUrl = normalizeUrl(intent.getStringExtra("url").orEmpty())
        if (initialUrl != null) {
            addressBar.setText(initialUrl)
            webView.loadUrl(initialUrl)
        } else {
            addressBar.requestFocus()
        }
    }

    // ---- Layout ------------------------------------------------------------

    private fun buildLayout() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }

        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            // Android 15 draws edge-to-edge, so the status bar would cover the
            // toolbar; pad it by the real inset instead of a hard-coded guess.
            setPadding(dp(6), dp(4) + systemBarInset("status_bar_height"), dp(6), dp(4))
            setBackgroundColor(Color.rgb(0xF1, 0xF3, 0xF5))
        }

        val closeButton = compactButton("关闭").apply {
            contentDescription = "关闭"
            setOnClickListener { finish() }
        }

        addressBar = EditText(this).apply {
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            imeOptions = EditorInfo.IME_ACTION_GO
            textSize = 13f
            hint = "输入教务网址"
            setTextColor(Color.rgb(0x22, 0x22, 0x22))
            setPadding(dp(10), dp(6), dp(10), dp(6))
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_GO ||
                    actionId == EditorInfo.IME_ACTION_DONE
                ) {
                    submitAddress()
                    true
                } else {
                    false
                }
            }
        }

        val refreshButton = compactButton("刷新").apply {
            contentDescription = "刷新页面"
            setOnClickListener { webView.reload() }
        }

        val desktopSwitch = Switch(this).apply {
            text = "电脑版"
            textSize = 12f
            setTextColor(Color.rgb(0x22, 0x22, 0x22))
            isChecked = desktopMode
            setOnCheckedChangeListener { _, checked -> applyDesktopMode(checked) }
        }

        toolbar.addView(closeButton)
        toolbar.addView(
            addressBar,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        toolbar.addView(refreshButton)
        toolbar.addView(desktopSwitch)

        webView = WebView(this).apply {
            setBackgroundColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            )
        }

        extractButton = Button(this).apply {
            text = "一键提取当前页课表"
            textSize = 13f
            isAllCaps = false
            minWidth = 0
            minimumWidth = 0
            setPadding(dp(14), dp(8), dp(14), dp(8))
            backgroundTintList = ColorStateList.valueOf(Color.rgb(0x2F, 0x6F, 0xED))
            setTextColor(Color.WHITE)
            setOnClickListener { extractCurrentPage() }
        }

        val bottomInset = systemBarInset("navigation_bar_height")
        val bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), dp(4), dp(8), dp(4) + bottomInset)
            setBackgroundColor(Color.rgb(0xF7, 0xF7, 0xF7))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(56) + bottomInset,
            )
        }
        val hint = TextView(this).apply {
            text = "请先登录并进入「个人课表」页面，然后点击右侧按钮 →"
            textSize = 12f
            setTextColor(Color.rgb(0x55, 0x55, 0x55))
            maxLines = 2
        }
        bottomBar.addView(
            hint,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        bottomBar.addView(extractButton)

        root.addView(
            toolbar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )
        root.addView(webView)
        root.addView(bottomBar)
        setContentView(root)
    }

    private fun compactButton(label: String): Button =
        Button(this).apply {
            text = label
            textSize = 13f
            isAllCaps = false
            minWidth = 0
            minimumWidth = 0
            setPadding(dp(10), dp(6), dp(10), dp(6))
        }

    // ---- WebView -----------------------------------------------------------

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    private fun configureWebView() {
        val settings = webView.settings
        mobileUserAgent = settings.userAgentString ?: ""

        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        @Suppress("DEPRECATION")
        settings.databaseEnabled = true
        settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
        settings.allowFileAccess = false
        settings.mediaPlaybackRequiresUserGesture = true
        settings.javaScriptCanOpenWindowsAutomatically = true
        settings.setSupportMultipleWindows(false)
        settings.loadWithOverviewMode = true
        settings.useWideViewPort = true
        settings.builtInZoomControls = true
        settings.displayZoomControls = false
        settings.setSupportZoom(true)
        if (desktopMode) settings.userAgentString = DESKTOP_USER_AGENT

        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }

        webView.addJavascriptInterface(Bridge(), BRIDGE_NAME)
        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedSslError(
                view: WebView?,
                handler: SslErrorHandler?,
                error: SslError?,
            ) {
                // Campus systems commonly ship self-signed, expired or
                // wrong-host certificates. Continuing keeps the login form
                // reachable instead of showing a blank page.
                handler?.proceed()
            }

            override fun onPageFinished(view: WebView, url: String?) {
                super.onPageFinished(view, url)
                if (!url.isNullOrBlank() && url != DEFAULT_ADDRESS) {
                    addressBar.setText(url)
                }
                CookieManager.getInstance().flush()
            }

            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                val scheme = request.url.scheme?.lowercase()
                if (scheme == "http" || scheme == "https" || scheme == "about") {
                    return false
                }
                // tel:, mailto:, weixin: ... let the system handle them.
                try {
                    startActivity(Intent(Intent.ACTION_VIEW, request.url))
                } catch (_: Exception) {
                    // No handler installed; stay on the current page.
                }
                return true
            }
        }
    }

    private fun submitAddress() {
        val url = normalizeUrl(addressBar.text?.toString().orEmpty())
        if (url == null) {
            Toast.makeText(this, "请输入教务网址", Toast.LENGTH_SHORT).show()
            return
        }
        addressBar.setText(url)
        hideKeyboard()
        webView.loadUrl(url)
    }

    /**
     * Adds `https://` to a bare host. `http://` and `https://` inputs are kept
     * verbatim (1261 schools still serve plain HTTP). Returns null when the
     * input is blank.
     */
    private fun normalizeUrl(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.contains("://")) return trimmed
        return "https://$trimmed"
    }

    private fun applyDesktopMode(enabled: Boolean) {
        desktopMode = enabled
        val settings = webView.settings
        settings.userAgentString = if (enabled) DESKTOP_USER_AGENT else mobileUserAgent
        webView.reload()
    }

    private fun hideKeyboard() {
        try {
            val manager =
                getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
            manager?.hideSoftInputFromWindow(addressBar.windowToken, 0)
        } catch (_: Exception) {
            // Keyboard already gone.
        }
    }

    // ---- Extraction --------------------------------------------------------

    private fun extractCurrentPage() {
        if (extracting) return
        if (webView.url == null) {
            Toast.makeText(this, "页面还没有加载完成", Toast.LENGTH_SHORT).show()
            return
        }
        setExtracting(true)
        handler.postDelayed(clearExtractingState, EXTRACTION_TIMEOUT_MS)
        webView.evaluateJavascript(buildExtractorScript(), null)
    }

    private fun setExtracting(active: Boolean) {
        extracting = active
        if (delivered || !::extractButton.isInitialized) return
        extractButton.isEnabled = !active
        extractButton.text = if (active) "正在提取…" else "一键提取当前页课表"
    }

    private fun buildExtractorScript(): String {
        val hint = JSONObject().apply {
            put("schoolName", schoolName)
            put("parserType", parserType)
        }
        return "window.__CP_EDU_HINT__ = " + hint.toString() + ";\n" +
            WEBVIEW_EXTRACTOR_SCRIPT
    }

    inner class Bridge {
        /**
         * Called from page JavaScript; [jsonPayload] is already a JSON string.
         * It is handed to Flutter verbatim so the Dart layer owns parsing.
         */
        @JavascriptInterface
        fun onExtracted(jsonPayload: String) {
            runOnUiThread {
                if (delivered || isFinishing) return@runOnUiThread
                delivered = true
                handler.removeCallbacks(clearExtractingState)
                setExtracting(false)
                val data = Intent().putExtra(EXTRA_RESULT, jsonPayload)
                setResult(Activity.RESULT_OK, data)
                finish()
            }
        }
    }

    // ---- Lifecycle ---------------------------------------------------------

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
            return
        }
        super.onBackPressed()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (::webView.isInitialized) {
            try {
                webView.removeJavascriptInterface(BRIDGE_NAME)
            } catch (_: Exception) {
                // Interface already detached.
            }
            try {
                webView.stopLoading()
            } catch (_: Exception) {
                // Already stopped.
            }
            try {
                (webView.parent as? ViewGroup)?.removeView(webView)
            } catch (_: Exception) {
                // Already detached.
            }
            webView.destroy()
        }
        super.onDestroy()
    }

    /// Height of a system bar (`status_bar_height`, `navigation_bar_height`),
    /// or 0 when the platform does not expose it.
    private fun systemBarInset(name: String): Int {
        val id = resources.getIdentifier(name, "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()
}
