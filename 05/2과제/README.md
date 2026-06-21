# 05 2怨쇱젣

## 紐⑤뱢 援ъ꽦

| 紐⑤뱢 | 寃쎈줈 | 由ъ쟾 | ?댁슜 |
|---|---|---|---|
| 1 | `module1/infra/` | us-east-1 | CDN (S3 + Lambda + CloudFront) |
| 2 | `module2/` | ap-southeast-1 | Kafka + Flink + NLB |
| 3 | `module3/infra/` | ap-northeast-2 | FastAPI + CW Agent + EventBridge |
| 4 | `module4/` | eu-central-1 | Keycloak + OIDC + IAM |

---

## ?ㅽ뻾 ?쒖꽌

### ?ъ쟾 以鍮?(CloudShell)

```bash
cd ~
git clone https://github.com/hnmly/2026-terraform.git
```

---

### Module 1: CDN

```bash
cd ~/2026-terraform/05/2怨쇱젣/module1/infra

# Pillow ?⑦궎吏 鍮뚮뱶 (terraform apply ???꾩닔)
bash build.sh

terraform init
terraform apply -var pin=<鍮꾨쾲??
# ??~5遺?
# apply ?꾨즺 ??諛고룷?뚯씪 S3 ?낅줈??aws s3 cp <?대?吏?뚯씪> s3://gj2026-cdn-bucket-<鍮꾨쾲??/images/ --region us-east-1
```

---

### Module 2: Real-time data analytics

```bash
cd ~/2026-terraform/05/2怨쇱젣/module2

terraform init
terraform apply
# ??~5遺?# EC2 userdata?먯꽌 Kafka ?먮룞 ?ㅼ튂 + ?좏뵿 ?앹꽦 (??3遺????뚯슂)
```

---

### Module 3: Cloud event handling

```bash
cd ~/2026-terraform/05/2怨쇱젣/module3/infra

terraform init
terraform apply -var alarm_email=<?대찓?쇱＜??
# ??~3遺?# alarm_email: SNS ?대찓???뚮┝ ?섏떊 二쇱냼 (梨꾩젏??ぉ 3-8)
```

---

### Module 4: Keycloak

```bash
cd ~/2026-terraform/05/2怨쇱젣/module4

terraform init
terraform apply
# ??~10遺?# EC2 湲곕룞 ??Keycloak ?쒖옉 ?湲?3遺? ??OIDC Provider + IAM Role ?먮룞 ?앹꽦
```

> apply ?꾨즺 ??異쒕젰??`keycloak_public_ip` ?뺤씤
> Keycloak 愿由ъ옄 肄섏넄: `https://<IP>/admin` (admin / admin1234!)

---

## 二쇱쓽?ы빆

- **Module 1**: `bash build.sh` 癒쇱? ?ㅽ뻾?섏? ?딆쑝硫?terraform apply ?ㅽ뙣
- **Module 3**: `alarm_email` ?앸왂 媛??(SNS 援щ룆 ?놁씠 ?뚮엺留??앹꽦)
- **Module 4**: EC2 ?ъ떆????Public IP 諛붾뚮㈃ `terraform apply` ?ъ떎???꾩슂
- **Lambda Runtime**: PDF 紐낆꽭??`python3.14`?대굹 ?꾩옱 `python3.12`濡??ㅼ젙 ??AWS 吏????媛?`main.tf`??`runtime` 媛?蹂寃?
---

## 蹂寃?媛????ぉ ?섏젙 ?꾩튂

### Module 1

| 蹂寃???ぉ | ?뚯씪 | ?섏젙 ?꾩튂 |
|---|---|---|
| S3 踰꾪궥 ?대쫫 | `module1/infra/main.tf` | `locals.bucket_name` |
| Lambda ?⑥닔 ?대쫫 (`gj2026-cdn-rotate`) | `module1/infra/main.tf` | `aws_lambda_function.rotate.function_name` |
| Lambda@Edge ?대쫫 (`gj2026-cdn-request/response`) | `module1/infra/main.tf` | `aws_lambda_function.request/response.function_name` |
| CloudFront Behavior 寃쎈줈 (`/images`) | `module1/infra/main.tf` | `ordered_cache_behavior.path_pattern` |
| 罹먯떆 荑쇰━ ?뚮씪誘명꽣 (`image`, `rotate`) | `module1/infra/main.tf` | `aws_cloudfront_cache_policy.cdn` ??`query_strings.items` |
| ?대?吏 prefix (`images/`) | `module1/infra/lambda/rotate.py` | `key = f"images/{image}"` |
| ?뚯쟾 諛⑺뼢 (?쒓퀎?믩컲?쒓퀎) | `module1/infra/lambda/rotate.py` | `img.rotate(-rotate` ??`img.rotate(rotate` |
| Lambda Runtime | `module1/infra/main.tf` | `runtime` (3怨? |

### Module 2

| 蹂寃???ぉ | ?뚯씪 | ?섏젙 ?꾩튂 |
|---|---|---|
| EC2 ?대쫫 (`gj2026-data-ec2`) | `module2/main.tf` | `aws_instance.kafka` ??`tags.Name` |
| NLB ?대쫫 (`gj2026-data-nlb`) | `module2/main.tf` | `aws_lb.data.name` |
| Kafka ?대? ?ы듃 (`9092`) | `module2/main.tf` | SG ingress + userdata `INTERNAL://0.0.0.0:9092` |
| Kafka ?몃? ?ы듃 (`9094`) | `module2/main.tf` | SG ingress + TG port + Listener port + userdata `EXTERNAL://0.0.0.0:9094` |
| ?좏뵿 ?대쫫/?뚰떚????| `module2/main.tf` | userdata??`kafka-topics.sh --create` 紐낅졊 |
| Glue DB ?대쫫 (`real_time_analytics`) | `module2/main.tf` | `aws_glue_catalog_database.analytics.name` |

### Module 3

| 蹂寃???ぉ | ?뚯씪 | ?섏젙 ?꾩튂 |
|---|---|---|
| EC2 ?대쫫 (`gj2026-event-ec2`) | `module3/infra/main.tf` | `aws_instance.event` ??`tags.Name` |
| ?쒕퉬???대쫫 (`gj2026-app`) | `module3/infra/main.tf` | userdata???쒕퉬???뚯씪紐?+ `systemctl` 紐낅졊 ?꾩껜 |
| FastAPI ?ы듃 (`8080`) | `module3/infra/main.tf` | userdata??`port=8080` + SG ingress |
| ???묐떟 硫붿떆吏 (`WorldSkills 2026`) | `module3/infra/main.tf` | userdata??`app.py` ??`"message"` 媛?|
| SSM Parameter 寃쎈줈 (`/gj2026/event/app-py`) | `module3/infra/main.tf` | `aws_ssm_parameter.app_py.name` + IAM policy |
| 硫뷀듃由??대쫫 (`app_process_count`) | `module3/infra/main.tf` | userdata??`put-app-metric.sh` + `aws_cloudwatch_metric_alarm.app.metric_name` |
| ?뚮엺 ?대쫫 (`gj2026-event-app-alarm`) | `module3/infra/main.tf` | `aws_cloudwatch_metric_alarm.app.alarm_name` + EventBridge `event_pattern` |
| ??濡쒓렇 洹몃９ (`/gj2026/event/app-logs`) | `module3/infra/main.tf` | `aws_cloudwatch_log_group.app_logs.name` + userdata CW Agent ?ㅼ젙 |
| 蹂듦뎄 濡쒓렇 洹몃９ (`/gj2026/event/recovery`) | `module3/infra/main.tf` + `lambda/recovery.py` | `aws_cloudwatch_log_group.recovery.name` + `LOG_GROUP` 蹂??|
| EventBridge Rule ?대쫫 (`gj2026-event-trigger-alarm`) | `module3/infra/main.tf` | `aws_cloudwatch_event_rule.alarm_trigger.name` |
| Updater Lambda ?대쫫 (`gj2026-event-updater`) | `module3/infra/main.tf` | `aws_lambda_function.updater.function_name` + userdata `ExecStartPost` |
| Recovery Lambda ?대쫫 (`gj2026-event-recovery`) | `module3/infra/main.tf` | `aws_lambda_function.recovery.function_name` |
| Lambda Runtime | `module3/infra/main.tf` | `runtime` (2怨? |

### Module 4

| 蹂寃???ぉ | ?뚯씪 | ?섏젙 ?꾩튂 |
|---|---|---|
| EC2 ?대쫫 (`gj2026-keycloak-ec2`) | `module4/main.tf` | `aws_instance.keycloak` ??`tags.Name` |
| Realm ?대쫫 (`team`) | `module4/main.tf` | userdata setup script??紐⑤뱺 `/realms/team` + `null_resource.oidc_provider` |
| Client ?대쫫 (`gj2026-keycloak-dev/sec`) | `module4/main.tf` | userdata??`for CLIENT in` 諛곗뿴 + `null_resource.iam_roles` |
| Client Scope ?대쫫 (`gj2026-keycloak-claims`) | `module4/main.tf` | userdata??`SCOPE_PAYLOAD.name` |
| Group ?대쫫 (`dev-team`, `sec-team`) | `module4/main.tf` | userdata??`for g in dev-team sec-team` |
| ?ъ슜??鍮꾨?踰덊샇 | `module4/main.tf` | userdata??`create_user` ?몄텧 |
| Dev/Sec Role ?대쫫 | `module4/main.tf` | `null_resource.iam_roles` ??`create_role` ?몄텧 |
| Dev/Sec Policy ?대쫫 | `module4/main.tf` | `aws_iam_policy.dev/sec.name` |
| ? ?쒓렇 ??(`team`) | `module4/main.tf` | `aws_iam_policy.dev/sec` ??`Condition.StringEquals["ec2:ResourceTag/team"]` |
| admin 鍮꾨?踰덊샇 (`admin1234!`) | `module4/main.tf` | `variable.keycloak_admin_password.default` |


