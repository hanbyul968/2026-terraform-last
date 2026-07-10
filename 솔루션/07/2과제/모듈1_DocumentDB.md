# 모듈 1 — DocumentDB based NoSQL Application (콘솔)

**리전: 서울 `ap-northeast-2`** — 우측 상단 리전 선택기에서 먼저 서울로 변경!

## 목표 구성도

```
[인터넷] ──▶ Public Subnet ── Client EC2 (skills-nosql-client-ec2, 8080 공개)
                                   │ 27017
                                   ▼
              Private Subnet ×2 ── DocumentDB (skills-nosql-docdb-cluster, 외부 비노출)
                                   └ KMS 암호화 / Secrets Manager
```

## 고정 이름 요약

| 항목 | 값 |
|------|-----|
| Cluster Identifier | `skills-nosql-docdb-cluster` |
| Instance Identifier | `skills-nosql-docdb-instance-1` |
| Instance Class | `db.t3.medium` |
| KMS Alias | `alias/skills-nosql-docdb` |
| Secret Name | `skills-nosql-docdb-secret` |
| Client EC2 Name | `skills-nosql-client-ec2` |
| Database | `skills_retail` |

---

## 1단계. VPC 및 서브넷

`[VPC > VPC 생성]`

가장 쉬운 방법은 **"VPC 등"** 옵션으로 한 번에 만드는 것입니다.

1. **VPC 등** 선택
2. 이름 태그 자동 생성: `skills-nosql`
3. IPv4 CIDR: **`10.1.0.0/16`**
4. 가용 영역(AZ) 수: **2**
5. 퍼블릭 서브넷 수: **1** (또는 2), 프라이빗 서브넷 수: **2**
6. NAT 게이트웨이: **없음**, VPC 엔드포인트: **없음**
7. **DNS 호스트 이름 활성화**, **DNS 확인 활성화** 체크
8. **VPC 생성**

> 수동으로 만들 경우:
> - VPC `10.1.0.0/16` (DNS 호스트네임 ON)
> - Public Subnet `10.1.1.0/24` (AZ a), 자동 퍼블릭 IP 할당 ON
> - Private Subnet `10.1.10.0/24` (AZ a), `10.1.11.0/24` (AZ c) ← DocDB는 서로 다른 AZ 2개 필요
> - 인터넷 게이트웨이 생성 후 VPC에 연결
> - 퍼블릭 라우팅 테이블에 `0.0.0.0/0 → IGW` 추가, Public Subnet 연결

---

## 2단계. 보안 그룹 2개

`[EC2 > 보안 그룹 > 보안 그룹 생성]`

**① Client EC2용** — 이름 `skills-nosql-client-sg`
- 인바운드 규칙:
  - **사용자 지정 TCP / 8080 / 소스 `0.0.0.0/0`** (앱 외부 접근)
  - (선택) SSH / 22 / `0.0.0.0/0`
- 아웃바운드: 전체 허용(기본)

**② DocumentDB용** — 이름 `skills-nosql-docdb-sg`
- 인바운드 규칙:
  - **사용자 지정 TCP / 27017 / 소스 = 위에서 만든 `skills-nosql-client-sg`** (SG를 소스로 지정)
- 아웃바운드: 전체 허용

> 핵심: DocDB는 **Client SG에서만** 27017 허용 → 외부 직접 노출 금지 조건 충족.

---

## 3단계. KMS 키

`[KMS > 고객 관리형 키 > 키 생성]`

1. 키 유형: **대칭**, 키 사용: **암호화 및 해독**
2. 별칭: **`skills-nosql-docdb`** (콘솔이 `alias/` 자동 접두)
3. 키 관리 권한/사용 권한: 본인 계정 관리자 역할 지정 → 다음 → **완료**

---

## 4단계. DocumentDB 클러스터

`[Amazon DocumentDB > 클러스터 > 생성]` (리전 서울 확인!)

### 서브넷 그룹 먼저
`[DocumentDB > 서브넷 그룹 > 생성]`
- 이름: `skills-nosql-docdb-subnet` (자유)
- VPC: `skills-nosql`
- 서브넷: **Private Subnet 2개** 추가

### 클러스터 생성
- **클러스터 식별자**: `skills-nosql-docdb-cluster`
- 엔진 버전: 기본(5.0)
- **인스턴스 클래스**: `db.t3.medium`
- 인스턴스 수: **1**
- 인증:
  - 사용자 이름: `skillsadmin`
  - 암호: `Skills2026!` (자유, 단 Secret과 일치)
- **암호화 저장**: 활성화 → KMS 키 **`alias/skills-nosql-docdb`** 선택
- 네트워크:
  - VPC: `skills-nosql`
  - 서브넷 그룹: 위에서 만든 것
  - VPC 보안 그룹: **`skills-nosql-docdb-sg`**
- 추가 설정:
  - **백업 보존 기간: 1일 이상**
  - **TLS: 활성화**(기본)
- **클러스터 생성** (약 8~10분 대기)

생성 후 **인스턴스 식별자**가 `skills-nosql-docdb-instance-1` 인지 확인.
> 자동 생성 이름이 다르면, 인스턴스를 이 이름으로 만들도록 클러스터 생성 시 **인스턴스 식별자**를 직접 지정하세요.

클러스터 상태가 `available` 되면 **엔드포인트(클러스터 엔드포인트)** 를 복사해 둡니다.

---

## 5단계. Secrets Manager 시크릿

`[Secrets Manager > 새 보안 암호 저장]`

1. 유형: **다른 유형의 보안 암호**
2. 키/값 (Plaintext 탭에서 아래 JSON):
   ```json
   {
     "username": "skillsadmin",
     "password": "Skills2026!",
     "host": "<DocDB 클러스터 엔드포인트 호스트네임>"
   }
   ```
   > `host`는 **호스트네임만** — `mongodb://`, `:27017` 같은 스킴/포트를 넣지 마세요.
   > 예: `skills-nosql-docdb-cluster.cluster-xxxx.ap-northeast-2.docdb.amazonaws.com`
3. **보안 암호 이름**: `skills-nosql-docdb-secret`
4. 나머지 기본 → **저장**

---

## 6단계. Client EC2 (IAM 역할 + 앱 배포)

### 6-1. IAM 역할
`[IAM > 역할 > 역할 생성]`
- 신뢰 엔터티: **AWS 서비스 > EC2**
- 권한 정책 2개 연결:
  - `AmazonSSMManagedInstanceCore`
  - `SecretsManagerReadWrite`
- 역할 이름: `skills-nosql-ec2-role`

### 6-2. EC2 인스턴스
`[EC2 > 인스턴스 시작]`
- 이름 태그: **`skills-nosql-client-ec2`**
- AMI: **Amazon Linux 2023**
- 인스턴스 유형: `t3.small`
- 키페어: 없음(진행) 또는 본인 것
- 네트워크:
  - VPC: `skills-nosql`
  - 서브넷: **Public Subnet**
  - 퍼블릭 IP 자동 할당: **활성화**
  - 보안 그룹: **`skills-nosql-client-sg`**
- 고급 세부 정보 → **IAM 인스턴스 프로파일**: `skills-nosql-ec2-role`
- 고급 세부 정보 → **사용자 데이터**에 아래 스크립트 붙여넣기:

```bash
#!/bin/bash
set -ex
cd /home/ec2-user

# 배포 파일 받기 (repo raw). 파일을 직접 올려도 됨.
REPO_BASE="https://raw.githubusercontent.com/hnmly/2026-terraform/main/07/2%EA%B3%BC%EC%A0%9C/app/module1"
for f in install_client_app.sh run_app.sh run_seed.sh run_validate.sh docdb_client.py retail_dataset.json requirements.txt; do
  curl -fsSL "$REPO_BASE/$f" -o "/home/ec2-user/$f"
done
chmod +x *.sh
./install_client_app.sh

cd /opt/skills-nosql
nohup ./run_app.sh > /home/ec2-user/nohup.out 2>&1 &
sleep 5
./run_seed.sh || /opt/skills-nosql/.venv/bin/python3 /opt/skills-nosql/docdb_client.py seed

# 인덱스 + TTL 생성
/opt/skills-nosql/.venv/bin/python3 -c "
from docdb_client import db, ASCENDING, DESCENDING
d = db()
d.orders.create_index([('orderId', ASCENDING)], unique=True, name='orderId_1')
d.orders.create_index([('customerId', ASCENDING), ('createdAt', DESCENDING)], name='customerId_1_createdAt_-1')
d.orders.create_index([('status', ASCENDING), ('dueAt', ASCENDING)], name='status_1_dueAt_1')
d.products.create_index([('productId', ASCENDING)], unique=True, name='productId_1')
d.products.create_index([('warehouseId', ASCENDING), ('stock', ASCENDING)], name='warehouseId_1_stock_1')
d.sessions.create_index([('sessionId', ASCENDING)], unique=True, name='sessionId_1')
d.sessions.create_index([('expiresAt', ASCENDING)], expireAfterSeconds=0, name='expiresAt_1')
d.sessions.create_index([('customerId', ASCENDING), ('lastSeen', DESCENDING)], name='customerId_1_lastSeen_-1')
"
```

> 앱은 `skills-nosql-docdb-secret` 에서 접속 정보를 **직접** 읽습니다. 그래서 Secret과 DocDB가 먼저 만들어져 있어야 합니다.
> 인터넷에서 raw 파일을 못 받는 환경이면, 배포 파일을 EC2에 직접 업로드(scp/SSM) 후 `install_client_app.sh` 부터 수동 실행하세요.

- **인스턴스 시작**

---

## 7단계. 데이터 모델 확인 (인덱스 & TTL)

user_data가 만든 인덱스가 문제지 요구와 일치해야 합니다.

| 컬렉션 | 인덱스 | 조건 |
|--------|--------|------|
| orders | `{orderId:1}` | **unique** |
| orders | `{customerId:1, createdAt:-1}` | |
| orders | `{status:1, dueAt:1}` | |
| products | `{productId:1}` | **unique** |
| products | `{warehouseId:1, stock:1}` | |
| sessions | `{sessionId:1}` | **unique** |
| sessions | `{expiresAt:1}` | **TTL expireAfterSeconds: 0** |
| sessions | `{customerId:1, lastSeen:-1}` | |

BSON Date 필드: `orders.createdAt/dueAt`, `products.updatedAt`, `sessions.lastSeen/expiresAt`
컬렉션 최소 데이터: orders 8+, products 6+, sessions 3+ (배포된 `retail_dataset.json` 그대로면 충족)

---

## 8단계. 검증 (CloudShell 또는 로컬)

```bash
IP=$(aws ec2 describe-instances --region ap-northeast-2 \
  --filters Name=tag:Name,Values=skills-nosql-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

curl http://$IP:8080/health              # {"status":"ok",...}
curl http://$IP:8080/v1/admin/summary    # counts: orders8/products6/sessions3
curl http://$IP:8080/v1/admin/indexes    # 인덱스 + TTL
curl http://$IP:8080/v1/orders/O-1001
curl http://$IP:8080/v1/customers/C001/orders
curl "http://$IP:8080/v1/orders/pending?from=2026-06-01T00:00:00Z&to=2026-06-08T00:00:00Z"
curl "http://$IP:8080/v1/products/low-stock?warehouseId=W-A"
```

전부 `http_code=200` 이고 데이터가 나오면 완료. (EC2 부팅 후 2~3분 뒤 확인)

## 체크리스트
- [ ] DocDB 클러스터/인스턴스 이름·클래스·KMS·백업 정확
- [ ] Secret에 username/password/host(호스트네임만)
- [ ] Client EC2 running + 퍼블릭 IP + 8080 응답
- [ ] 인덱스 8종 + sessions TTL
- [ ] 조회 API 4종 200
