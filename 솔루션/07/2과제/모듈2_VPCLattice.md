# 모듈 2 — Simplify Service Networking with VPC Lattice (콘솔)

**리전: 도쿄 `ap-northeast-1`** — 리전 선택기 먼저 도쿄로!

> Client VPC와 Service VPC 사이에 **VPC Peering / Transit Gateway 를 만들지 않습니다.**
> 오직 **VPC Lattice** 로만 두 앱을 연결합니다.

## 목표 구성도

```
Client VPC (10.61.0.0/16)                Service VPC (10.62.0.0/16)
  Client EC2 (public, :80) ─┐             Service EC2 (no public IP, :8080)
                            │                     ▲
                     [VPC Lattice]                │ Target Group(:8080)
        Service Network(skills-lattice-sn)        │
        └─ Service(order-service) ─ Listener(:80) ─ Forward ─┘
```

## 고정 이름 요약

| 항목 | 값 |
|------|-----|
| Client VPC / CIDR | `skills-lattice-client-vpc` / `10.61.0.0/16` |
| Service VPC / CIDR | `skills-lattice-service-vpc` / `10.62.0.0/16` |
| Client EC2 | `skills-lattice-client-ec2` (public, :80) |
| Service EC2 | `skills-lattice-service-ec2` (no public IP, :8080) |
| Service Network | `skills-lattice-sn` |
| Service | `skills-lattice-order-service` |
| Target Group | `skills-lattice-order-tg` (INSTANCE, HTTP/8080) |
| Listener | `skills-lattice-http-listener` (HTTP/80) |

---

## 1단계. 두 개의 VPC

`[VPC > VPC 생성]` — **"VPC 등"** 으로 2번 생성.

**Client VPC**
- 이름: `skills-lattice-client-vpc`, CIDR **`10.61.0.0/16`**, DNS 호스트네임 ON
- 퍼블릭 서브넷 1개 (`10.61.1.0/24`, 자동 퍼블릭 IP ON), IGW 연결, 퍼블릭 라우팅

**Service VPC**
- 이름: `skills-lattice-service-vpc`, CIDR **`10.62.0.0/16`**, DNS 호스트네임 ON
- 서브넷 `10.62.1.0/24` (Service EC2용, 퍼블릭 IP 없음)
- Service EC2가 앱 설치를 위해 인터넷이 필요하므로 **퍼블릭 서브넷 + IGW** 를 하나 두거나(간단),
  또는 NAT를 둡니다. (여기선 간단히 IGW + 퍼블릭 서브넷을 쓰되 EC2에 **퍼블릭 IP는 부여하지 않음**)

> 채점 조건: Service EC2 는 **퍼블릭 IP 없이** 내부 서비스. 앱 배포용 아웃바운드만 필요.

---

## 2단계. 보안 그룹

`[EC2 > 보안 그룹]` (VPC 주의해서 생성)

**Client EC2 SG** (Client VPC) — `skills-lattice-client-sg`
- 인바운드: **HTTP TCP/80 from `0.0.0.0/0`**
- 아웃바운드: 전체 허용 (Lattice 도메인 호출)

**Service EC2 SG** (Service VPC) — `skills-lattice-service-sg`
- 인바운드: **사용자 지정 TCP/8080**, 소스는 **VPC Lattice 관리형 접두사 목록(Prefix List)**
  - 소스 드롭다운에서 **접두사 목록** → `com.amazonaws.ap-northeast-1.vpc-lattice` 선택
  - ⚠️ **`0.0.0.0/0` 로 열면 미충족**입니다. 반드시 Lattice Prefix List만!
- 아웃바운드: 전체 허용

**Lattice VPC 연결용 SG** (Client VPC) — `skills-lattice-assoc-sg`
- 인바운드: **HTTP TCP/80 from `10.61.0.0/16`** (Client VPC CIDR)
- 아웃바운드: 전체 허용

---

## 3단계. Service EC2 (먼저)

`[EC2 > 인스턴스 시작]`
- 이름: **`skills-lattice-service-ec2`**
- AMI: Amazon Linux 2023, 유형 `t3.micro`
- 네트워크: **Service VPC**, 서브넷 지정, **퍼블릭 IP 자동 할당: 비활성화**
- 보안 그룹: `skills-lattice-service-sg`
- 사용자 데이터: 제공 `service_app.py`(:8080)를 systemd로 기동. 예:

```bash
#!/bin/bash
set -ex
install -d -m 0755 /opt/skills-lattice/service
cat > /opt/skills-lattice/service/service_app.py <<'PY'
# ↓↓↓ 제공 배포파일 service_app.py 내용을 그대로 붙여넣기 ↓↓↓
PY
cat > /etc/systemd/system/lattice-order-service-app.service <<'UNIT'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/skills-lattice/service/service_app.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now lattice-order-service-app.service
```

---

## 4단계. VPC Lattice 리소스

`[VPC Lattice]` 콘솔에서 순서대로.

### 4-1. Target Group
`[VPC Lattice > 대상 그룹 > 생성]`
- 유형: **인스턴스**
- 이름: **`skills-lattice-order-tg`**
- 프로토콜/포트: **HTTP / 8080**
- VPC: **`skills-lattice-service-vpc`**
- 상태 확인: **HTTP, 경로 `/health`**
- 대상 등록: **`skills-lattice-service-ec2`** (포트 8080) 추가
- 생성

### 4-2. Service
`[VPC Lattice > 서비스 > 생성]`
- 이름: **`skills-lattice-order-service`**
- 사용자 지정 도메인: 없음 (Generated Domain 사용)
- **리스너 추가**:
  - 이름: **`skills-lattice-http-listener`**
  - 프로토콜/포트: **HTTP / 80**
  - 기본 작업: **대상 그룹으로 전달 → `skills-lattice-order-tg`**
- 생성

### 4-3. Service Network
`[VPC Lattice > 서비스 네트워크 > 생성]`
- 이름: **`skills-lattice-sn`**
- **서비스 연결**: `skills-lattice-order-service` 추가
- **VPC 연결**: `skills-lattice-client-vpc` 추가
  - 연결 시 보안 그룹: **`skills-lattice-assoc-sg`** (80 from 10.61.0.0/16)
- 생성

> 완료되면 Service, VPC Association, Service Association 이 모두 **ACTIVE** 여야 합니다.
> Service 의 **Generated Domain**(예: `skills-lattice-order-service-xxxx....vpc-lattice-svcs.ap-northeast-1.on.aws`) 을 복사.

---

## 5단계. Client EC2

`[EC2 > 인스턴스 시작]`
- 이름: **`skills-lattice-client-ec2`**
- 네트워크: **Client VPC**, 퍼블릭 서브넷, **퍼블릭 IP 활성화**
- 보안 그룹: `skills-lattice-client-sg`
- IAM 역할(선택): `vpc-lattice:ListServices` 권한을 주면 앱이 도메인을 자동 조회 가능
- 사용자 데이터: 제공 `client_app.py`(:80)를 기동하되, 환경변수 **`SERVICE_URL`** 를 위 Generated Domain 으로 설정

```bash
#!/bin/bash
set -ex
install -d -m 0755 /opt/skills-lattice/client
cat > /opt/skills-lattice/client/client_app.py <<'PY'
# ↓↓↓ 제공 배포파일 client_app.py 내용을 그대로 붙여넣기 ↓↓↓
PY
cat > /etc/skills-lattice-client.env <<EOF
SERVICE_URL=http://<복사한 Generated Domain>
EOF
cat > /etc/systemd/system/lattice-client-app.service <<'UNIT'
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
EnvironmentFile=/etc/skills-lattice-client.env
ExecStart=/usr/bin/python3 /opt/skills-lattice/client/client_app.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now lattice-client-app.service
```

> ⚠️ `SERVICE_URL` 은 앱 시작 시 읽힙니다. 도메인을 나중에 알게 되면 값을 채운 뒤
> `sudo systemctl restart lattice-client-app` 로 재시작하세요.

---

## 6단계. 검증

```bash
IP=$(aws ec2 describe-instances --region ap-northeast-1 \
  --filters Name=tag:Name,Values=skills-lattice-client-ec2 Name=instance-state-name,Values=running \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

curl http://$IP/health
curl "http://$IP/v1/client/orders?id=1001"
# 기대: {"client":"ok","service":{"order_id":"1001","via":"vpc-lattice"}}
```

## 체크리스트
- [ ] Client/Service VPC CIDR 10.61 / 10.62
- [ ] Service EC2 퍼블릭 IP 없음, Client EC2 퍼블릭 IP 있음 + /health 200
- [ ] Service SG 8080 은 **Lattice Prefix List 만** (0.0.0.0/0 금지)
- [ ] SN/Service/Association 전부 ACTIVE, Target **HEALTHY**
- [ ] `/v1/client/orders?id=1001` 에 order_id=1001, via=vpc-lattice 포함
