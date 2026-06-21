// k6 step-load profiler — drives each app endpoint with rising RPS.
// Stages climb in steps so the collector can join (timestamp → RPS bucket → pod count).
//
// Run:  k6 run -e BASE=http://<endpoint> -e PROFILE=short profile.js --out json=out/k6.json
//
// PROFILE=short  : ~5min  (smoke / pipeline check)
// PROFILE=full   : ~25min (real capacity profiling)

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';

const BASE    = __ENV.BASE    || 'http://localhost:8080';
const PROFILE = __ENV.PROFILE || 'short';

const userLat    = new Trend('lat_user',    true);
const productLat = new Trend('lat_product', true);
const stressLat  = new Trend('lat_stress',  true);
const errs       = new Counter('app_errors');

const STAGES_SHORT = [
  { duration: '30s', target: 20  },
  { duration: '1m',  target: 50  },
  { duration: '1m',  target: 100 },
  { duration: '1m',  target: 200 },
  { duration: '1m',  target: 400 },
  { duration: '30s', target: 0   },
];

const STAGES_FULL = [
  { duration: '2m', target: 50   },
  { duration: '3m', target: 100  },
  { duration: '3m', target: 200  },
  { duration: '3m', target: 400  },
  { duration: '3m', target: 700  },
  { duration: '3m', target: 1000 },
  { duration: '3m', target: 1500 },
  { duration: '3m', target: 0    },
];

export const options = {
  scenarios: {
    mix: {
      executor: 'ramping-arrival-rate',
      startRate: 5,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 1500,
      stages: PROFILE === 'full' ? STAGES_FULL : STAGES_SHORT,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.10'],
    lat_user:    ['p(95)<2000'],
    lat_product: ['p(95)<2000'],
    lat_stress:  ['p(95)<5000'],
  },
  discardResponseBodies: true,
};

// hot id pool — product GET hits same 20 ids so cache effect is visible
const HOT_IDS = Array.from({ length: 20 }, (_, i) => `hot-${i}`);
let warmed = false;

function warmup() {
  if (warmed) return;
  warmed = true;
  for (const id of HOT_IDS) {
    http.post(`${BASE}/v1/product`,
      JSON.stringify({ id, name: 'preset', price: 1000 }),
      { headers: { 'Content-Type': 'application/json' } });
  }
}

export default function () {
  warmup();
  const r = Math.random();

  if (r < 0.50) {
    // 50% product GET (cache-friendly)
    const id = HOT_IDS[Math.floor(Math.random() * HOT_IDS.length)];
    const res = http.get(`${BASE}/v1/product?id=${id}`, { tags: { app: 'product' } });
    productLat.add(res.timings.duration);
    if (!check(res, { 'product 2xx': r => r.status >= 200 && r.status < 300 })) errs.add(1);

  } else if (r < 0.85) {
    // 35% user POST + GET
    const u = uuidv4();
    const email = `u${u.slice(0, 8)}@k6.local`;
    const rid = uuidv4();
    const post = http.post(`${BASE}/v1/user`,
      JSON.stringify({ requestid: rid, uuid: u, username: u.slice(0, 8), email }),
      { headers: { 'Content-Type': 'application/json' }, tags: { app: 'user' } });
    userLat.add(post.timings.duration);
    if (!check(post, { 'user 2xx': r => r.status < 300 })) errs.add(1);

    const get = http.get(`${BASE}/v1/user?email=${encodeURIComponent(email)}&requestid=${rid}&uuid=${u}`,
      { tags: { app: 'user' } });
    userLat.add(get.timings.duration);
    if (!check(get, { 'user GET 2xx': r => r.status < 300 })) errs.add(1);

  } else {
    // 15% stress (CPU bound, low share)
    const res = http.post(`${BASE}/v1/stress`,
      JSON.stringify({ length: 100 }),
      { headers: { 'Content-Type': 'application/json' }, tags: { app: 'stress' } });
    stressLat.add(res.timings.duration);
    if (!check(res, { 'stress 2xx': r => r.status < 300 })) errs.add(1);
  }
}
