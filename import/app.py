#!/usr/bin/env python3
"""
Terraform Import Helper (generic)
---------------------------------
terraform apply 시 "이미 존재함"(EntityAlreadyExists, AlreadyExists,
BucketAlreadyOwnedByYou ...) 에러가 뜨면, 에러 메시지를 통째로 붙여넣어
어떤 `terraform import` 명령어를 실행해야 하는지 알려준다.

어느 terraform 프로젝트에서도 동작하도록 리소스 "타입"별 import ID 포맷을 사용한다.
에러 메시지에서 실제 리소스 이름을 자동 추출하며(보통 괄호 안),
추출되지 않는 경우 해당 타입의 import ID 포맷/조회 힌트를 안내한다.

실행:
    pip install -r requirements.txt
    python app.py
    -> http://127.0.0.1:5000
"""
import re
from flask import Flask, request, render_template_string

app = Flask(__name__)

# ---------------------------------------------------------------------------
# 리소스 "타입" -> import ID 사용법
#   id_kind : import ID 가 무엇인지 (사람이 읽는 설명)
#   needs   : 에러에서 이름이 안 잡힐 때 ID 를 구하는 힌트(aws CLI 등)
#   from_err: True 면 에러 괄호 안의 이름을 그대로 import ID 로 쓸 수 있음
# Terraform AWS provider 의 대표적인 import 규칙을 정리한 것.
# ---------------------------------------------------------------------------
TYPE_SPECS = {
    # name 기반 (에러 괄호 안 이름을 그대로 사용 가능)
    "aws_iam_role":                  {"id_kind": "Role 이름", "from_err": True},
    "aws_iam_policy":                {"id_kind": "Policy ARN", "from_err": False,
                                      "needs": 'aws iam list-policies --query "Policies[?PolicyName==\'<name>\'].Arn" --output text'},
    "aws_iam_user":                  {"id_kind": "User 이름", "from_err": True},
    "aws_iam_group":                 {"id_kind": "Group 이름", "from_err": True},
    "aws_iam_instance_profile":      {"id_kind": "Instance Profile 이름", "from_err": True},
    "aws_iam_role_policy":           {"id_kind": "role_name:policy_name 형식", "from_err": False,
                                      "needs": "인라인 정책 → <role이름>:<정책이름> 으로 입력"},
    "aws_iam_role_policy_attachment":{"id_kind": "role_name/policy_arn 형식", "from_err": False,
                                      "needs": "<role이름>/<정책 ARN> 으로 입력 (정책 ARN: aws iam list-policies --query \"Policies[?PolicyName=='<name>'].Arn\" --output text)"},
    "aws_s3_bucket":                 {"id_kind": "버킷 이름", "from_err": True},
    "aws_s3_bucket_versioning":      {"id_kind": "버킷 이름", "from_err": True},
    "aws_s3_bucket_policy":          {"id_kind": "버킷 이름", "from_err": True},
    "aws_s3_bucket_public_access_block": {"id_kind": "버킷 이름", "from_err": True},
    "aws_s3_bucket_server_side_encryption_configuration": {"id_kind": "버킷 이름", "from_err": True},
    "aws_s3_bucket_lifecycle_configuration": {"id_kind": "버킷 이름", "from_err": True},
    "aws_dynamodb_table":            {"id_kind": "테이블 이름", "from_err": True},
    "aws_ecr_repository":            {"id_kind": "레포 이름", "from_err": True},
    "aws_lambda_function":           {"id_kind": "함수 이름", "from_err": True},
    "aws_cloudwatch_log_group":      {"id_kind": "로그 그룹 이름", "from_err": True},
    "aws_sns_topic":                 {"id_kind": "Topic ARN", "from_err": False,
                                      "needs": 'aws sns list-topics --query "Topics[?ends_with(TopicArn, \':<name>\')].TopicArn|[0]" --output text'},
    "aws_sqs_queue":                 {"id_kind": "Queue URL", "from_err": False,
                                      "needs": 'aws sqs get-queue-url --queue-name <name> --query QueueUrl --output text'},
    "aws_secretsmanager_secret":     {"id_kind": "Secret ARN 또는 이름", "from_err": True},
    "aws_kms_alias":                 {"id_kind": "alias/<이름>", "from_err": True},
    "aws_db_instance":               {"id_kind": "DB identifier", "from_err": True},
    "aws_eks_cluster":               {"id_kind": "클러스터 이름", "from_err": True},
    "aws_eks_node_group":            {"id_kind": "cluster:nodegroup 형식", "from_err": False,
                                      "needs": '<클러스터이름>:<노드그룹이름> (조회: aws eks list-nodegroups --cluster-name <cluster> --query "nodegroups" --output text)'},
    "aws_ecs_cluster":               {"id_kind": "클러스터 이름 또는 ARN", "from_err": True},
    "aws_route53_zone":              {"id_kind": "Hosted Zone ID", "from_err": False,
                                      "needs": 'aws route53 list-hosted-zones-by-name --dns-name <name> --query "HostedZones[0].Id" --output text'},

    # ID 기반 (에러에 ID 가 없으면 aws CLI 로 조회 필요)
    "aws_kms_key":                   {"id_kind": "Key ID", "from_err": False,
                                      "needs": 'aws kms describe-key --key-id alias/<alias> --query "KeyMetadata.KeyId" --output text'},
    "aws_kms_replica_key":           {"id_kind": "Key ID", "from_err": False,
                                      "needs": 'aws kms list-aliases --query "Aliases[?AliasName==\'alias/<alias>\'].TargetKeyId|[0]" --output text'},
    "aws_vpc":                       {"id_kind": "VPC ID (vpc-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-vpcs --filters Name=tag:Name,Values=<name> --query "Vpcs[0].VpcId" --output text'},
    "aws_subnet":                    {"id_kind": "Subnet ID (subnet-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-subnets --filters Name=tag:Name,Values=<name> --query "Subnets[0].SubnetId" --output text'},
    "aws_internet_gateway":          {"id_kind": "IGW ID (igw-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-internet-gateways --filters Name=tag:Name,Values=<name> --query "InternetGateways[0].InternetGatewayId" --output text'},
    "aws_nat_gateway":               {"id_kind": "NAT GW ID (nat-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-nat-gateways --filter Name=tag:Name,Values=<name> --query "NatGateways[0].NatGatewayId" --output text'},
    "aws_eip":                       {"id_kind": "Allocation ID (eipalloc-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-addresses --filters Name=tag:Name,Values=<name> --query "Addresses[0].AllocationId" --output text'},
    "aws_route_table":               {"id_kind": "Route Table ID (rtb-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-route-tables --filters Name=tag:Name,Values=<name> --query "RouteTables[0].RouteTableId" --output text'},
    "aws_route_table_association":   {"id_kind": "subnet_id/route_table_id 형식", "from_err": False,
                                      "needs": '<subnet-id>/<rtb-id> 으로 입력 (subnet: aws ec2 describe-subnets ..., rtb: aws ec2 describe-route-tables ...)'},
    "aws_security_group":            {"id_kind": "SG ID (sg-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-security-groups --filters Name=group-name,Values=<name> --query "SecurityGroups[0].GroupId" --output text'},
    "aws_security_group_rule":       {"id_kind": "sg-...연결된 복합 ID", "from_err": False,
                                      "needs": "보통 import 대신 apply 로 재생성 권장"},
    "aws_flow_log":                  {"id_kind": "Flow Log ID (fl-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-flow-logs --filter Name=resource-id,Values=<vpc-id> --query "FlowLogs[0].FlowLogId" --output text'},
    "aws_vpc_endpoint":              {"id_kind": "VPC Endpoint ID (vpce-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-vpc-endpoints --filters Name=tag:Name,Values=<name> --query "VpcEndpoints[0].VpcEndpointId" --output text'},
    "aws_instance":                  {"id_kind": "Instance ID (i-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-instances --filters Name=tag:Name,Values=<name> --query "Reservations[0].Instances[0].InstanceId" --output text'},
    "aws_lb":                        {"id_kind": "LB ARN", "from_err": False,
                                      "needs": 'aws elbv2 describe-load-balancers --names <name> --query "LoadBalancers[0].LoadBalancerArn" --output text'},
    "aws_lb_target_group":           {"id_kind": "Target Group ARN", "from_err": False,
                                      "needs": 'aws elbv2 describe-target-groups --names <name> --query "TargetGroups[0].TargetGroupArn" --output text'},
    "aws_lb_listener":               {"id_kind": "Listener ARN", "from_err": False,
                                      "needs": 'aws elbv2 describe-listeners --load-balancer-arn <lb-arn> --query "Listeners[0].ListenerArn" --output text'},
    "aws_lb_listener_rule":          {"id_kind": "Rule ARN", "from_err": False,
                                      "needs": 'aws elbv2 describe-rules --listener-arn <listener-arn> --query "Rules[0].RuleArn" --output text'},
    "aws_cloudfront_distribution":   {"id_kind": "Distribution ID", "from_err": False,
                                      "needs": 'aws cloudfront list-distributions --query "DistributionList.Items[?Comment==\'<comment>\'].Id|[0]" --output text'},
    "aws_cloudfront_origin_access_control": {"id_kind": "OAC ID", "from_err": False,
                                      "needs": 'aws cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?Name==\'<name>\'].Id|[0]" --output text'},
    "aws_cloudfront_function":       {"id_kind": "함수 이름", "from_err": True,
                                      "needs": 'aws cloudfront list-functions --query "FunctionList.Items[?Name==\'<name>\'].Name|[0]" --output text'},
    "aws_wafv2_web_acl":             {"id_kind": "WebACL ID (id/name/scope)", "from_err": False,
                                      "needs": 'aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name==\'<name>\'].Id|[0]" --output text',
                                      "id_tmpl": "{var}/<name>/REGIONAL"},
    "aws_launch_template":           {"id_kind": "Launch Template ID (lt-...)", "from_err": False,
                                      "needs": 'aws ec2 describe-launch-templates --filters Name=launch-template-name,Values=<name> --query "LaunchTemplates[0].LaunchTemplateId" --output text'},
    "aws_eks_access_entry":          {"id_kind": "cluster_name:principal_arn 형식", "from_err": False,
                                      "needs": '형식 <cluster>:<principal_arn> — 목록: aws eks list-access-entries --cluster-name <cluster> --query "accessEntries" --output text'},
    "aws_eks_access_policy_association": {"id_kind": "cluster_name#principal_arn#policy_arn 형식", "from_err": False,
                                      "needs": '형식 <cluster>#<principal_arn>#<policy_arn> — 목록: aws eks list-associated-access-policies --cluster-name <cluster> --principal-arn <arn>'},
}


def parse_blocks(error_text):
    """
    terraform 에러를 'Error:' 단위 블록으로 쪼개고,
    각 블록에서 (리소스 주소, 에러 괄호 안 이름)을 추출한다.
    """
    # 'Error:' 로 분할 (첫 조각은 버려질 수 있음)
    raw_blocks = re.split(r'(?=Error:)', error_text)
    results = []
    seen = set()
    for blk in raw_blocks:
        # 리소스 주소 ('with <주소>,' 줄 전체를 잡아 인덱스 안의 :,/,| 등도 보존)
        m_addr = re.search(r'^[\s│|]*with\s+(.+?),\s*$', blk, re.MULTILINE)
        addr = m_addr.group(1).strip() if m_addr else None
        # 주소가 없으면 단독 주소 줄 형태도 시도
        if not addr:
            m2 = re.search(r'^\s*((?:module\.[\w\-]+\.)*aws_[\w]+\.[\w\[\]"\-]+)\s*$',
                           blk, re.MULTILINE)
            addr = m2.group(1).strip() if m2 else None
        if not addr:
            continue
        # 에러 괄호 안의 이름:  "creating IAM Role (unicorn-book-app-role):"
        m_name = re.search(r'\(([^()]+?)\)\s*:', blk)
        name = m_name.group(1).strip() if m_name else None
        if addr in seen:
            continue
        seen.add(addr)
        results.append({"addr": addr, "name": name})
    return results


def type_of(addr):
    """리소스 주소에서 리소스 타입을 추출. (aws_ 외 null_resource 등도 지원)"""
    # module.X.Y.aws_type.name[idx] -> aws_type
    m = re.search(r'(aws_[a-z0-9_]+)\.', addr)
    if m:
        return m.group(1)
    # aws_ 가 아닌 타입: module 프리픽스를 제거한 뒤 첫 토큰을 타입으로
    s = re.sub(r'^(?:module\.[\w\-]+\.)+', '', addr)
    m2 = re.match(r'([a-z][a-z0-9_]*)\.', s)
    return m2.group(1) if m2 else None


def quote_addr(addr):
    """인덱스(["app"])나 공백이 포함된 주소는 bash 가 안쪽 따옴표를 벗기지 않도록
    전체를 작은따옴표로 감싼다. 예: aws_iam_role.node["app"] -> 'aws_iam_role.node["app"]'"""
    if any(c in addr for c in '["\' '):
        return "'" + addr + "'"
    return addr


def var_for(addr):
    """리소스 주소를 셸 변수명으로 변환. 예: aws_s3_bucket.static[0] -> ID_AWS_S3_BUCKET_STATIC_0"""
    safe = re.sub(r'[^a-zA-Z0-9]+', '_', addr).strip('_').upper()
    return f"ID_{safe}"


def build(block, var_pairs=None):
    addr = block["addr"]
    name = block["name"]
    rtype = type_of(addr)
    spec = TYPE_SPECS.get(rtype)

    var = ""
    for v_name, v_value in (var_pairs or []):
        if v_name and v_value:
            var += f' -var="{v_name}={v_value}"'
    tf = f"terraform import{var}"
    qaddr = quote_addr(addr)  # 인덱스/공백 있는 주소는 작은따옴표로 감쌈

    lines = []
    note = None
    if spec is None:
        if rtype in ("null_resource", "terraform_data"):
            # 실제 클라우드 자원이 아니라 import 대상이 아님 → 명령은 출력하지 않음
            note = (f"'{rtype}' 는 실제 클라우드 리소스가 아니라 import 대상이 아닙니다. "
                    f"필요하면 `terraform apply -replace='{addr}'` 로 재생성하세요.")
        elif rtype is None:
            note = ("리소스 타입을 인식하지 못했습니다. "
                    "`terraform import <리소스주소> <ID>` 형식으로 직접 import 하세요.")
            lines.append(f"{tf} {qaddr} <리소스_ID>")
        else:
            note = (f"'{rtype}' 타입의 import 규칙이 등록되어 있지 않습니다. "
                    f"`terraform import {addr} <ID>` 형식으로 직접 import 하세요. "
                    f"정확한 ID 형식은 Terraform Registry 해당 리소스 문서의 'Import' 섹션을 참고하세요.")
            lines.append(f"{tf} {qaddr} <리소스_ID>")
        return {"addr": addr, "rtype": rtype, "commands": "\n".join(lines), "note": note}

    if spec.get("from_err") and name:
        # 이름을 그대로 import ID 로 사용 가능
        import_id = name if ("/" not in name and " " not in name) else f'"{name}"'
        lines.append(f"{tf} {qaddr} {import_id}")
        note = f"import ID = {spec['id_kind']} (에러 메시지에서 '{name}' 자동 추출)"
    else:
        # ID 를 별도로 구해야 함
        needs = spec.get("needs")
        hint = needs or ""
        if name:
            hint = hint.replace("<name>", name).replace("<comment>", name)
        # needs 가 실제 실행 가능한 aws CLI 명령이면 변수에 담아 바로 import
        if needs and needs.lstrip().startswith("aws "):
            v = var_for(addr)
            lines.append(f"# {spec['id_kind']} 조회 후 변수에 저장")
            lines.append(f"{v}=$({hint})")
            # id_tmpl 로 최종 import ID 조립 ({var}=조회값, <name>=에러에서 추출한 이름)
            id_str = spec.get("id_tmpl", "{var}").replace("{var}", f"${v}")
            if name:
                id_str = id_str.replace("<name>", name)
            lines.append(f'{tf} {qaddr} "{id_str}"')
            note = (f"import ID = {spec['id_kind']}. 위 두 줄을 그대로 실행하면 "
                    f"조회한 값으로 조립된 ID 로 바로 import 됩니다.")
        else:
            if hint:
                lines.append(f"# {spec['id_kind']} 조회/형식:")
                lines.append(f"# {hint}")
            lines.append(f"{tf} {qaddr} <{spec['id_kind']}>")
            extra = f" (에러에서 '{name}' 감지)" if name else ""
            note = f"import ID = {spec['id_kind']}. 위 안내대로 실제 ID를 구해 넣으세요.{extra}"

    return {"addr": addr, "rtype": rtype, "commands": "\n".join(lines), "note": note}


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
  textarea { width: 100%; height: 220px; font-family: monospace; font-size: 13px;
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
  .rtype { color:#8b949e; font-size:12px; font-family:monospace; }
  pre { background:#0d1117; border:1px solid #30363d; border-radius:6px;
        padding:12px; overflow-x:auto; font-size:13px; white-space:pre-wrap;
        word-break:break-all; }
  .note { color:#d29922; font-size:13px; margin-top:6px; }
  .miss { color:#f85149; }
  .row { display:flex; gap:16px; align-items:center; margin-bottom:8px; flex-wrap:wrap; }
  label { font-size:13px; }
  .hint { color:#8b949e; font-size:12px; }
  .rm { background:#6e2c2c; padding:4px 10px; margin:0; font-size:12px; }
  .rm:hover { background:#8b3a3a; }
  #addVar { background:#30363d; padding:6px 14px; font-size:13px; }
  #addVar:hover { background:#3c444d; }
  .var-row { margin-bottom:6px; }
</style>
</head>
<body>
<h1>🛠️ Terraform Import Helper</h1>
<p>terraform apply 시 <code>EntityAlreadyExists</code> / <code>AlreadyExists</code> 등
   "이미 존재함" 에러를 통째로 붙여넣으세요. 어느 terraform 프로젝트든 동작합니다.</p>
<form method="post">
  <div class="row">
    <label>(선택) 변수 — 여러 개 추가 가능</label>
    <span class="hint">※ var 가 필요한 프로젝트면 변수명과 값을 모두 입력, 아니면 비워두세요.</span>
  </div>
  <div id="vars">
    {% for vp in var_pairs %}
    <div class="row var-row">
      <code>-var="</code>
      <input type="text" name="var_name" value="{{ vp[0] }}" size="12" placeholder="변수명"><code>=</code>
      <input type="text" name="var_value" value="{{ vp[1] }}" size="12" placeholder="값"><code>"</code>
      <button type="button" class="rm" onclick="this.closest('.var-row').remove()">✕</button>
    </div>
    {% endfor %}
  </div>
  <button type="button" id="addVar" onclick="addVarRow()">+ 변수 추가</button>
  <textarea name="error" placeholder="여기에 terraform 에러 전체를 붙여넣기...">{{ error_text }}</textarea>
  <br>
  <button type="submit">Import 명령어 생성</button>
</form>

{% if results is not none %}
  <h2>결과 ({{ results|length }}개 리소스)</h2>
  {% if results|length == 0 %}
    <div class="card miss">인식된 리소스 주소가 없습니다.
      에러에 <code>with &lt;주소&gt;,</code> 줄이 포함됐는지 확인하세요.</div>
  {% endif %}
  {% for r in results %}
    <div class="card">
      <div class="addr">{{ r.addr }}</div>
      <div class="rtype">{{ r.rtype }}</div>
      {% if r.commands %}<pre>{{ r.commands }}</pre>{% endif %}
      {% if r.note %}<div class="note">ℹ️ {{ r.note }}</div>{% endif %}
    </div>
  {% endfor %}

  {% if all_commands %}
    <h2>전체 명령어 (한 번에 복사)</h2>
    <pre>{{ all_commands }}</pre>
  {% endif %}
{% endif %}

<script>
function addVarRow() {
  var wrap = document.getElementById('vars');
  var div = document.createElement('div');
  div.className = 'row var-row';
  div.innerHTML = '<code>-var="</code>' +
    '<input type="text" name="var_name" size="12" placeholder="변수명"><code>=</code>' +
    '<input type="text" name="var_value" size="12" placeholder="값"><code>"</code>' +
    '<button type="button" class="rm" onclick="this.closest(\\'.var-row\\').remove()">✕</button>';
  wrap.appendChild(div);
}
// 변수 입력 행이 하나도 없으면 빈 행 하나 추가
if (!document.querySelector('.var-row')) addVarRow();
</script>
</body>
</html>
"""


@app.route("/", methods=["GET", "POST"])
def index():
    error_text = ""
    var_pairs = []
    results = None
    all_commands = ""
    if request.method == "POST":
        error_text = request.form.get("error", "")
        names = request.form.getlist("var_name")
        values = request.form.getlist("var_value")
        # 입력된 (변수명, 값) 쌍을 모두 수집 (둘 다 채워진 것만 사용)
        var_pairs = [(n.strip(), v.strip())
                     for n, v in zip(names, values)
                     if n.strip() or v.strip()]
        used_pairs = [(n, v) for n, v in var_pairs if n and v]
        blocks = parse_blocks(error_text)
        results = []
        cmd_blocks = []
        for b in blocks:
            built = build(b, used_pairs)
            results.append(built)
            if built["commands"].strip():
                cmd_blocks.append(built["commands"])
        all_commands = "\n\n".join(cmd_blocks)
    return render_template_string(
        TEMPLATE, error_text=error_text, var_pairs=var_pairs,
        results=results, all_commands=all_commands,
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
