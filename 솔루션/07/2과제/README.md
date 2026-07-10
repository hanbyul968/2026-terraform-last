# 제2과제 Small Challenges — AWS 콘솔(GUI) 솔루션

> Terraform 없이 **AWS Management Console** 에서 클릭으로 처음부터 끝까지 진행하는 가이드입니다.
> 각 모듈은 **독립적**이며, 지정된 리전에 정확히 만들어야 합니다. **리전이 틀리면 해당 모듈 0점**입니다.

## 모듈별 문서

| 모듈 | 리전 | 문서 | 배점 |
|------|------|------|------|
| 1 | 서울 `ap-northeast-2` | [모듈1_DocumentDB.md](모듈1_DocumentDB.md) | 7.5 |
| 2 | 도쿄 `ap-northeast-1` | [모듈2_VPCLattice.md](모듈2_VPCLattice.md) | 7.5 |
| 3 | 싱가포르 `ap-southeast-1` | [모듈3_CloudEventHandling.md](모듈3_CloudEventHandling.md) | 7.5 |
| 4 | 오레곤 `us-west-2` | [모듈4_EKS_SQS.md](모듈4_EKS_SQS.md) | 7.5 |

## 시작 전 공통 체크

1. **리전 선택기**(콘솔 우측 상단)를 항상 먼저 확인하고 모듈별 리전으로 바꾼다.
2. **고정 리소스 이름**(`skills-*`)은 문제지 그대로, **대소문자까지** 정확히 입력한다.
3. 문제지에서 이름을 지정하지 않은 리소스의 Name 태그는 자유.
4. 배포 파일(`docdb_client.py`, `client_app.py`, `service_app.py`,
   `remediate_security_group.py`, `worker.py`, `retail_dataset.json`)은 **수정 없이** 사용한다.
5. 채점은 CloudShell에서 자동 스크립트로 진행된다.

## 권장 진행 순서

오래 걸리는 것부터 먼저 시작하면 대기 시간을 겹칠 수 있습니다.

```
① 모듈4 EKS 클러스터 생성 시작 (15~20분 소요 → 백그라운드로 두고)
② 모듈1 DocumentDB 클러스터 생성 시작 (10분 소요 → 백그라운드)
③ 그 사이 모듈2, 모듈3을 콘솔로 완성
④ 모듈1으로 돌아와 EC2/앱/인덱스 마무리
⑤ 모듈4로 돌아와 Fargate/IRSA/kubectl/helm 마무리
```

## 표기 규칙

- `[서비스 > 메뉴]` : 콘솔 상단 검색창에 서비스명을 치고 해당 메뉴로 이동
- **굵게** : 입력값 또는 클릭할 버튼
- `<비번호>` : 선수 비번호로 치환
