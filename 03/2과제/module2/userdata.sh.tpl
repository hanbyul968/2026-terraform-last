#!/bin/bash
# =============================================================================
# wsc2026-keycloak EC2 부트스트랩 (private subnet, SSM 접속)
#   - Keycloak 26 (start-dev, ALB edge proxy 뒤 HTTP:8080)
#   - Realm wsc2026-aws / 그룹(dev-team, infra-team) / 사용자(dev-user, infra-user)
#   - AWS SAML Client (urn:amazon:webservices) + Role/SessionName/SessionDuration 매퍼
#   로그: /var/log/keycloak-bootstrap.log
# =============================================================================
set -eux
exec > /var/log/keycloak-bootstrap.log 2>&1

ADMIN_PW='${admin_password}'
REALM='${realm}'
ACCOUNT_ID='${account_id}'
SAML_PROVIDER='${saml_provider}'
DEV_ROLE='${dev_role}'
INFRA_ROLE='${infra_role}'
DEV_USER_PW='${dev_user_pw}'
INFRA_USER_PW='${infra_user_pw}'

DEV_SAML_ROLE="arn:aws:iam::$${ACCOUNT_ID}:role/$${DEV_ROLE},arn:aws:iam::$${ACCOUNT_ID}:saml-provider/$${SAML_PROVIDER}"
INFRA_SAML_ROLE="arn:aws:iam::$${ACCOUNT_ID}:role/$${INFRA_ROLE},arn:aws:iam::$${ACCOUNT_ID}:saml-provider/$${SAML_PROVIDER}"

dnf install -y java-21-amazon-corretto tar jq

KC_VERSION="26.0.7"
cd /opt
curl -fsSLO "https://github.com/keycloak/keycloak/releases/download/$${KC_VERSION}/keycloak-$${KC_VERSION}.tar.gz"
tar -xzf "keycloak-$${KC_VERSION}.tar.gz"
ln -sfn "keycloak-$${KC_VERSION}" keycloak
rm -f "keycloak-$${KC_VERSION}.tar.gz"
useradd -r -s /sbin/nologin keycloak || true
chown -R keycloak:keycloak /opt/keycloak*

cat > /opt/keycloak/conf/keycloak.conf <<'KCEOF'
http-enabled=true
http-port=8080
proxy-headers=xforwarded
hostname-strict=false
KCEOF

cat > /etc/systemd/system/keycloak.service <<SVCEOF
[Unit]
Description=Keycloak
After=network.target

[Service]
Type=simple
User=keycloak
Environment=KEYCLOAK_ADMIN=admin
Environment=KEYCLOAK_ADMIN_PASSWORD=$${ADMIN_PW}
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=admin
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=$${ADMIN_PW}
ExecStart=/opt/keycloak/bin/kc.sh start-dev
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable keycloak
systemctl start keycloak

# ---- Realm / 그룹 / 사용자 / SAML Client 구성 ----
KCADM=/opt/keycloak/bin/kcadm.sh
export JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto

for i in $(seq 1 60); do
  if curl -sf http://localhost:8080/realms/master >/dev/null 2>&1; then break; fi
  sleep 5
done

$KCADM config credentials --server http://localhost:8080 --realm master --user admin --password "$${ADMIN_PW}"

# Realm
$KCADM create realms -s realm="$${REALM}" -s enabled=true || true

# Groups
$KCADM create groups -r "$${REALM}" -s name=dev-team || true
$KCADM create groups -r "$${REALM}" -s name=infra-team || true

DEV_GID=$($KCADM get groups -r "$${REALM}" -q search=dev-team --fields id,name | jq -r '.[]|select(.name=="dev-team")|.id')
INFRA_GID=$($KCADM get groups -r "$${REALM}" -q search=infra-team --fields id,name | jq -r '.[]|select(.name=="infra-team")|.id')

# 그룹별 SAML Role 속성 (AWS Role 형식: roleARN,providerARN)
$KCADM update "groups/$${DEV_GID}" -r "$${REALM}" -s "attributes.role=[\"$${DEV_SAML_ROLE}\"]" || true
$KCADM update "groups/$${INFRA_GID}" -r "$${REALM}" -s "attributes.role=[\"$${INFRA_SAML_ROLE}\"]" || true

# Users
$KCADM create users -r "$${REALM}" -s username=dev-user -s enabled=true -s emailVerified=true || true
$KCADM set-password -r "$${REALM}" --username dev-user -p "$${DEV_USER_PW}"
DEV_UID=$($KCADM get users -r "$${REALM}" -q username=dev-user --fields id,username | jq -r '.[0].id')
$KCADM update "users/$${DEV_UID}/groups/$${DEV_GID}" -r "$${REALM}" -s realm="$${REALM}" -s userId="$${DEV_UID}" -s groupId="$${DEV_GID}" -n || true

$KCADM create users -r "$${REALM}" -s username=infra-user -s enabled=true -s emailVerified=true || true
$KCADM set-password -r "$${REALM}" --username infra-user -p "$${INFRA_USER_PW}"
INFRA_UID=$($KCADM get users -r "$${REALM}" -q username=infra-user --fields id,username | jq -r '.[0].id')
$KCADM update "users/$${INFRA_UID}/groups/$${INFRA_GID}" -r "$${REALM}" -s realm="$${REALM}" -s userId="$${INFRA_UID}" -s groupId="$${INFRA_GID}" -n || true

# ---- AWS SAML Client ----
CID=$($KCADM create clients -r "$${REALM}" \
  -s clientId="urn:amazon:webservices" \
  -s protocol=saml \
  -s enabled=true \
  -s 'redirectUris=["https://signin.aws.amazon.com/saml"]' \
  -s 'attributes."saml.assertion.signature"=true' \
  -s 'attributes."saml_name_id_format"=transient' \
  -s 'attributes."saml.client.signature"=false' \
  -i) || CID=""

if [ -n "$${CID}" ]; then
  # Role list 매퍼 (그룹 attribute role -> AWS Role attribute)
  $KCADM create "clients/$${CID}/protocol-mappers/models" -r "$${REALM}" \
    -s name=session-role \
    -s protocol=saml \
    -s protocolMapper=saml-group-membership-mapper \
    -s 'config."attribute.name"=https://aws.amazon.com/SAML/Attributes/Role' \
    -s 'config."attribute.nameformat"=URI Reference' \
    -s 'config."single"=true' \
    -s 'config."full.path"=false' || true

  # 사용자 속성 role -> Role attribute (그룹 attribute 기반)
  $KCADM create "clients/$${CID}/protocol-mappers/models" -r "$${REALM}" \
    -s name=aws-role \
    -s protocol=saml \
    -s protocolMapper=saml-user-attribute-mapper \
    -s 'config."user.attribute"=role' \
    -s 'config."attribute.name"=https://aws.amazon.com/SAML/Attributes/Role' \
    -s 'config."attribute.nameformat"=URI Reference' \
    -s 'config."aggregate.attrs"=true' || true

  # RoleSessionName 매퍼 (username)
  $KCADM create "clients/$${CID}/protocol-mappers/models" -r "$${REALM}" \
    -s name=session-name \
    -s protocol=saml \
    -s protocolMapper=saml-user-property-mapper \
    -s 'config."user.attribute"=username' \
    -s 'config."attribute.name"=https://aws.amazon.com/SAML/Attributes/RoleSessionName' \
    -s 'config."attribute.nameformat"=URI Reference' || true

  # SessionDuration 매퍼 (3600초)
  $KCADM create "clients/$${CID}/protocol-mappers/models" -r "$${REALM}" \
    -s name=session-duration \
    -s protocol=saml \
    -s protocolMapper=saml-hardcode-attribute-mapper \
    -s 'config."attribute.name"=https://aws.amazon.com/SAML/Attributes/SessionDuration' \
    -s 'config."attribute.nameformat"=URI Reference' \
    -s 'config."attribute.value"=3600' || true
fi

echo "KEYCLOAK SETUP COMPLETE"
