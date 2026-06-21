# logcheck — capacity profiling tool

3과제 EKS 인프라에 k6 부하 + kubectl 폴링 돌려서:

1. **현재 트래픽이 어느 정도의 파드/노드/리소스로 처리되는지** 표로 정리
2. **예상 트래픽 입력 → 권장 파드/노드/HPA/Karpenter 설정 출력**

Terraform 에 포함 안 됨. 별도 툴.

---

## 구성

```
logcheck/
├── profile.js     # k6 step-load 시나리오 (50→100→200→400→…)
├── collect.sh     # 10초마다 kubectl top/get hpa/get pod 폴링 → metrics.csv
├── run.sh         # collect + k6 동시 실행 → analyze 자동 호출
├── analyze.py     # k6.json + metrics.csv 합쳐서 profile.csv + report.md 생성
├── recommend.py   # profile.csv 역방향 lookup: 예상 RPS → 권장 구성
└── out/<stamp>/   # 각 실행마다 raw + report
```

## 사전 준비

```bash
brew install k6 jq
pip3 install --user  # (stdlib만 사용, 추가 패키지 없음)

# kubectl 컨텍스트 (kim profile)
AWS_PROFILE=kim aws eks update-kubeconfig \
  --name apdev-eks-cluster --region ap-northeast-2 --alias kim-apdev
kubectl config use-context kim-apdev

# metrics-server 가 클러스터에 있어야 kubectl top 동작 (EKS addon 으로 설치 가능)
kubectl get deploy -n kube-system metrics-server
```

## 사용 흐름

### 1. 프로파일링 (한 번만)

```bash
cd logcheck

# 짧게 (~5분, smoke + 파이프라인 검증용)
./run.sh http://<endpoint> short app kim-apdev

# 본격 (~25분, 실제 권장값 산출용)
./run.sh http://<endpoint> full app kim-apdev
```

결과:
```
out/20260517-090000/
├── k6.json              # k6 raw stream
├── k6_summary.json      # k6 요약
├── k6.log               # k6 stdout
├── metrics.csv          # kubectl 폴링 raw
├── profile.csv          # 합쳐진 RPS-bucket 표
└── report.md            # 사람이 읽는 결론
```

`report.md` 예시:
```
## product  (SLA p95 ≤ 200ms)
| RPS bucket | samples | p50 | p95 | p99 | err | replicas | cpu(m) | mem(Mi) | nodes |
|---|---|---|---|---|---|---|---|---|---|
| 50  | 510  |  18 |  42 |  68 | 0.00% | 2.0 |  120 | 180 | 2.0 |
| 100 | 970  |  21 |  55 |  92 | 0.00% | 2.0 |  240 | 195 | 2.0 |
| 200 | 1980 |  32 |  88 | 140 | 0.00% | 3.0 |  450 | 240 | 2.0 |
| 400 | 3850 |  78 | 210 | 380 | 0.30% | 4.0 |  870 | 320 | 3.0 |

**SLA breach at**: ~400 RPS (p95 exceeds 200ms)
```

### 2. 권장값 산출 (반복)

```bash
cp out/20260517-090000/profile.csv profile.csv   # 기준 baseline 으로 승격

./recommend.py --user 300 --product 800 --stress 50
# →
# === Capacity recommendation (mode=cost, safety=120%) ===
# App        Target RPS  Pods CPU/pod   Mem/pod   Total CPU  Total Mem
# user             300    4   200m     128Mi    800m       512Mi
# product          800    3   150m     100Mi    450m       300Mi
# stress            50    3   400m     200Mi   1200m       600Mi
#
# === Cluster sizing (t3.medium) ===
#   → recommended nodes: 3
#
# === HPA suggestions ===
#   user    request=300m  minReplicas=2  maxReplicas=8  targetCPU=66%
#   product request=250m  minReplicas=2  maxReplicas=6  targetCPU=60%
#   stress  request=600m  minReplicas=2  maxReplicas=6  targetCPU=66%
```

옵션:
```bash
--safety 1.3       # 마진 30%
--mode ha          # 최소 2 pod, 최소 3 node 강제
--profile <path>   # 다른 baseline 사용
```

## 작동 원리

### k6
- `ramping-arrival-rate` executor 로 초당 요청 수를 단계적으로 올림
- 시나리오: 50% product GET (캐시 hit 유도용 hot id 20개) / 35% user POST+GET / 15% stress
- 각 요청에 `tags: { app: <name> }` 붙임 → analyze 에서 앱별 분류

### collect.sh
- 10초마다 `kubectl get deploy/hpa/pods`, `kubectl top pods`, `kubectl get nodes` 한 줄 CSV 로 append
- 백그라운드 PID 로 돌리고 k6 끝나면 kill

### analyze.py
- k6.json 의 `http_req_duration` 이벤트를 10초 window 로 묶음 → 그 window 의 RPS 계산
- 같은 window 의 kubectl 메트릭과 join (timestamp 정렬)
- RPS 를 버킷 (10/25/50/100/200/…) 으로 quantize
- 버킷별 p50/p95/p99/err_rate + 평균 replicas/cpu/mem/nodes
- SLA (`user=200ms, product=200ms, stress=1000ms`) 첫 breach 지점 자동 탐지

### recommend.py
- profile.csv 에서 "SLA 통과한 가장 높은 RPS 버킷" 의 (rps_per_pod, cpu_per_pod, mem_per_pod) 추출
- 사용자 입력 target RPS × safety → 필요 pod 수
- pod 합산 + 시스템 overhead → t3.medium allocatable 으로 나눠서 노드 수
- HPA target CPU% = `(평균 사용 / 권장 request) × 100`, 50~80% 범위로 clamp
- 측정 범위 초과 시 ⚠ 외삽 경고

## 한계

- DB 가 병목이면 pod 늘려도 안 됨 (RDS CPU/Connections 별도 관찰 필요)
- 캐시 hit ratio 변동에 따라 product 처리량 ±크게 변함
- `kubectl top` 은 ~15초 지연 — 짧은 spike 는 못 잡음
- t3.medium 고정. 다른 instance type 쓰려면 `recommend.py` 의 `NODE_CPU_M`/`NODE_MEM_MI` 변경

## 정리

```bash
rm -rf out/
```
