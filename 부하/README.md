# 3과제 부하 테스트 & 채점 시뮬레이터

실시간으로 엔드포인트에 부하를 주입하고, 채점 기준에 맞춰 점수를 시뮬레이션하는 웹 도구.

## 빠른 시작

```powershell
cd 부하
python -m http.server 9000

# 별도 PowerShell 창에서 Chrome CORS 비활성화 모드로 실행 (필수)
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --disable-web-security --user-data-dir=C:\temp\chrome-cors http://localhost:9000
```

> ⚠️ **반드시 `--disable-web-security` Chrome으로 열어야 합니다.** 일반 브라우저에서는 CORS 때문에 CloudFront 엔드포인트 요청이 전부 차단됩니다.

1. 엔드포인트 URL 입력 (예: `http://dxxxxxx.cloudfront.net`)
2. ▶ 부하 시작 클릭
3. 테스트 완료 후 📊 채점 클릭

## 인스턴스 자동 감지 (비용 자동 계산)

별도 PowerShell 창에서 로컬 서버를 실행하면 EC2 인스턴스를 자동으로 감지합니다.

```powershell
# 새 PowerShell 창에서 실행
powershell -ExecutionPolicy Bypass -File detect-server.ps1
```

서버 실행 후 웹페이지에서 "🔍 인스턴스 자동 감지" 버튼 클릭.

> 서버 없이도 동작합니다. 자동 감지 실패 시 `t3.medium:2` 형식으로 수동 입력하는 팝업이 뜹니다.

## 테스트 항목

| 테스트 | 설명 | 채점 기준 |
|--------|------|-----------|
| user GET | `/v1/user?email=...` | availability + ≤0.2s |
| product GET | `/v1/product?id=...` | availability + ≤0.2s |
| stress POST | `/v1/stress` (length) | availability + ≤1.0s |
| WAF (비정상) | XSS, SQLi, SSRF 등 11종 | → 403 응답 |
| 404 처리 | `/v1/none`, `/random` 등 | → 404 응답 |
| 이미지 | `/images/productN.jpg` | 5s 이내 다운로드 |

## 채점 기준 (40점 만점)

| 항목 | 배점 | 측정 방법 |
|------|------|-----------|
| 1. 비정상 요청 처리 | 4점 | 이미지 다운로드율 + WAF 차단율 (90/85/80/50%) |
| 2. 고가용성/안정성 | 12점 | API별 availability (90~30%, 각 0.5점) |
| 3. 성능 효율성 | 12점 | ≤0.2s 응답 비율 (90~30%, 각 0.5점) |
| 4. 비용 최적화 | 12점 | cost ratio 0.5~3.75 (각 구간 1점, 성능 30% 이상 조건) |

### Cost Ratio 계산

```
Cost Ratio = 실제 EC2 비용(시간당) / 기준 비용(t3.medium × 2, 시간당)
```

- 기준: t3.medium 2대 = $0.0928/hr
- 예: 노드 3대 → $0.1392/hr → ratio = 1.50
- ratio가 낮을수록 고득점 (1.00 이하면 12점 만점)

## 설정 옵션

| 옵션 | 기본값 | 설명 |
|------|--------|------|
| Concurrency | 10 | 동시 요청 워커 수 |
| 테스트 시간 | 60초 | 자동 종료까지 시간 |
| 요청 간격 | 100ms | 워커당 요청 사이 대기시간 |
| Stress length | 256 | stress API의 length 파라미터 |

## 파일 구조

```
부하/
├── index.html          # 웹 UI
├── app.js              # 부하 테스트 + 채점 로직
├── detect-server.ps1   # EC2 인스턴스 자동 감지 로컬 서버
└── README.md
```

## 주의사항

- CORS: CloudFront 엔드포인트는 기본적으로 CORS를 허용하지 않을 수 있음. 브라우저에서 직접 테스트 시 CORS 에러가 나면 `--disable-web-security` 플래그로 Chrome 실행하거나, 별도 부하 도구(hey, k6) 사용 권장.
- 실제 대회 채점은 서버사이드에서 수행되므로 이 도구의 점수는 **참고용**입니다.
- WAF 테스트는 실제 AWS Managed Rules 동작과 100% 일치하지 않을 수 있습니다.
