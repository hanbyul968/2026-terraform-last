#!/usr/bin/env python3
"""
AWS WAF 로그 (CloudWatch Logs Insights) 헤더 키/값 × 엔드포인트 × action × status 통계.

Logs Insights 는 배열 explode 가 없으므로 httpRequest.headers.{i}.name/value 를
인덱스 i = 0..MAX_INDEX 까지 각각 쿼리한 뒤,
(header_key, header_value, endpoint, action, status) 기준으로 합산한다.

출력은:
  1) action(ALLOW/BLOCK) 요약
  2) ⚠ 아직 안 막힌 비정상 요청 (판정=403대상인데 WAF가 ALLOW) — '무엇을 더 막아야 하나'
  3) 정렬된 전체 표 (판정 / WAF action / status / cnt / endpoint / header)

사용 예:
  python3 waf_header_stats.py \
      --log-group aws-waf-logs-wsi2026e \
      --region us-east-1 \
      --hours 24 \
      --max-index 5 \
      --output waf_header_stats.csv

  (WAF 가 CloudFront scope 면 로그는 us-east-1)
"""
import argparse
import csv
import sys
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import boto3

QUERY_TEMPLATE = """\
fields `httpRequest.headers.{i}.name`  as header_key,
       `httpRequest.headers.{i}.value` as header_value,
       httpRequest.uri as endpoint,
       action,
       responseCodeSent as status
| filter ispresent(header_key)
| stats count(*) as cnt by header_key, header_value, endpoint, action, status
| sort cnt desc
| limit {limit}
"""

# ---- 판정 규칙 (스펙 + waf.tf/alb.tf 와 일치) ----
VALID_EP = {"/v1/user", "/v1/product", "/v1/stress", "/healthcheck"}
SCANNERS = ("sqlmap", "nikto", "nmap", "masscan", "acunetix", "havij", "attack")


def verdict(header_key, header_value, endpoint):
    """이 (헤더, 엔드포인트) 조합이 어떻게 처리돼야 하는지."""
    ep = (endpoint or "").split("?")[0]
    valid = ep in VALID_EP or ep.startswith("/images/")
    if not valid:
        return "404"          # 제공 API 외 경로 → 404 (ALB default)
    hk = (header_key or "").lower()
    hv = (header_value or "")
    if hk == "user-agent" and any(s in hv.lower() for s in SCANNERS):
        return "403-UA"       # 악성 User-Agent
    if hk == "x-forwarded-for" and "127.0.0.1" in hv:
        return "403-XFF"      # XFF 위조
    if hk == "x-junk":
        return "403-HDR"      # 비정상 헤더
    return "OK"               # 정상


def run_query(logs, log_group, start_ts, end_ts, index, limit, poll=2.0, timeout=300):
    q = QUERY_TEMPLATE.format(i=index, limit=limit)
    resp = logs.start_query(logGroupName=log_group, startTime=start_ts,
                            endTime=end_ts, queryString=q)
    qid = resp["queryId"]
    deadline = time.time() + timeout
    while True:
        res = logs.get_query_results(queryId=qid)
        status = res["status"]
        if status in ("Complete", "Failed", "Cancelled", "Timeout"):
            if status != "Complete":
                print(f"[index {index}] 쿼리 종료 상태: {status}", file=sys.stderr)
            return res.get("results", [])
        if time.time() > deadline:
            print(f"[index {index}] 폴링 타임아웃, 쿼리 취소", file=sys.stderr)
            try:
                logs.stop_query(queryId=qid)
            except Exception:
                pass
            return []
        time.sleep(poll)


def row_to_dict(row):
    return {c["field"]: c["value"] for c in row if c["field"] != "@ptr"}


def _short(s, n):
    s = s or ""
    return (s[: n - 1] + "…") if len(s) > n else s


def _table(rows, headers):
    """폭 정렬된 표 문자열 (ASCII 폭 기준)."""
    cols = list(zip(*([headers] + rows))) if rows else [[h] for h in headers]
    widths = [max(len(str(c)) for c in col) for col in cols]
    line = lambda r: "  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r))
    out = [line(headers), "  ".join("-" * w for w in widths)]
    out += [line(r) for r in rows]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="WAF 헤더 통계 + 차단 판정 (CloudWatch Logs Insights)")
    ap.add_argument("--log-group", required=True, help="WAF 로그 그룹명 (예: aws-waf-logs-xxx)")
    ap.add_argument("--region", default=None, help="AWS 리전 (CloudFront WAF면 us-east-1)")
    ap.add_argument("--hours", type=float, default=24, help="조회 기간(시간), 기본 24")
    ap.add_argument("--start", type=int, default=None, help="시작 epoch초 (지정 시 --hours 무시)")
    ap.add_argument("--end", type=int, default=None, help="종료 epoch초 (기본 now)")
    ap.add_argument("--max-index", type=int, default=5, help="헤더 인덱스 0..N, 기본 5")
    ap.add_argument("--limit", type=int, default=10000, help="인덱스별 쿼리 행수 제한")
    ap.add_argument("--top", type=int, default=100, help="전체 표 상위 N행")
    ap.add_argument("--output", default=None, help="CSV 출력 경로")
    args = ap.parse_args()

    end_ts = args.end if args.end is not None else int(time.time())
    start_ts = args.start if args.start is not None else end_ts - int(args.hours * 3600)

    session = boto3.Session(region_name=args.region) if args.region else boto3.Session()
    logs = session.client("logs")

    indices = list(range(args.max_index + 1))
    print(f"인덱스 {indices[0]}..{indices[-1]} 쿼리 실행 중 "
          f"(기간 {start_ts}~{end_ts}, 로그그룹 {args.log_group})...", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=min(8, len(indices))) as ex:
        futures = [ex.submit(run_query, logs, args.log_group, start_ts, end_ts, i, args.limit)
                   for i in indices]
        all_rows = []
        for fut in futures:
            all_rows.extend(fut.result())

    # (header_key, header_value, endpoint, action, status) 합산
    agg = defaultdict(int)
    for row in all_rows:
        d = row_to_dict(row)
        key = (d.get("header_key", ""), d.get("header_value", ""),
               d.get("endpoint", ""), d.get("action", ""), d.get("status", ""))
        try:
            agg[key] += int(d.get("cnt", 0))
        except ValueError:
            pass

    merged = sorted(agg.items(), key=lambda kv: kv[1], reverse=True)

    # ---- CSV (판정 컬럼 포함) ----
    if args.output:
        with open(args.output, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["verdict", "waf_action", "status", "cnt", "endpoint", "header_key", "header_value"])
            for (hk, hv, ep, act, st), cnt in merged:
                w.writerow([verdict(hk, hv, ep), act, st, cnt, ep, hk, hv])
        print(f"총 {len(merged)}행 -> {args.output} 저장 완료", file=sys.stderr)

    # ---- 1) action 요약 ----
    act_sum = defaultdict(int)
    for (hk, hv, ep, act, st), cnt in merged:
        act_sum[act or "(none)"] += cnt
    print("\n=== WAF action 요약 ===")
    for a, c in sorted(act_sum.items(), key=lambda x: -x[1]):
        print(f"  {a:<8} {c}")

    # ---- 2) 아직 안 막힌 비정상 요청 (403대상인데 BLOCK 아님) ----
    gaps = [((hk, hv, ep, act, st), cnt) for (hk, hv, ep, act, st), cnt in merged
            if verdict(hk, hv, ep).startswith("403") and (act or "").upper() != "BLOCK"]
    print("\n=== ⚠ 아직 안 막힌 비정상 요청 (막아야 할 것) ===")
    if not gaps:
        print("  없음 — 403대상이 모두 BLOCK 되고 있음 👍")
    else:
        rows = [[verdict(hk, hv, ep), act or "-", st or "-", cnt, _short(ep, 22), hk, _short(hv, 30)]
                for (hk, hv, ep, act, st), cnt in gaps]
        print(_table(rows, ["판정", "WAF", "status", "cnt", "endpoint", "header", "value"]))

    # ---- 3) 전체 표 ----
    print("\n=== 전체 (상위 %d) ===" % args.top)
    print("판정 범례: 404=미정의경로(정상404)  403-UA=악성UA  403-XFF=XFF위조  403-HDR=비정상헤더  OK=정상")
    rows = [[verdict(hk, hv, ep), act or "-", st or "-", cnt, _short(ep, 22), hk, _short(hv, 30)]
            for (hk, hv, ep, act, st), cnt in merged[: args.top]]
    print(_table(rows, ["판정", "WAF", "status", "cnt", "endpoint", "header", "value"]))


if __name__ == "__main__":
    main()
