#!/usr/bin/env python3
"""
Terraform Import Helper
-----------------------
terraform apply 시 'EntityAlreadyExists' 같은 에러가 뜨면,
에러 메시지를 통째로 붙여넣어 어떤 import 명령어를 실행해야 하는지 알려준다.

실행:
    pip install flask
    python app.py
    -> http://127.0.0.1:5000
"""
import re
from flask import Flask, request, render_template_string

app = Flask(__name__)

# ---------------------------------------------------------------------------
# 리소스 주소 -> import 정보
#   lookup     : import ID를 구하는 aws CLI 명령어 (없으면 None = 이름 고정)
#   import_id  : terraform import 에 넣을 ID (쉘 변수 또는 고정 문자열)
# ---------------------------------------------------------------------------
RESOURCES = {
    # ---------- VPC ----------
    "module.VPC.aws_vpc.unicorn": {
        "lookup": 'VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=unicorn-vpc --query "Vpcs[0].VpcId" --output text)',
        "import_id": "$VPC_ID",
    },
    "module.VPC.aws_subnet.public[0]": {
        "lookup": 'PUB_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-a --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PUB_A",
    },
    "module.VPC.aws_subnet.public[1]": {
        "lookup": 'PUB_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-b --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PUB_B",
    },
    "module.VPC.aws_subnet.public[2]": {
        "lookup": 'PUB_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-pub-c --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PUB_C",
    },
    "module.VPC.aws_subnet.private[0]": {
        "lookup": 'PRIV_A=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-a --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PRIV_A",
    },
    "module.VPC.aws_subnet.private[1]": {
        "lookup": 'PRIV_B=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-b --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PRIV_B",
    },
    "module.VPC.aws_subnet.private[2]": {
        "lookup": 'PRIV_C=$(aws ec2 describe-subnets --filters Name=tag:Name,Values=unicorn-subnet-priv-c --query "Subnets[0].SubnetId" --output text)',
        "import_id": "$PRIV_C",
    },
    "module.VPC.aws_internet_gateway.unicorn": {
        "lookup": 'IGW=$(aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=unicorn-igw --query "InternetGateways[0].InternetGatewayId" --output text)',
        "import_id": "$IGW",
    },
    "module.VPC.aws_eip.nat[0]": {
        "lookup": 'EIP_A=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-a --query "Addresses[0].AllocationId" --output text)',
        "import_id": "$EIP_A",
    },
    "module.VPC.aws_eip.nat[1]": {
        "lookup": 'EIP_B=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-b --query "Addresses[0].AllocationId" --output text)',
        "import_id": "$EIP_B",
    },
    "module.VPC.aws_eip.nat[2]": {
        "lookup": 'EIP_C=$(aws ec2 describe-addresses --filters Name=tag:Name,Values=unicorn-eip-nat-c --query "Addresses[0].AllocationId" --output text)',
        "import_id": "$EIP_C",
    },
    "module.VPC.aws_nat_gateway.unicorn[0]": {
        "lookup": 'NAT_A=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-a --query "NatGateways[0].NatGatewayId" --output text)',
        "import_id": "$NAT_A",
    },
    "module.VPC.aws_nat_gateway.unicorn[1]": {
        "lookup": 'NAT_B=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-b --query "NatGateways[0].NatGatewayId" --output text)',
        "import_id": "$NAT_B",
    },
    "module.VPC.aws_nat_gateway.unicorn[2]": {
        "lookup": 'NAT_C=$(aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=unicorn-nat-c --query "NatGateways[0].NatGatewayId" --output text)',
        "import_id": "$NAT_C",
    },
    "module.VPC.aws_route_table.public": {
        "lookup": 'RT_PUB=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-pub --query "RouteTables[0].RouteTableId" --output text)',
        "import_id": "$RT_PUB",
    },
    "module.VPC.aws_route_table.private[0]": {
        "lookup": 'RT_PRIV_A=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-a --query "RouteTables[0].RouteTableId" --output text)',
        "import_id": "$RT_PRIV_A",
    },
    "module.VPC.aws_route_table.private[1]": {
        "lookup": 'RT_PRIV_B=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-b --query "RouteTables[0].RouteTableId" --output text)',
        "import_id": "$RT_PRIV_B",
    },
    "module.VPC.aws_route_table.private[2]": {
        "lookup": 'RT_PRIV_C=$(aws ec2 describe-route-tables --filters Name=tag:Name,Values=unicorn-rt-priv-c --query "RouteTables[0].RouteTableId" --output text)',
        "import_id": "$RT_PRIV_C",
    },
    "module.VPC.aws_route_table_association.public[0]": {
        "lookup": "# 위 PUB_A, RT_PUB 변수 필요",
        "import_id": "$PUB_A/$RT_PUB",
    },
    "module.VPC.aws_route_table_association.public[1]": {
        "lookup": "# 위 PUB_B, RT_PUB 변수 필요",
        "import_id": "$PUB_B/$RT_PUB",
    },
    "module.VPC.aws_route_table_association.public[2]": {
        "lookup": "# 위 PUB_C, RT_PUB 변수 필요",
        "import_id": "$PUB_C/$RT_PUB",
    },
    "module.VPC.aws_route_table_association.private[0]": {
        "lookup": "# 위 PRIV_A, RT_PRIV_A 변수 필요",
        "import_id": "$PRIV_A/$RT_PRIV_A",
    },
    "module.VPC.aws_route_table_association.private[1]": {
        "lookup": "# 위 PRIV_B, RT_PRIV_B 변수 필요",
        "import_id": "$PRIV_B/$RT_PRIV_B",
    },
    "module.VPC.aws_route_table_association.private[2]": {
        "lookup": "# 위 PRIV_C, RT_PRIV_C 변수 필요",
        "import_id": "$PRIV_C/$RT_PRIV_C",
    },
    "module.VPC.aws_flow_log.unicorn": {
        "lookup": 'FLOWLOG=$(aws ec2 describe-flow-logs --filter Name=resource-id,Values=$VPC_ID --query "FlowLogs[0].FlowLogId" --output text)',
        "import_id": "$FLOWLOG",
    },
    "module.VPC.aws_cloudwatch_log_group.flow_log": {
        "lookup": None,
        "import_id": "/aws/vpc-flow-log/unicorn-vpc",
    },
    "module.VPC.aws_iam_role.flow_log": {
        "lookup": None,
        "import_id": "unicorn-vpc-flow-log-role",
    },
    "module.VPC.aws_iam_role_policy.flow_log": {
        "lookup": None,
        "import_id": "unicorn-vpc-flow-log-role:unicorn-vpc-flow-log-policy",
    },
    "module.VPC.aws_security_group.vpc_endpoint": {
        "lookup": 'SG_VPCE=$(aws ec2 describe-security-groups --filters Name=tag:Name,Values=unicorn-vpc-vpce-sg --query "SecurityGroups[0].GroupId" --output text)',
        "import_id": "$SG_VPCE",
    },
    "module.VPC.aws_vpc_endpoint.s3": {
        "lookup": 'VPCE_S3=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.ap-northeast-2.s3 --query "VpcEndpoints[0].VpcEndpointId" --output text)',
        "import_id": "$VPCE_S3",
    },
    "module.VPC.aws_vpc_endpoint.ecr_api": {
        "lookup": 'VPCE_ECR_API=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.ap-northeast-2.ecr.api --query "VpcEndpoints[0].VpcEndpointId" --output text)',
        "import_id": "$VPCE_ECR_API",
    },
    "module.VPC.aws_vpc_endpoint.ecr_dkr": {
        "lookup": 'VPCE_ECR_DKR=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$VPC_ID Name=service-name,Values=com.amazonaws.ap-northeast-2.ecr.dkr --query "VpcEndpoints[0].VpcEndpointId" --output text)',
        "import_id": "$VPCE_ECR_DKR",
    },

    # ---------- KMS ----------
    "module.KMS.aws_kms_key.app": {
        "lookup": 'KMS_APP=$(aws kms describe-key --key-id alias/unicorn-kms-app --query "KeyMetadata.KeyId" --output text)',
        "import_id": "$KMS_APP",
    },
    "module.KMS.aws_kms_key.data": {
        "lookup": 'KMS_DATA=$(aws kms describe-key --key-id alias/unicorn-kms-data --query "KeyMetadata.KeyId" --output text)',
        "import_id": "$KMS_DATA",
    },
    "module.KMS.aws_kms_key.platform": {
        "lookup": 'KMS_PLATFORM=$(aws kms describe-key --key-id alias/unicorn-kms-platform --query "KeyMetadata.KeyId" --output text)',
        "import_id": "$KMS_PLATFORM",
    },
    "module.KMS.aws_kms_alias.app": {
        "lookup": None,
        "import_id": "alias/unicorn-kms-app",
    },
    "module.KMS.aws_kms_alias.data": {
        "lookup": None,
        "import_id": "alias/unicorn-kms-data",
    },
    "module.KMS.aws_kms_alias.platform": {
        "lookup": None,
        "import_id": "alias/unicorn-kms-platform",
    },
    "module.KMS.aws_kms_replica_key.platform_replica": {
        "lookup": 'KMS_REPLICA=$(aws kms describe-key --key-id alias/unicorn-kms-platform --region us-east-1 --query "KeyMetadata.KeyId" --output text)',
        "import_id": "$KMS_REPLICA",
    },
    "module.KMS.aws_kms_alias.platform_replica": {
        "lookup": None,
        "import_id": "alias/unicorn-kms-platform",
        "note": "us-east-1 리전 alias (replica). 필요 시 --provider 또는 별도 리전 주의.",
    },

    # ---------- S3 ----------
    "module.S3.aws_s3_bucket.frontend": {
        "lookup": 'BUCKET=unicorn-web-$(aws sts get-caller-identity --query Account --output text)',
        "import_id": "$BUCKET",
    },
    "module.S3.aws_s3_bucket_versioning.frontend": {
        "lookup": 'BUCKET=unicorn-web-$(aws sts get-caller-identity --query Account --output text)',
        "import_id": "$BUCKET",
    },
    "module.S3.aws_s3_bucket_server_side_encryption_configuration.frontend": {
        "lookup": 'BUCKET=unicorn-web-$(aws sts get-caller-identity --query Account --output text)',
        "import_id": "$BUCKET",
    },
    "module.S3.aws_s3_bucket_public_access_block.frontend": {
        "lookup": 'BUCKET=unicorn-web-$(aws sts get-caller-identity --query Account --output text)',
        "import_id": "$BUCKET",
    },
    "module.CloudFront.aws_s3_bucket_policy.cloudfront": {
        "lookup": 'BUCKET=unicorn-web-$(aws sts get-caller-identity --query Account --output text)',
        "import_id": "$BUCKET",
    },
    "aws_s3_bucket.manifest": {
        "lookup": "MANIFEST_BUCKET=$(aws s3 ls | grep unicorn-manifest | awk '{print $3}')",
        "import_id": "$MANIFEST_BUCKET",
    },

    # ---------- DynamoDB / ECR ----------
    "module.DynamoDB.aws_dynamodb_table.concert": {
        "lookup": None,
        "import_id": "unicorn-concert-db",
    },
    "module.ECR.aws_ecr_repository.concert_app": {
        "lookup": None,
        "import_id": "unicorn-concert-app",
    },

    # ---------- Lambda ----------
    "module.Lambda.aws_lambda_function.this": {
        "lookup": None,
        "import_id": "unicorn-get-booking-func",
    },
    "module.Lambda.aws_cloudwatch_log_group.lambda": {
        "lookup": None,
        "import_id": "/unicorn/lambda/get-booking",
    },
    "module.Lambda.aws_iam_role.lambda": {
        "lookup": None,
        "import_id": "unicorn-get-booking-func-role",
    },
    "module.Lambda.aws_iam_role_policy.lambda": {
        "lookup": None,
        "import_id": "unicorn-get-booking-func-role:unicorn-get-booking-func-policy",
    },
    "module.Lambda.aws_security_group.lambda": {
        "lookup": 'LAMBDA_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-get-booking-func-sg --query "SecurityGroups[0].GroupId" --output text)',
        "import_id": "$LAMBDA_SG",
    },

    # ---------- ALB ----------
    "module.ALB.aws_lb.this": {
        "lookup": 'ALB_ARN=$(aws elbv2 describe-load-balancers --names unicorn-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)',
        "import_id": "$ALB_ARN",
    },
    "module.ALB.aws_security_group.alb": {
        "lookup": 'ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-alb-sg --query "SecurityGroups[0].GroupId" --output text)',
        "import_id": "$ALB_SG",
    },
    "module.ALB.aws_lb_target_group.app": {
        "lookup": 'TG_APP_ARN=$(aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text)',
        "import_id": "$TG_APP_ARN",
    },
    "module.ALB.aws_lb_target_group.lambda": {
        "lookup": 'TG_LAMBDA_ARN=$(aws elbv2 describe-target-groups --names unicorn-alb-lambda-tg --query "TargetGroups[0].TargetGroupArn" --output text)',
        "import_id": "$TG_LAMBDA_ARN",
    },
    "module.ALB.aws_lb_listener.http": {
        "lookup": 'LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[0].ListenerArn" --output text)',
        "import_id": "$LISTENER_ARN",
    },
    "module.ALB.aws_lb_listener_rule.health": {
        "lookup": 'RULE_HEALTH_ARN=$(aws elbv2 describe-rules --listener-arn $LISTENER_ARN --query "Rules[?Priority==\'5\'].RuleArn" --output text)',
        "import_id": "$RULE_HEALTH_ARN",
    },
    "module.ALB.aws_lb_listener_rule.lambda_get": {
        "lookup": 'RULE_LAMBDA_ARN=$(aws elbv2 describe-rules --listener-arn $LISTENER_ARN --query "Rules[?Priority==\'10\'].RuleArn" --output text)',
        "import_id": "$RULE_LAMBDA_ARN",
    },

    # ---------- CloudFront / WAF ----------
    "module.CloudFront.aws_cloudfront_distribution.this": {
        "lookup": 'CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment==\'unicorn-svc-cf\'].Id|[0]" --output text)',
        "import_id": "$CF_ID",
    },
    "module.CloudFront.aws_cloudfront_origin_access_control.s3": {
        "lookup": 'OAC_ID=$(aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name==\'s3-oac\'].Id|[0]" --output text)',
        "import_id": "$OAC_ID",
    },
    "module.CloudFront.aws_cloudfront_vpc_origin.alb": {
        "lookup": 'VPC_ORIGIN_ID=$(aws cloudfront list-vpc-origins --query "VpcOriginList.Items[?Name==\'app-origin\'].Id|[0]" --output text)',
        "import_id": "$VPC_ORIGIN_ID",
    },
    "module.CloudFront.aws_cloudwatch_log_group.waf": {
        "lookup": None,
        "import_id": "aws-waf-logs-unicorn",
        "note": "us-east-1 리전 로그 그룹",
    },
    "module.CloudFront.aws_wafv2_web_acl.this": {
        "lookup": 'WAF_ID=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name==\'unicorn-waf\'].Id|[0]" --output text)',
        "import_id": "$WAF_ID/unicorn-waf/CLOUDFRONT",
    },
    "module.CloudFront.aws_wafv2_web_acl_logging_configuration.this": {
        "lookup": 'WAF_ARN=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 --query "WebACLs[?Name==\'unicorn-waf\'].ARN|[0]" --output text)',
        "import_id": "$WAF_ARN",
    },

    # ---------- IAM / Security ----------
    "module.IAM.aws_iam_role.audit": {
        "lookup": None,
        "import_id": "unicorn-audit-role",
    },
    "module.IAM.aws_iam_role_policy.audit": {
        "lookup": None,
        "import_id": "unicorn-audit-role:unicorn-audit-role-policy",
    },
    "aws_iam_role.book_app": {
        "lookup": None,
        "import_id": "unicorn-book-app-role",
    },
    "aws_iam_role_policy.book_app": {
        "lookup": None,
        "import_id": "unicorn-book-app-role:unicorn-book-app-policy",
    },

    # ---------- CloudWatch / 기타 ----------
    "aws_cloudwatch_log_group.book_app": {
        "lookup": None,
        "import_id": "/unicorn/eks/book-app",
    },
    "aws_security_group.cloudshell": {
        "lookup": 'CLOUDSHELL_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-mark-sg --query "SecurityGroups[0].GroupId" --output text)',
        "import_id": "$CLOUDSHELL_SG",
    },
    "aws_security_group.grafana_alb": {
        "lookup": 'G_ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=unicorn-grafana-alb-sg --query "SecurityGroups[0].GroupId" --output text)',
        "import_id": "$G_ALB_SG",
    },
    "aws_lb.grafana": {
        "lookup": 'G_ALB_ARN=$(aws elbv2 describe-load-balancers --names unicorn-grafana-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)',
        "import_id": "$G_ALB_ARN",
    },
    "aws_lb_target_group.grafana": {
        "lookup": 'G_TG_ARN=$(aws elbv2 describe-target-groups --names unicorn-grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text)',
        "import_id": "$G_TG_ARN",
    },
    "aws_lb_listener.grafana": {
        "lookup": 'G_LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $G_ALB_ARN --query "Listeners[0].ListenerArn" --output text)',
        "import_id": "$G_LISTENER_ARN",
    },
}


def parse_addresses(error_text):
    """terraform 에러 텍스트에서 리소스 주소를 추출한다."""
    addrs = []
    # "with <addr>," 패턴 (가장 정확)
    for m in re.finditer(r'with\s+([a-zA-Z0-9_.\[\]"\-]+?),', error_text):
        addrs.append(m.group(1).strip())
    # 보조: 직접 주소를 붙여넣은 경우
    if not addrs:
        for line in error_text.splitlines():
            line = line.strip()
            if re.fullmatch(r'(module\.[\w]+\.)?aws_[\w]+\.[\w\[\]]+', line):
                addrs.append(line)
    # 중복 제거(순서 유지)
    seen = set()
    out = []
    for a in addrs:
        if a not in seen:
            seen.add(a)
            out.append(a)
    return out


def build_commands(addr, number="<비번호>"):
    info = RESOURCES.get(addr)
    tf = f'terraform import -var="number={number}"'
    if not info:
        return None
    lines = []
    if info.get("lookup"):
        lines.append(info["lookup"])
    import_id = info["import_id"]
    # 쉘 변수($)나 / 가 들어가면 따옴표로 감싼다
    if "$" in import_id or "/" in import_id:
        import_id_q = f'"{import_id}"'
    else:
        import_id_q = import_id
    lines.append(f'{tf} {addr} {import_id_q}')
    return {"commands": "\n".join(lines), "note": info.get("note")}


TEMPLATE = """
<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<title>Terraform Import Helper</title>
<style>
  body { font-family: -apple-system, "Segoe UI", sans-serif; max-width: 900px;
         margin: 40px auto; padding: 0 16px; background:#0d1117; color:#c9d1d9; }
  h1 { font-size: 22px; }
  textarea { width: 100%; height: 200px; font-family: monospace; font-size: 13px;
             background:#161b22; color:#c9d1d9; border:1px solid #30363d;
             border-radius:6px; padding:10px; box-sizing:border-box; }
  input[type=text] { background:#161b22; color:#c9d1d9; border:1px solid #30363d;
             border-radius:6px; padding:6px 10px; }
  button { background:#238636; color:#fff; border:none; padding:10px 20px;
           border-radius:6px; font-size:14px; cursor:pointer; margin-top:10px; }
  button:hover { background:#2ea043; }
  .card { background:#161b22; border:1px solid #30363d; border-radius:6px;
          padding:14px 16px; margin:14px 0; }
  .addr { color:#58a6ff; font-family:monospace; font-weight:bold; }
  pre { background:#0d1117; border:1px solid #30363d; border-radius:6px;
        padding:12px; overflow-x:auto; font-size:13px; white-space:pre-wrap;
        word-break:break-all; }
  .note { color:#d29922; font-size:13px; margin-top:6px; }
  .miss { color:#f85149; }
  .row { display:flex; gap:16px; align-items:center; margin-bottom:8px; flex-wrap:wrap; }
  label { font-size:13px; }
  a.copy { font-size:12px; color:#58a6ff; cursor:pointer; }
</style>
</head>
<body>
<h1>🛠️ Terraform Import Helper</h1>
<p>terraform apply 시 <code>EntityAlreadyExists</code> 등의 에러 메시지를 통째로 붙여넣으세요.
   해당 리소스를 import 하는 명령어를 알려줍니다.</p>
<form method="post">
  <div class="row">
    <label>비번호: <input type="text" name="number" value="{{ number }}" size="8"></label>
  </div>
  <textarea name="error" placeholder="여기에 terraform 에러 전체를 붙여넣기...">{{ error_text }}</textarea>
  <br>
  <button type="submit">Import 명령어 생성</button>
</form>

{% if results is not none %}
  <h2>결과 ({{ results|length }}개 리소스)</h2>
  {% if results|length == 0 %}
    <div class="card miss">인식된 리소스 주소가 없습니다. 에러에 <code>with &lt;주소&gt;,</code> 줄이 포함됐는지 확인하세요.</div>
  {% endif %}
  {% for r in results %}
    <div class="card">
      <div class="addr">{{ r.addr }}</div>
      {% if r.commands %}
        <pre id="cmd{{ loop.index }}">{{ r.commands }}</pre>
        {% if r.note %}<div class="note">⚠️ {{ r.note }}</div>{% endif %}
      {% else %}
        <div class="miss">매핑된 import 정보가 없습니다. (state에서 빠졌거나 신규 리소스)</div>
      {% endif %}
    </div>
  {% endfor %}

  {% if all_commands %}
    <h2>전체 명령어 (한 번에 복사)</h2>
    <pre>{{ all_commands }}</pre>
  {% endif %}
{% endif %}

</body>
</html>
"""


@app.route("/", methods=["GET", "POST"])
def index():
    error_text = ""
    number = "<비번호>"
    results = None
    all_commands = ""
    if request.method == "POST":
        error_text = request.form.get("error", "")
        number = request.form.get("number", "<비번호>").strip() or "<비번호>"
        addrs = parse_addresses(error_text)
        results = []
        cmd_blocks = []
        for addr in addrs:
            built = build_commands(addr, number)
            if built:
                results.append({"addr": addr, "commands": built["commands"], "note": built.get("note")})
                cmd_blocks.append(built["commands"])
            else:
                results.append({"addr": addr, "commands": None, "note": None})
        all_commands = "\n\n".join(cmd_blocks)
    return render_template_string(
        TEMPLATE, error_text=error_text, number=number,
        results=results, all_commands=all_commands,
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
