# 제1과제 — Web Service Provisioning (과제지_vf)

EKS 기반 콘서트 예매 REST API + 정적 웹(S3/CloudFront) + 모니터링.
**로컬에서 bastion 만 띄우고, bastion(Linux) 안에서 전체를 apply** 한다
(루트가 `/bin/bash` provisioner·docker·kubectl/helm 에 의존 → 로컬 직접 apply 불가).

---

## 스테이지 구성

| 스테이지 | 위치 | 만드는 것 |
|----------|------|-----------|
| **bastion** | `bastion/` | 네트워크(VPC/서브넷/IGW/NAT/RTB) + Bastion EC2(SSM). 코드를 `/opt/task1` 로 번들 |
| **root** | `.` (`/opt/task1`) | AWS 리소스: KMS·S3·ECR(빌드/스캔)·DynamoDB·EKS·노드그룹·Lambda·ALB·CloudFront·IAM(IRSA)·LogGroup |
| **k8s** | `k8s/` | 쿠버네티스/헬름: book 앱·LB Controller·모니터링(Prometheus/Grafana)·로깅(Fluent Bit) |

> 네트워크는 root 가 아니라 **`bastion/network.tf`** 가 만든다. root/k8s 는 이름(tag)으로 `data` 조회.
> 파드 권한은 Pod Identity 가 아니라 **IRSA(OIDC)** — root 가 역할 생성, k8s SA 에 `role-arn` 어노테이션.

---

## 배포 절차

```powershell
# 1) 로컬 PowerShell — Bastion 생성
cd C:\Users\competitor\2026-terraform\1과제\02\bastion
terraform init
terraform apply -auto-approve
terraform output -raw ssm_connect_command   # SSM 접속 명령 출력
```
```bash
# 2) SSM 접속 후 — Bastion 안에서 전체 배포 (비번호는 프롬프트로 입력)
sudo su - ec2-user
until [ -f /opt/task1/READY ]; do sleep 5; done
cd /opt/task1 && bash run.sh 2>&1 | tee /tmp/apply.log
```
```powershell
# 3) 채점 종료 후 — Bastion 제거
cd C:\Users\competitor\2026-terraform\1과제\02\bastion
terraform destroy -auto-approve
```

- `run.sh` 는 **비번호(bi_number)** 를 입력받아 root → k8s 순서로 apply.
- EKS/헬름 타이밍으로 간헐 실패 시 `bash run.sh` 를 한 번 더 실행하면 수렴.

---

## ⭐ 대회 중 값 변경 매핑표 (최대 30% 변형 대비)

> "이 값이 바뀌면 → 여기를 고친다". **모든 이름/태그/변수는 대소문자 구분.**

### 네트워크 (Reference01) — 전부 `bastion/network.tf`
| 바뀌는 값 | 수정 위치 |
|-----------|-----------|
| VPC CIDR / 이름 | `aws_vpc` `cidr_block` / `tags.Name` |
| 서브넷 CIDR·이름·AZ | 각 `aws_subnet` |
| IGW/NAT/RTB 이름 | 각 리소스 `tags.Name` |
> 이름이 바뀌면 root `data.tf` 의 `tag:Name` 필터도 같이 수정.

### 이름·키 — 대부분 `locals.tf` / `variables.tf`
| 바뀌는 값 | 수정 위치 |
|-----------|-----------|
| S3 버킷 prefix | `locals.tf` `bucket_name` |
| 비번호 | `run.sh` 프롬프트 (또는 `-var="bi_number=..."`) |
| S3 객체 경로 (web/main/) | `s3.tf` object `key` + `cloudfront.tf` `origin_path` |
| ECR 레포명 / 태그(stable) | `locals.tf` `ecr_repo` / `image_tag` |
| DynamoDB 테이블명 / PK | `locals.tf` `table_name` / `dynamodb.tf` `hash_key`+`attribute` |
| EKS 클러스터명 / 버전 | `locals.tf` `cluster_name` / `variables.tf` `eks_version` |
| EKS 서브넷 | `eks.tf` `vpc_config.subnet_ids` |
| 네임스페이스 (wskorea26) | `locals.tf` `namespace` |
| 노드그룹명/태그/라벨 | `eks_nodegroups.tf` `local.node_groups` |
| 노드 인스턴스타입 | `variables.tf` `node_instance_type` |
| Lambda 함수명/런타임 | `lambda.tf` `function_name`/`runtime` |
| CMK 별칭 3종 | `kms.tf` 각 `aws_kms_alias` |
> k8s 스테이지도 이름을 참조하므로, 이름 변경 시 **`k8s/variables.tf` 기본값**도 함께 수정.

### ALB / CloudFront (가장 까다로움)
| 바뀌는 값 | 수정 위치 |
|-----------|-----------|
| ALB 이름 / 리스너 포트 | `alb.tf` `aws_lb.book` / `aws_lb_listener.book` |
| 라우팅 경로(/book·/v1/book) | `alb.tf` 리스너 룰 `path_pattern` + `cloudfront.tf` 재작성 함수 + `/book*` behavior |
| X-Origin-Verify 값 | `variables.tf` `cf_origin_verify` |
| S3 전달 헤더(wskorea26-s3-access=true) | `variables.tf` `s3_access_header_value` |
| CloudFront 이름(Comment) / Origin ID | `cloudfront.tf` `comment` / `origin_id` |

> ⚠️ book 앱은 **`POST /v1/book`·`GET /health` 만** 처리(배포 바이너리 고정).
> CloudFront `/book`(POST) → CF Function 이 `/v1/book` 재작성 → ALB 룰(POST)이 book Pod 로.
> `GET /book` 은 ALB 룰(GET)이 Lambda 로. 경로가 바뀌면 **CF 함수 + ALB 룰** 둘 다 수정.

### Lambda 조회 / DynamoDB GSI
| 바뀌는 값 | 수정 위치 |
|-----------|-----------|
| 조회 파라미터(concert_name) | `files/lambda_function.py` + GSI hash_key |
| 정렬(created_at 최신순) | `dynamodb.tf` GSI `range_key` + py `ScanIndexForward` |
| GSI 이름 | `locals.tf` `gsi_name` (lambda env 주입) |

### 모니터링 / Grafana
| 바뀌는 값 | 수정 위치 |
|-----------|-----------|
| 대시보드 이름/uid | `k8s/wskorea26-dashboard.json` `title`/`uid` |
| 표시 지표(패널) | `k8s/wskorea26-dashboard.json` `panels[].targets[].expr` |
| Grafana 계정 | `run.sh`에서 받은 `bi_number`로 `skills-<비번호>-admin` 자동 생성, 비밀번호는 `k8s/variables.tf` |
| Grafana LB 이름 | `k8s/grafana-values.yaml.tftpl` `aws-load-balancer-name` |
| 모니터링 배치 노드 | `k8s/*-values.yaml.tftpl` `nodeSelector.node-type` |

---

## 채점 항목 대응 메모

| # | 항목 | 핵심 |
|---|------|------|
| 1 | Network | CIDR/라우팅. private RTB = 0.0.0.0/0→NAT 만, public → IGW |
| 2 | S3 | 객체 `web/main/*`, KMS=`wskorea26-s3-key`, PublicAccessBlock 4종 True |
| 3 | ECR | scanOnPush + **레지스트리 BASIC 스캔** / KMS / 태그 stable / Critical·High 0 (Debian slim 보안 업데이트 + 스캔 결과 non-empty 검증) |
| 4 | DynamoDB | client_id HASH / DeletionProtection / `wskorea26-dynamodb-key` |
| 5 | EKS | 1.35 / 로그 5종 / `wskorea26-eks-key` / priv-c·d / 노드 node-type 라벨 / ns wskorea26 |
| 6 | Lambda | python3.14 / TABLE_NAME |
| 7 | ALB | internet-facing / 80 HTTP / 룰 헤더 wskorea26-cf / 직접 /book → 403 |
| 8 | CloudFront | S3 기본·ALB /book* / redirect-to-https / 커스텀헤더 / main.jpeg 180926B |
| 9 | Application | CF 경유 POST·GET /book. **created_at 은 KST(+09:00)** — 이미지 tzdata + `TZ=Asia/Seoul` |
| 10 | Monitoring | Grafana 로그인 `skills-<비번호>-admin / $korea26!!`, 대시보드 5개 지표 |

---

## 주의

1. **비번호** 는 `run.sh` 프롬프트에 정확히 입력(버킷명·Grafana 계정에 반영).
2. **book 이미지 빌드는 docker 필요** — bastion 에서 apply(=docker 존재). CloudShell 불가.
3. **ECR 스캔** — `aws_ecr_registry_scanning_configuration`(BASIC·SCAN_ON_PUSH)로 켜야 3-1 이 채워짐.
4. **created_at KST** — 이미지에 `tzdata`+`TZ=Asia/Seoul`. 파드 재기동 필요 시
   `kubectl -n wskorea26 rollout restart deploy/wskorea26-book`.
5. CloudFront 는 apply 후 **Deployed** 까지 수 분 소요. 8-x 채점 전 Status 확인.
6. **CloudFront origin 은 실제 버킷·ALB 를 동적 참조** — 비번호를 바꿔 재apply 했다면
   옛 배포(다른 버킷명) 잔재가 남지 않았는지 확인(중복 distribution 삭제).
