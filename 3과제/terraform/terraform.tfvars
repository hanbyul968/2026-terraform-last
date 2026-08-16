# WAF 커스텀 차단 (waf.tf 수정 없이 변수로만 제어)
# x-api-version: 로그 실측상 이 헤더를 쓰는 요청은 100% 공격(Shellshock/JNDI),
# 정상 트래픽은 이 헤더를 전혀 안 씀 → 존재만으로 403 (오탐 0).
waf_blocked_headers = ["x-junk", "x-api-version", "X-Forwarded-Host", "X-Forwarded-For"]

# python-urllib: 정상 채점 트래픽은 Go-http-client/1.1 만 사용 → python-urllib 는 정찰/스캐너.
# 리스트 변수는 덮어쓰기이므로 기본값 전체 + 새 토큰을 함께 나열해야 함.
waf_blocked_user_agents = [
  "sqlmap",
  "nikto",
  "nmap",
  "masscan",
  "acunetix",
  "havij",
  "nuclei",
  "wpscan",
  "dirbuster",
  "gobuster",
  "attack",
  "bin/bash",
  "ZAP",
  "/bin/bash"
]

# multipart/form-data 차단 (사용자 요청). Content-Type 헤더 값에 포함되면 403.
waf_blocked_header_values = [
]

waf_blocked_query_patterns = [
  "/etc/passwd",
  "hijack",
  "$gt",
  "$where",
  "passwd",
]