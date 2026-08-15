# System Operation 데모 — color 앱 (EC2 기반)

`2026년_System_Operation_데모_문제지_v1.0.0` 요구사항에 맞춘 **독립·이식형** Terraform 스택.
다른 계정·리전·날짜에서도 `terraform apply` 한 번으로 그대로 배포된다(계정 ID·AMI·AZ 하드코딩 없음).

> 이 폴더는 상위 `../../terraform/`(정식 3과제, EKS 기반)와 **완전히 분리**되어 있어
> 기존 인프라/state 를 건드리지 않는다.

---

## 아키텍처

```
사용자 → CloudFront (단일 https 엔드포인트, *.cloudfront.net, 기본 인증서)
        → ALB (:80, SG 로 CloudFront edge 만 허용)
        → Target Group (:8080, HC /healthcheck)
        → Auto Scaling Group: t3.micro × 2 (2AZ, AL2023)
              └ user-data: 제공 color 바이너리를 S3 에서 다운로드 → systemd 실행
              └ CloudWatch Agent: 앱 로그 + mem/disk 지표 전송
CloudWatch: 로그그룹 + 알람(5xx/비정상호스트/응답시간/CPU) + 대시보드
S3: 배포 아티팩트(color 바이너리) 스테이징 — 게이트웨이 엔드포인트로 사설 다운로드
VPC: 2AZ public 서브넷 + IGW (NAT 없음 = 저비용)
```

### 문제지 요구사항 매핑

| 요구                                           | 구현                                                                    |
| ---------------------------------------------- | ----------------------------------------------------------------------- |
| color 앱`/v1/color`, `/healthcheck`, :8080 | 제공 바이너리`app/color/color` (S3→EC2 배포)                         |
| access log stdout/stderr                       | systemd`StandardOutput` → 파일 → CloudWatch Logs                    |
| EC2**t3.micro 전용**, 최소 리소스        | `instance_type=t3.micro`, ASG min 2(2AZ HA)                           |
| Fargate/Lambda 미사용                          | EC2/ASG 만 사용 (Lambda·Fargate 없음)                                  |
| 단일 엔드포인트(https, 경로X)                  | CloudFront 기본 도메인                                                  |
| 모니터링·로깅 솔루션                          | CloudWatch 로그그룹·알람·대시보드                                     |
| ap-northeast-2, KST, WA 6 pillars              | 기본 리전/태그/최소권한/HA/오토스케일                                   |
| 불필요 리소스 최소화                           | RDS·WAF·EKS 없음. S3 는 바이너리 배포용 1개(user-data 16KB 한도 회피) |

---

## 배포

사전 요건: Terraform ≥ 1.3, AWS 자격증명(환경변수 또는 `-var aws_profile=...`).

```bash
cd terraform
terraform init
terraform apply -auto-approve
terraform output endpoint      # 채점 플랫폼에 입력 (경로 없이 이 값 그대로)
```

CloudFront 전파(약 5~15분) 후 스모크 테스트:

```bash
# terraform output smoke_test 의 명령 사용
curl -s  https://<dist>.cloudfront.net/v1/color        # {"color":"...","hex":"#..."}
curl -s -o /dev/null -w '%{http_code}\n' https://<dist>.cloudfront.net/healthcheck   # 200
```

인스턴스 접속(SSH 없음, SSM 사용):

```bash
aws ssm start-session --target <instance-id>
sudo journalctl -u color -f          # 앱 상태
sudo tail -f /var/log/user-data.log  # 부팅 빌드 로그
```

정리:

```bash
terraform destroy -auto-approve
```

---

## 주요 변수 (`terraform.tfvars` 또는 `-var`)

| 변수                                 | 기본값              | 설명                                  |
| ------------------------------------ | ------------------- | ------------------------------------- |
| `region`                           | `ap-northeast-2`  | 배포 리전                             |
| `project`                          | `wsc-sysops-demo` | 이름/태그 prefix (+ 자동 임의 suffix) |
| `instance_type`                    | `t3.micro`        | 문제지 고정                           |
| `asg_min_size`/`desired`/`max` | 2 / 2 / 4           | 고가용성·스케일 상한                 |
| `cpu_target`                       | 50                  | CPU 타깃 트래킹(%)                    |
| `container_port`                   | 8080                | 앱 포트                               |
| `aws_profile`                      | `""`              | named profile(비우면 기본 체인)       |

---

## 이식성 설계 포인트

- **AMI**: SSM 파라미터로 최신 AL2023 조회 → 날짜/리전 무관.
- **AZ**: `aws_availability_zones` 데이터소스로 동적 선택 → 리전 이동 안전.
- **이름 충돌 방지**: 모든 리소스명에 `random_string` suffix.
- **계정 종속 값 없음**: 계정 ID/ARN 하드코딩 없이 관리형 정책·데이터소스만 사용.
- **앱 배포**: 제공된 color 바이너리를 Terraform 이 S3 에 업로드하고 인스턴스가 부팅 시
  다운로드한다. 바이너리 교체 시 `app/color/color` 만 덮어쓰고 `terraform apply` 하면
  `source_hash` 변화로 자동 재업로드 + 롤링 교체된다.

> 연습용 Go 소스(`app/color/main.go`, `go.mod`)는 참고용으로 남겨두었으나 배포에는
> 사용되지 않는다(현재는 제공 바이너리 `app/color/color` 를 배포). 다시 소스빌드로
> 돌리려면 이전 방식의 user-data(golang 빌드)로 되돌리면 된다.
