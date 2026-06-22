# Terraform Import Helper

terraform apply 시 `EntityAlreadyExists` 등 "이미 존재하는 리소스" 에러가 뜨면,
에러 메시지를 통째로 붙여넣어 어떤 `terraform import` 명령어를 실행해야 하는지 알려주는 웹 도구.

## 실행

```bash
pip install -r requirements.txt
python app.py
# 브라우저 http://127.0.0.1:5000 접속
```

## 사용법

1. 비번호 입력 (예: 103)
2. terraform 에러 메시지를 textarea에 통째로 붙여넣기
3. "Import 명령어 생성" 클릭
4. 리소스별 import 명령어 + 전체 명령어 묶음 출력

## 동작 원리

- 에러에서 `with <리소스주소>,` 줄을 정규식으로 추출
- 미리 정의된 매핑(`RESOURCES`)에서 해당 주소의 import ID / 조회 명령어를 찾아 출력
- ID가 ARN/SubnetId 등 동적 값이면 `aws` CLI 조회 명령어도 함께 제공

## 리소스 추가/변경 시

`app.py`의 `RESOURCES` 딕셔너리에 항목 추가:

```python
"module.XXX.aws_yyy.zzz": {
    "lookup": 'VAR=$(aws ... )',   # 동적 ID면 조회 명령, 고정 이름이면 None
    "import_id": "$VAR",           # 또는 "고정-리소스-이름"
},
```
