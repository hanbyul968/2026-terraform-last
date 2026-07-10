# Module 4 — Keycloak (eu-central-1)

> **리전 eu-central-1**

## 구성 요약
```
gj2026-keycloak-ec2 : Keycloak(8080) + nginx(443, self-signed) HTTPS
Realm team : dev-team/sec-team 그룹, dev-user/sec-user, Client Scope gj2026-keycloak-claims
IAM OIDC Provider = https://<IP>/realms/team
dev-role/sec-role : team 태그 EC2만 start/stop (팀별 격리)
CLI: ~/.aws/gj2026-keycloak-creds.sh 로 Keycloak 계정만으로 STS 임시자격 발급
```

| 항목 | 값 |
|---|---|
| EC2 | `gj2026-keycloak-ec2` |
| Realm | `team` |
| Client Scope | `gj2026-keycloak-claims` (role/team/group 클레임) |
| Client | `gj2026-keycloak-dev`, `gj2026-keycloak-sec` |
| Group | `dev-team`, `sec-team` |
| User | admin/admin1234!, dev-user/dev123!, sec-user/sec123! |
| IAM Role | `gj2026-keycloak-dev-role`, `gj2026-keycloak-sec-role` |
| IAM Policy | `gj2026-keycloak-dev-policy`, `gj2026-keycloak-sec-policy` |

---

## 1) SG + IAM 역할
- SG `gj2026-keycloak-sg`: 22, 80, 443 (또는 전체 허용)
- EC2 역할 `gj2026-keycloak-ec2-role`: `AmazonSSMManagedInstanceCore` (편하면 Admin)

## 2) EC2 생성 + userdata (nginx 먼저 → Keycloak)
**EC2 시작** — 이름 `gj2026-keycloak-ec2`, AL2023 표준, t3.small, 퍼블릭IP, SG/역할 위 값.

```bash
#!/bin/bash
# nginx + 자체서명 인증서 먼저 (OIDC thumbprint 빠르게 확보)
dnf install -y nginx openssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl.key -out /etc/nginx/ssl.crt -subj "/CN=keycloak/O=GJ2026"
cat > /etc/nginx/conf.d/keycloak.conf <<'NG'
server {
  listen 443 ssl; server_name _;
  ssl_certificate /etc/nginx/ssl.crt; ssl_certificate_key /etc/nginx/ssl.key;
  location / {
    proxy_pass http://localhost:8080;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }
}
NG
systemctl enable --now nginx

# Keycloak 26 (curl 사용 - AL2023엔 wget 없음)
dnf install -y java-21-amazon-corretto
cd /opt
curl -fsSLO "https://github.com/keycloak/keycloak/releases/download/26.0.0/keycloak-26.0.0.tar.gz"
tar -xzf keycloak-26.0.0.tar.gz && ln -s keycloak-26.0.0 keycloak && rm keycloak-26.0.0.tar.gz
useradd -r -s /sbin/nologin keycloak || true; chown -R keycloak:keycloak /opt/keycloak*
cat > /opt/keycloak/conf/keycloak.conf <<'KC'
http-enabled=true
http-port=8080
hostname-strict=false
proxy=edge
KC
cat > /etc/systemd/system/keycloak.service <<'SVC'
[Unit]
After=network.target
[Service]
User=keycloak
Environment=KEYCLOAK_ADMIN=admin
Environment=KEYCLOAK_ADMIN_PASSWORD=admin1234!
ExecStart=/opt/keycloak/bin/kc.sh start-dev
Restart=on-failure
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload && systemctl enable --now keycloak
```

> 부팅 후 `https://<PublicIP>/admin` (admin / admin1234!) 접속 확인.

---

## 3) Realm/Group/User/Client/Scope 구성 (콘솔 or CLI)

가장 빠른 방법 — CloudShell에서 Admin REST API:
```bash
IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" --region eu-central-1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
T=$(curl -sk -X POST "https://$IP/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d username=admin -d password='admin1234!' -d grant_type=password | jq -r .access_token)
B="https://$IP/admin/realms"; H="Authorization: Bearer $T"

# Realm
curl -sk -X POST "$B" -H "$H" -H "Content-Type: application/json" -d '{"realm":"team","enabled":true}'
# Groups
for g in dev-team sec-team; do curl -sk -X POST "$B/team/groups" -H "$H" -H "Content-Type: application/json" -d "{\"name\":\"$g\"}"; done
DG=$(curl -sk "$B/team/groups" -H "$H" | jq -r '.[]|select(.name=="dev-team")|.id')
SG=$(curl -sk "$B/team/groups" -H "$H" | jq -r '.[]|select(.name=="sec-team")|.id')
# Client Scope + mappers(role/team/group)
curl -sk -X POST "$B/team/client-scopes" -H "$H" -H "Content-Type: application/json" \
  -d '{"name":"gj2026-keycloak-claims","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"}}'
SID=$(curl -sk "$B/team/client-scopes" -H "$H" | jq -r '.[]|select(.name=="gj2026-keycloak-claims")|.id')
# role, team 은 user attribute 매퍼 / group 은 group membership 매퍼
for m in role team; do
 curl -sk -X POST "$B/team/client-scopes/$SID/protocol-mappers/models" -H "$H" -H "Content-Type: application/json" \
  -d "{\"name\":\"$m\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-attribute-mapper\",\"config\":{\"user.attribute\":\"$m\",\"claim.name\":\"$m\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}"
done
curl -sk -X POST "$B/team/client-scopes/$SID/protocol-mappers/models" -H "$H" -H "Content-Type: application/json" \
  -d '{"name":"group","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"false","claim.name":"group","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}'
# Clients (default scope에 claims 포함, direct grant 허용)
for c in gj2026-keycloak-dev gj2026-keycloak-sec; do
 curl -sk -X POST "$B/team/clients" -H "$H" -H "Content-Type: application/json" \
  -d "{\"clientId\":\"$c\",\"enabled\":true,\"publicClient\":false,\"directAccessGrantsEnabled\":true,\"standardFlowEnabled\":false,\"defaultClientScopes\":[\"gj2026-keycloak-claims\"]}"
done
# Users (그룹/team attribute 포함)
mkuser(){ local u=$1 p=$2 gid=$3 team=$4
 curl -sk -X POST "$B/team/users" -H "$H" -H "Content-Type: application/json" \
   -d "{\"username\":\"$u\",\"enabled\":true,\"emailVerified\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$p\",\"temporary\":false}],\"attributes\":{\"team\":[\"$team\"]}}"
 local uid=$(curl -sk "$B/team/users?username=$u" -H "$H" | jq -r '.[0].id')
 curl -sk -X PUT "$B/team/users/$uid/groups/$gid" -H "$H"; }
mkuser dev-user 'dev123!' "$DG" dev-team
mkuser sec-user 'sec123!' "$SG" sec-team
```

---

## 4) IAM OIDC Provider + 팀별 Role/Policy

```bash
IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=gj2026-keycloak-ec2" --region eu-central-1 --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ACCT=$(aws sts get-caller-identity --query Account --output text)

# 4-1. OIDC Provider (thumbprint = nginx 인증서 SHA1)
THUMB=$(echo | openssl s_client -connect "$IP:443" -servername "$IP" 2>/dev/null | openssl x509 -fingerprint -noout -sha1 | cut -d= -f2 | tr -d ':' | tr A-Z a-z)
aws iam create-open-id-connect-provider --url "https://$IP/realms/team" \
  --client-id-list gj2026-keycloak-dev gj2026-keycloak-sec --thumbprint-list "$THUMB"
OIDC="arn:aws:iam::$ACCT:oidc-provider/$IP/realms/team"

# 4-2. Policy (팀 태그 EC2만 start/stop)
mkpolicy(){ local name=$1 team=$2
 cat > /tmp/p.json <<J
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ec2:StartInstances","ec2:StopInstances"],"Resource":"*","Condition":{"StringEquals":{"ec2:ResourceTag/team":"$team"}}},
 {"Effect":"Allow","Action":["ec2:DescribeInstances"],"Resource":"*"},
 {"Effect":"Deny","Action":["ec2:StartInstances","ec2:StopInstances"],"Resource":"*","Condition":{"StringNotEquals":{"ec2:ResourceTag/team":"$team"}}}]}
J
 aws iam create-policy --policy-name "$name" --policy-document file:///tmp/p.json; }
mkpolicy gj2026-keycloak-dev-policy dev-team
mkpolicy gj2026-keycloak-sec-policy sec-team

# 4-3. Role (web identity, aud = client)
mkrole(){ local role=$1 client=$2 pol=$3
 cat > /tmp/t.json <<J
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"$OIDC"},
 "Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"$IP/realms/team:aud":"$client"}}}]}
J
 aws iam create-role --role-name "$role" --assume-role-policy-document file:///tmp/t.json
 aws iam attach-role-policy --role-name "$role" --policy-arn "arn:aws:iam::$ACCT:policy/$pol"; }
mkrole gj2026-keycloak-dev-role gj2026-keycloak-dev gj2026-keycloak-dev-policy
mkrole gj2026-keycloak-sec-role gj2026-keycloak-sec gj2026-keycloak-sec-policy
```

---

## 5) AWS CLI 인증 구성 (keycloak EC2 안에서)
`~/.aws/gj2026-keycloak-creds.sh` — Keycloak에서 ID Token 받아 STS AssumeRoleWithWebIdentity:
```bash
#!/bin/bash
# 사용: gj2026-keycloak-creds.sh <dev|sec> <username>
TEAM=$1; USER=$2
IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)   # 또는 고정 도메인
[ "$TEAM" = "dev" ] && CLIENT=gj2026-keycloak-dev && ROLE=gj2026-keycloak-dev-role && PW='dev123!'
[ "$TEAM" = "sec" ] && CLIENT=gj2026-keycloak-sec && ROLE=gj2026-keycloak-sec-role && PW='sec123!'
ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "<ACCT>")
TOKEN=$(curl -sk -X POST "https://$IP/realms/team/protocol/openid-connect/token" \
  -d client_id=$CLIENT -d username=$USER -d "password=$PW" -d grant_type=password -d scope=openid \
  --data-urlencode "client_secret=$(cat ~/.$CLIENT.secret 2>/dev/null)" | jq -r .id_token)
aws sts assume-role-with-web-identity \
  --role-arn "arn:aws:iam::$ACCT:role/$ROLE" \
  --role-session-name keycloak-session \
  --web-identity-token "$TOKEN" \
  --query 'Credentials.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey,SessionToken:SessionToken,Version:`1`}' \
  --output json
```
프로필 연결(`~/.aws/config`):
```ini
[profile gj2026-keycloak-dev]
credential_process = /home/ec2-user/.aws/gj2026-keycloak-creds.sh dev dev-user
[profile gj2026-keycloak-sec]
credential_process = /home/ec2-user/.aws/gj2026-keycloak-creds.sh sec sec-user
```
> Client가 confidential이면 client secret 필요(콘솔 Client → Credentials에서 복사, `~/.gj2026-keycloak-dev.secret`에 저장). public client로 바꾸면 secret 불필요.

---

## 6) 채점 검증 (CloudShell)
```bash
# 4-3 임시자격
aws configure list-profiles | grep gj2026-keycloak
aws sts get-caller-identity --profile gj2026-keycloak-dev
aws sts get-caller-identity --profile gj2026-keycloak-sec

# 4-4 팀별 start/stop (사전 dev/sec 태그 EC2 필요 - 채점 사전준비에서 생성)
# dev로 dev-team EC2 start → 성공 / sec-team stop → UnauthorizedOperation
```

---

## 자주 나는 문제
| 증상 | 해결 |
|---|---|
| OIDC thumbprint 못 가져옴 | nginx(443)가 안 뜸. **nginx를 Keycloak보다 먼저** 기동, 인증서 SAN에 빈 IP 넣지 말 것(고정 CN) |
| Keycloak 다운로드 실패 | `wget: command not found` → **curl** 사용 |
| `assume-role-with-web-identity` 거부 | Role 신뢰정책 `aud` = client id 일치, OIDC Provider client-id-list에 client 등록 |
| 타 팀 접근이 막히지 않음 | Policy에 **Deny + StringNotEquals** 조건 필요 |
