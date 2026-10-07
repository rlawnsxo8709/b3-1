#!/usr/bin/env bash
# B3-1 테스트 러너 — PATH 맨 앞에 가짜 aws·curl·ssh(tests/fake-bin)를 넣고 스크립트를 실행해
# 호출 순서·인자·상태 파일·증거 파일을 검증한다. 실제 AWS와 네트워크는 호출하지 않는다.
#
#   bash tests/run.sh                 # 전체 실행
#   bash tests/run.sh test_이름 ...    # 일부만 실행
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/b3-1-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAIL_MARK=""
SANDBOX=""
FAKE_LOG=""
APP_FIX=""
REMOTE_DIR=""
OUT=""
RC=0

# ---------------------------------------------------------------- 헬퍼

fail() {
  printf '    ✗ %s\n' "$*"
  # 서브셸 안에서 호출돼도 실패가 집계되도록 파일에 표시한다
  if [ -n "$FAIL_MARK" ]; then echo x >> "$FAIL_MARK"; fi
  return 0
}

assert_exit() {
  if [ "$RC" -ne "$1" ]; then
    fail "종료 코드 기대 $1, 실제 $RC"
    printf '%s\n' "$OUT" | tail -n 8 | sed 's/^/      | /'
  fi
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "'$2' 이(가) 없음"
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || fail "'$2' 이(가) 있으면 안 됨"
}

# 가짜 명령 로그에서 B가 처음 나오기 전까지 A가 나온 줄 수
lines_before() {
  awk -v a="$1" -v b="$2" 'index($0, b) { exit } index($0, a) { n++ } END { print n + 0 }' "$FAKE_LOG"
}

# 가짜 명령 로그에서 A가 처음 나온 줄이 B가 처음 나온 줄보다 앞서야 한다
assert_order() {
  local a b
  a="$(grep -nF -- "$1" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" "$FAKE_LOG" | head -n 1 | cut -d: -f1)"
  if [ -z "$a" ] || [ -z "$b" ]; then
    fail "순서 확인 불가: '$1'(줄 ${a:-없음}) / '$2'(줄 ${b:-없음})"
  elif [ "$a" -ge "$b" ]; then
    fail "순서 위반: '$1'(줄 $a)이 '$2'(줄 $b)보다 먼저여야 함"
  fi
}

# 배포 대상 앱(ai_chatbot)의 비밀값 대신 쓰는 표식. 이 문자열이 로그·증거·화면·상태 파일에 나오면 유출이다
SECRET_MARKER="B31-SECRET-MARKER-7f3a9c0d1e2f"
LLM_MARKER="B31-LLMKEY-MARKER-2b8e4d6a"

# git 명령을 사용자 설정(전역 훅·서명 등)과 무관하게 실행한다
tgit() {
  git -c init.defaultBranch=main -c user.name=b3-1-test -c user.email=test@example.com \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# 테스트용 앱 체크아웃: 작은 git 저장소. 실제 ai_chatbot은 쓰지 않는다(그 .env는 읽지도 않는다).
#   태그 no-app: 앱 코드가 없는 첫 커밋(ai_chatbot의 main처럼) / HEAD: app/main.py·requirements.txt가 있는 커밋
#   .env: 추적하지 않는 파일(.gitignore). 비밀 표식이 들어 있다
make_app_repo() {
  local dir="$1"
  mkdir -p "$dir/app"
  printf '.env\n*.env\n' > "$dir/.gitignore"
  tgit -C "$dir" init -q
  tgit -C "$dir" add .gitignore
  tgit -C "$dir" commit -q -m "Initial commit"
  tgit -C "$dir" tag no-app
  printf 'from fastapi import FastAPI\napp = FastAPI()\n' > "$dir/app/main.py"
  printf 'fastapi\nuvicorn\n' > "$dir/requirements.txt"
  tgit -C "$dir" add app requirements.txt
  tgit -C "$dir" commit -q -m "앱 코드"
  printf '%s\n' "SECRET_KEY=$SECRET_MARKER" "DATABASE_URL=sqlite:///./app.db" \
    "LLM_API_KEY=$LLM_MARKER" "NAVER_CLIENT_ID=" "NAVER_CLIENT_SECRET=" > "$dir/.env"
}

# 프로젝트 사본을 만든다. 사용자의 실제 .env·state·evidence/aws·.tools는 복사하지 않는다.
# 사본 옆에 테스트용 앱 저장소($APP_FIX)도 만든다
setup_sandbox() {
  SANDBOX="$(mktemp -d "$TEST_ROOT/sandbox.XXXXXX")"
  rsync -a \
    --exclude .git --exclude /state --exclude /.tools --exclude /evidence/aws --exclude __pycache__ \
    --include /.env.example --exclude '/.env' --exclude '/.env.*' \
    "$PROJECT_DIR/" "$SANDBOX/"
  FAKE_LOG="$SANDBOX/calls.log"
  APP_FIX="$SANDBOX-app"
  REMOTE_DIR="$SANDBOX-remote"
  make_app_repo "$APP_FIX"
}

# 가짜 키 두 개와 테스트용 앱 경로만 채운 .env
write_env() {
  printf '%s\n' \
    "AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE" \
    "AWS_SECRET_ACCESS_KEY=fakeSecretKeyForTestsOnly000000000000000" \
    "APP_SRC=$APP_FIX" > "$SANDBOX/.env"
}

# 사본 안의 모든 파일(로그·증거·상태·.env)과 마지막 화면 출력에 비밀 표식이 없어야 한다
assert_no_secret_leak() {
  local hits m
  for m in "$SECRET_MARKER" "$LLM_MARKER"; do
    # tests/는 표식 문자열을 정의한 이 파일의 사본이라 뺀다
    hits="$(grep -rlF --exclude-dir=tests -- "$m" "$SANDBOX" 2> /dev/null || true)"
    [ -z "$hits" ] || fail "비밀 표식이 파일에 남음: ${hits//$'\n'/, }"
    assert_not_contains "$OUT" "$m"
  done
}

# 사본에서 명령을 실행한다. 호스트의 AWS 관련 환경변수는 지우고 가짜 명령을 PATH 앞에 둔다
run_in_sandbox() {
  run_in_sandbox_env -- "$@"
}

# run_in_sandbox_env 이름=값... -- 명령... : 사용자의 셸에 export된 변수가 있는 상황을 흉내 낸다
run_in_sandbox_env() {
  local assigns=()
  while [ "$1" != "--" ]; do
    assigns+=("$1")
    shift
  done
  shift
  OUT="$(cd "$SANDBOX" && env \
    -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_REGION -u AWS_DEFAULT_REGION \
    -u MY_IP -u INSTANCE_TYPE -u AZ -u PROJECT -u APP_SRC -u APP_ENV_FILE -u APP_REF \
    PATH="$SANDBOX/tests/fake-bin:$PATH" FAKE_LOG="$FAKE_LOG" FAKE_REMOTE_DIR="$REMOTE_DIR" \
    VERIFY_WAIT_INTERVAL=0 CLEANUP_RETRY_SLEEP=0 DEPLOY_EXISTS_SLEEP=0 DEPLOY_SSH_SLEEP=0 \
    ${assigns[@]+"${assigns[@]}"} timeout 120 "$@" 2>&1)"
  RC=$?
}

# ---------------------------------------------------------------- Task 1: 사전 점검

test_missing_keys_fails_before_any_aws_call() {
  setup_sandbox; : > "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "AWS_ACCESS_KEY_ID"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

test_missing_env_file_explains_copy() {
  setup_sandbox
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "cp .env.example .env"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

test_root_account_is_rejected() {
  setup_sandbox; write_env; FAKE_ROOT=1 run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "루트"; assert_not_contains "$(cat "$FAKE_LOG")" "create-vpc"
}

test_invalid_detected_ip_aborts() {
  setup_sandbox; write_env; FAKE_IP="not-an-ip" run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "MY_IP"; assert_not_contains "$(cat "$FAKE_LOG")" "authorize-security-group-ingress"
}

test_identity_evidence_masks_account() {
  setup_sandbox; write_env; FAKE_STOP_AFTER_PREFLIGHT=1 run_in_sandbox ./deploy.sh --preflight-only
  assert_contains "$(cat "$SANDBOX/evidence/aws/00-identity.txt")" "1234****9012"
}

test_my_ip_from_env_skips_detection() {
  setup_sandbox; write_env; echo "MY_IP=203.0.113.77" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_not_contains "$(cat "$FAKE_LOG")" "checkip"
  # 개인 IP는 증거 파일에서 뒤 두 자리를 가린다
  local E; E="$(cat "$SANDBOX/evidence/aws/00-identity.txt")"
  assert_contains "$E" "203.0.*.*/32"; assert_not_contains "$E" "203.0.113.77"
}

test_env_file_tolerates_crlf_quotes_and_comments() {
  setup_sandbox
  printf '%s\r\n' \
    "# 윈도우 메모장으로 저장한 .env" \
    'AWS_ACCESS_KEY_ID="AKIAFAKEFAKEFAKEFAKE"' \
    "AWS_SECRET_ACCESS_KEY=fakeSecret/with+chars   # 주석" \
    "MY_IP=203.0.113.77   # 내 IP" \
    "APP_SRC=\"$APP_FIX\"   # 배포할 앱" > "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" "sts get-caller-identity"
}

test_bad_credentials_stop_with_guidance() {
  setup_sandbox; write_env; FAKE_FAIL_ON=get-caller-identity run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" ".env"; assert_not_contains "$(cat "$FAKE_LOG")" "create-vpc"
}

test_non_seoul_region_rejected() {
  setup_sandbox; write_env; echo "AWS_REGION=us-east-1" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "ap-northeast-2"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

test_non_free_tier_instance_type_rejected() {
  setup_sandbox; write_env; echo "INSTANCE_TYPE=t3.large" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "t3.micro"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# ---------------------------------------------------------------- Task 2: 서버 설정(user-data)

# Nginx는 80에서 받아 127.0.0.1:8000(uvicorn)으로 넘긴다. /health도 앱이 답한다(Nginx 고정 응답 없음).
# 비밀값은 user-data(인스턴스 메타데이터·콘솔에 보이는 곳)에 넣지 않는다
test_user_data_static() {
  local f=server/user-data.sh
  [ -f "$f" ] || { fail "$f 없음"; return; }
  bash -n "$f" || fail "$f 문법 오류"
  grep -q 'set -euxo pipefail' "$f" || fail "set -euxo pipefail 없음"
  grep -q 'listen 80 default_server' "$f" || fail "80 포트 리슨 설정 없음"
  grep -qF 'proxy_pass http://127.0.0.1:8000' "$f" || fail "127.0.0.1:8000 프록시 설정 없음"
  grep -qF 'proxy_read_timeout 90s' "$f" || fail "proxy_read_timeout 90s 없음(LLM 응답 최대 50초)"
  grep -qF 'proxy_set_header Host' "$f" || fail "Host 헤더 전달 없음"
  grep -qF 'proxy_set_header X-Forwarded-For' "$f" || fail "X-Forwarded-For 헤더 전달 없음"
  ! grep -qF 'location = /health' "$f" || fail "/health는 앱으로 넘겨야 함(Nginx 고정 응답 금지)"
  ! grep -qF 'return 200' "$f" || fail "Nginx 고정 응답이 남아 있음"
  grep -q 'python3-venv' "$f" || fail "python3-venv 설치 없음"
  grep -qF '/home/ubuntu/ai_chatbot' "$f" || fail "앱 폴더 준비 없음"
  grep -qF '/var/lib/b3-1/user-data.done' "$f" || fail "완료 표식 없음"
  grep -q '/run/systemd/system' "$f" || fail "systemd 유무 분기 없음"
  grep -q 'nginx -t' "$f" || fail "nginx -t 설정 검사 없음"
  ! grep -qF '0.0.0.0/0' "$f" || fail "user-data에 0.0.0.0/0 문자열이 있으면 안 됨"
  ! grep -qE 'listen[[:space:]]+8000|0\.0\.0\.0:8000' "$f" || fail "8000을 바깥에 열면 안 됨"
  ! grep -qE 'SECRET_KEY|LLM_API_KEY|NAVER_CLIENT' "$f" || fail "user-data에 비밀값 항목이 있으면 안 됨"
}

# ---------------------------------------------------------------- Task 3: deploy.sh

test_deploy_happy_path_call_order_and_rules() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local L; L="$(cat "$FAKE_LOG")"
  assert_order "create-vpc" "create-subnet"; assert_order "create-internet-gateway" "attach-internet-gateway"
  assert_order "attach-internet-gateway" "create-route "; assert_order "create-route " "associate-route-table"
  assert_order "create-security-group" "authorize-security-group-ingress"; assert_order "authorize-security-group-ingress" "run-instances"
  assert_contains "$L" "--destination-cidr-block 0.0.0.0/0 --gateway-id igw-0fake"
  assert_contains "$L" "FromPort=22,ToPort=22,IpRanges=[{CidrIp=198.51.100.7/32"
  assert_not_contains "$L" "FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0"
  assert_not_contains "$L" "FromPort=0,ToPort=65535"; assert_not_contains "$L" "IpProtocol=-1"
  assert_contains "$L" "--map-public-ip-on-launch"; assert_contains "$L" "HttpTokens=required"
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "INSTANCE_ID=i-0fake"
  [ "$(stat -c %a "$SANDBOX/state/b3-1-key.pem")" = "400" ] || fail "pem 권한이 400이 아님"
  for f in 01-network 02-security-group 03-instance 04-verify; do [ -s "$SANDBOX/evidence/aws/$f.txt" ] || fail "$f 증거 없음"; done
}

test_deploy_rerun_is_idempotent() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_not_contains "$(cat "$FAKE_LOG")" "create-vpc"; assert_not_contains "$(cat "$FAKE_LOG")" "run-instances"
  # 첫 실행이 실제로 리소스를 만들었고, 재실행도 검증까지 마쳤는지(아무것도 안 해서 통과하는 것 방지)
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "INSTANCE_ID=i-0fake"
  assert_contains "$(cat "$FAKE_LOG")" "systemctl is-active nginx"
}

test_deploy_all_calls_in_seoul_region() {
  # 가짜 aws는 각 로그 줄 끝에 " region=${AWS_DEFAULT_REGION:-unset}"을 붙여 기록한다
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  local bad; bad="$(grep '^aws ec2' "$FAKE_LOG" | grep -v 'region=ap-northeast-2$' || true)"
  [ -z "$bad" ] || fail "서울 리전이 아닌 호출: $bad"
  grep -q '^aws ec2 run-instances' "$FAKE_LOG" || fail "ec2 호출이 없음(검사 대상 없음)"
}

test_deploy_resumes_after_mid_failure() {
  setup_sandbox; write_env
  FAKE_FAIL_ON=authorize-security-group-ingress run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "단계 실패"; assert_contains "$OUT" "./cleanup.sh"
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "SG_ID=sg-0fake"
  assert_not_contains "$(cat "$SANDBOX/state/resources.env")" "INSTANCE_ID="
  : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  local L; L="$(cat "$FAKE_LOG")"
  for op in create-vpc create-subnet create-internet-gateway attach-internet-gateway create-route-table "create-route " create-security-group; do
    assert_not_contains "$L" "$op"
  done
  assert_contains "$L" "authorize-security-group-ingress"; assert_contains "$L" "run-instances"
}

test_deploy_uses_latest_canonical_ubuntu_and_free_tier_disk() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local L; L="$(cat "$FAKE_LOG")"
  assert_contains "$L" "describe-images --owners 099720109477"
  assert_contains "$L" "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
  assert_contains "$L" "--image-id ami-0fake --instance-type t3.micro"
  assert_contains "$L" "VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true"
  assert_contains "$L" "--user-data file://"
}

test_deploy_tags_every_created_resource() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local untagged
  untagged="$(grep -E '^aws ec2 (create-(vpc|subnet|internet-gateway|route-table|security-group|key-pair)|run-instances) ' "$FAKE_LOG" | grep -v 'Key=Project,Value=b3-1' || true)"
  [ -z "$untagged" ] || fail "Project 태그 없는 생성 호출: $untagged"
  assert_contains "$(grep '^aws ec2 run-instances' "$FAKE_LOG")" "ResourceType=volume"
}

test_deploy_summary_shows_access_info() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_contains "$OUT" "http://203.0.113.10/health"
  assert_contains "$OUT" "ssh -i state/b3-1-key.pem ubuntu@203.0.113.10"
  assert_contains "$OUT" "./cleanup.sh"
}

# ---------------------------------------------------------------- Task 4: verify.sh

test_verify_records_health_and_ssh_checks() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; run_in_sandbox ./verify.sh; assert_exit 0
  local E; E="$(cat "$SANDBOX/evidence/aws/04-verify.txt")"
  assert_contains "$E" "/health"; assert_contains "$E" "PASS"; assert_not_contains "$E" "FAIL"
  assert_contains "$(cat "$FAKE_LOG")" "systemctl is-active nginx"
}

test_verify_fails_when_health_not_200() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; FAKE_HEALTH_CODE=503 run_in_sandbox ./verify.sh; assert_exit 1
}

test_verify_without_state_explains() {
  setup_sandbox; write_env; run_in_sandbox ./verify.sh; assert_exit 1; assert_contains "$OUT" "deploy.sh"
}

test_verify_checks_outbound_and_localhost_over_ssh() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"; run_in_sandbox ./verify.sh; assert_exit 0
  local S; S="$(grep '^ssh ' "$FAKE_LOG")"
  assert_contains "$S" "ubuntu@203.0.113.10"; assert_contains "$S" "StrictHostKeyChecking=accept-new"
  assert_contains "$S" "http://localhost"; assert_contains "$S" "https://example.com"
  local E; E="$(cat "$SANDBOX/evidence/aws/04-verify.txt")"
  assert_contains "$E" "example.com"; assert_contains "$E" "방식 B"
}

test_verify_fails_when_ssh_unreachable() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; FAKE_SSH_FAIL=1 run_in_sandbox ./verify.sh; assert_exit 1
  assert_contains "$(cat "$SANDBOX/evidence/aws/04-verify.txt")" "FAIL"
}

# ---------------------------------------------------------------- Task 5: cleanup.sh

test_cleanup_reverse_order_and_verification() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"; run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_order "terminate-instances" "wait instance-terminated"; assert_order "wait instance-terminated" "delete-security-group"
  assert_order "delete-security-group" "delete-route-table"; assert_order "detach-internet-gateway" "delete-internet-gateway"
  assert_order "delete-internet-gateway" "delete-vpc"; assert_order "delete-subnet" "delete-vpc"
  assert_contains "$(cat "$SANDBOX/evidence/aws/05-cleanup.txt")" "describe-vpcs"
  [ ! -f "$SANDBOX/state/resources.env" ] || fail "상태 파일이 남아 있음"
}

test_cleanup_without_state_discovers_by_tag() {
  setup_sandbox; write_env; FAKE_DISCOVER=1 run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" "tag:Project,Values=b3-1"; assert_contains "$(cat "$FAKE_LOG")" "delete-vpc --vpc-id vpc-0fake"
}

test_cleanup_reports_leftovers() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; FAKE_LEFTOVER=1 run_in_sandbox ./cleanup.sh; assert_exit 1
  assert_contains "$OUT" "남은 리소스"
}

test_cleanup_disassociates_route_table_before_delete() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"; run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" "disassociate-route-table --association-id rtbassoc-0fake"
  assert_order "disassociate-route-table" "delete-route-table"
  assert_contains "$(cat "$FAKE_LOG")" "detach-internet-gateway --internet-gateway-id igw-0fake --vpc-id vpc-0fake"
}

test_cleanup_discovered_eip_and_volume_are_released() {
  setup_sandbox; write_env; FAKE_DISCOVER=1 run_in_sandbox ./cleanup.sh; assert_exit 0
  local L; L="$(cat "$FAKE_LOG")"
  assert_contains "$L" "terminate-instances --instance-ids i-0fake"
  assert_contains "$L" "delete-volume --volume-id vol-0fake"
  assert_contains "$L" "release-address --allocation-id eipalloc-0fake"
  assert_order "wait instance-terminated" "delete-volume"
}

test_cleanup_removes_key_pair_and_local_secrets() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  : > "$SANDBOX/state/known_hosts"
  run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" "delete-key-pair --key-name b3-1-key"
  [ ! -e "$SANDBOX/state/b3-1-key.pem" ] || fail "pem이 남아 있음"
  [ ! -e "$SANDBOX/state/known_hosts" ] || fail "known_hosts가 남아 있음"
  ls "$SANDBOX"/state/resources.cleaned-*.env > /dev/null 2>&1 || fail "정리된 상태 파일 보관본이 없음"
  local E; E="$(cat "$SANDBOX/evidence/aws/05-cleanup.txt")"
  for kw in describe-instances describe-volumes describe-addresses describe-internet-gateways; do assert_contains "$E" "$kw"; done
}

test_cleanup_keeps_going_after_a_failed_step() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  FAKE_FAIL_ON=delete-security-group run_in_sandbox ./cleanup.sh; assert_exit 1
  assert_contains "$OUT" "[WARN]"; assert_contains "$(cat "$FAKE_LOG")" "delete-vpc --vpc-id vpc-0fake"
  [ -f "$SANDBOX/state/resources.env" ] || fail "실패가 있었는데 상태 파일을 치움"
}

test_cleanup_twice_is_safe() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; run_in_sandbox ./cleanup.sh; assert_exit 0
  : > "$FAKE_LOG"; run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_not_contains "$(cat "$FAKE_LOG")" "terminate-instances"
}

test_cleanup_does_not_need_my_ip() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  FAKE_IP="not-an-ip" run_in_sandbox ./cleanup.sh; assert_exit 0
}

# ---------------------------------------------------------------- Task 6: aws CLI 설치 + IAM 최소권한

test_installer_url_by_arch() {
  ( source lib/common.sh; source lib/awscli.sh
    [ "$(awscli_installer_url x86_64)" = "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ] || fail x86
    [ "$(awscli_installer_url aarch64)" = "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ] || fail arm )
}

test_installer_url_rejects_unknown_arch() {
  local out rc=0
  out="$( (source lib/common.sh; source lib/awscli.sh; awscli_installer_url armv7l) 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "알 수 없는 아키텍처인데 성공함"
  assert_contains "$out" "armv7l"
}

test_ensure_awscli_installs_into_project_without_sudo() {
  setup_sandbox
  # aws가 없는 PATH: 필요한 도구만 링크하고 curl은 가짜를 쓴다
  local bin="$SANDBOX/minbin" t
  mkdir -p "$bin"
  for t in bash env uname mktemp unzip rm mkdir chmod cat sed tr grep head tail dirname cp ln; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  ln -s "$SANDBOX/tests/fake-bin/curl" "$bin/curl"
  # 가짜 설치 패키지: aws/install -i DIR -b BINDIR 가 BINDIR/aws 를 만든다
  mkdir -p "$SANDBOX/pkg/aws"
  cat > "$SANDBOX/pkg/aws/install" << 'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -i) i="$2"; shift ;; -b) b="$2"; shift ;; esac; shift; done
mkdir -p "$i" "$b"
printf '#!/usr/bin/env bash\necho aws-cli/2.0.0-fake-installed\n' > "$b/aws"
chmod +x "$b/aws"
EOF
  chmod +x "$SANDBOX/pkg/aws/install"
  (cd "$SANDBOX/pkg" && python3 -m zipfile -c "$SANDBOX/awscli.zip" aws/)
  OUT="$(cd "$SANDBOX" && env -i PATH="$bin" HOME="$SANDBOX" FAKE_LOG="$FAKE_LOG" FAKE_AWSCLI_ZIP="$SANDBOX/awscli.zip" \
    bash -c 'source lib/common.sh; source lib/awscli.sh; ensure_awscli; command -v aws; aws --version' 2>&1)"
  RC=$?
  assert_exit 0
  assert_contains "$OUT" "$SANDBOX/.tools/bin/aws"
  assert_contains "$OUT" "aws-cli/2.0.0-fake-installed"
  assert_contains "$(cat "$FAKE_LOG")" "https://awscli.amazonaws.com/awscli-exe-linux-"
}

test_iam_policy_is_least_privilege() {
  python3 - iam/least-privilege-policy.json <<'PY' || fail "IAM 정책 검사 실패"
import json, sys
p = json.load(open(sys.argv[1])); acts = []
for s in p["Statement"]:
    a = s["Action"]; a = [a] if isinstance(a, str) else a
    if s["Effect"] == "Allow":
        acts += a
        assert s["Condition"]["StringEquals"]["aws:RequestedRegion"] == "ap-northeast-2"
assert "*" not in acts and "ec2:*" not in acts
assert not [x for x in acts if not x.startswith("ec2:")], "EC2 외 서비스 권한 존재"
for need in ["ec2:RunInstances", "ec2:AuthorizeSecurityGroupIngress", "ec2:CreateRoute", "ec2:DeleteVpc"]:
    assert need in acts, need
assert any(s["Effect"] == "Deny" for s in p["Statement"])
PY
}

# 스크립트가 부르는 모든 aws ec2 작업이 정책에서 허용되는지(실제 AWS에서 권한 부족으로 멈추지 않게)
test_iam_policy_covers_every_ec2_call_in_scripts() {
  python3 - iam/least-privilege-policy.json deploy.sh verify.sh cleanup.sh <<'PY' || fail "정책에 빠진 권한이 있음"
import fnmatch, json, re, sys
p = json.load(open(sys.argv[1]))
allowed = []
for s in p["Statement"]:
    if s["Effect"] == "Allow":
        a = s["Action"]; allowed += [a] if isinstance(a, str) else a
ops = set()
for f in sys.argv[2:]:
    ops |= set(re.findall(r"aws ec2 ([a-z][a-z-]+)", open(f).read()))
ops.discard("wait")  # waiter는 Describe* 호출
assert len(ops) > 15, f"추출한 작업 수가 너무 적음: {sorted(ops)}"
missing = []
for op in sorted(ops):
    action = "ec2:" + "".join(w.capitalize() for w in op.split("-"))
    if not any(fnmatch.fnmatchcase(action, pat) for pat in allowed):
        missing.append(action)
assert not missing, f"정책에 없는 작업: {missing}"
PY
}

test_iam_policy_denies_non_free_tier_types() {
  python3 - iam/least-privilege-policy.json <<'PY' || fail "프리 티어 외 유형 차단 규칙 이상"
import json, sys
p = json.load(open(sys.argv[1]))
d = [s for s in p["Statement"] if s["Effect"] == "Deny"][0]
assert d["Action"] in ("ec2:RunInstances", ["ec2:RunInstances"])
assert d["Resource"] == "arn:aws:ec2:*:*:instance/*"
assert sorted(d["Condition"]["StringNotEquals"]["ec2:InstanceType"]) == ["t2.micro", "t3.micro"]
PY
}

test_create_iam_user_writes_env_with_new_keys() {
  setup_sandbox; write_env; echo "MY_IP=203.0.113.77" >> "$SANDBOX/.env"
  ADMIN_AWS_ACCESS_KEY_ID=AKIAADMINADMINADMIN1 ADMIN_AWS_SECRET_ACCESS_KEY=adminSecret \
    run_in_sandbox ./iam/create-iam-user.sh; assert_exit 0
  local L E; L="$(cat "$FAKE_LOG")"; E="$(cat "$SANDBOX/.env")"
  assert_contains "$L" "iam create-user --user-name b3-1-operator"
  assert_contains "$L" "iam create-policy --policy-name b3-1-least-privilege --policy-document file://"
  assert_contains "$L" "iam attach-user-policy --user-name b3-1-operator --policy-arn arn:aws:iam::123456789012:policy/b3-1-least-privilege"
  assert_not_contains "$L" "AdministratorAccess"; assert_not_contains "$L" "create-login-profile"
  assert_contains "$E" "AWS_ACCESS_KEY_ID=AKIAFAKEOPERATOR0001"
  assert_contains "$E" "AWS_SECRET_ACCESS_KEY=fakeOperatorSecret/abc+123"
  assert_contains "$E" "MY_IP=203.0.113.77"
  assert_contains "$(cat "$SANDBOX/.env.bak")" "AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE"
  [ "$(stat -c %a "$SANDBOX/.env")" = "600" ] || fail ".env 권한이 600이 아님"
  # 새로 만든 .env로 바로 사전 점검이 통과해야 한다
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
}

test_create_iam_user_reuses_existing_user_and_policy() {
  setup_sandbox
  FAKE_IAM_USER_EXISTS=1 FAKE_IAM_POLICY_EXISTS=1 ADMIN_AWS_ACCESS_KEY_ID=AKIAADMINADMINADMIN1 ADMIN_AWS_SECRET_ACCESS_KEY=adminSecret \
    run_in_sandbox ./iam/create-iam-user.sh; assert_exit 0
  assert_not_contains "$(cat "$FAKE_LOG")" "iam create-user"; assert_not_contains "$(cat "$FAKE_LOG")" "iam create-policy"
  assert_contains "$(cat "$FAKE_LOG")" "iam attach-user-policy"
  assert_contains "$(cat "$SANDBOX/.env")" "AWS_ACCESS_KEY_ID=AKIAFAKEOPERATOR0001"
}

test_create_iam_user_console_option_forces_password_change() {
  setup_sandbox
  ADMIN_AWS_ACCESS_KEY_ID=AKIAADMINADMINADMIN1 ADMIN_AWS_SECRET_ACCESS_KEY=adminSecret \
    run_in_sandbox ./iam/create-iam-user.sh --console; assert_exit 0
  local L; L="$(cat "$FAKE_LOG")"
  assert_contains "$L" "create-login-profile --user-name b3-1-operator"; assert_contains "$L" "--password-reset-required"
  assert_contains "$L" "arn:aws:iam::aws:policy/IAMUserChangePassword"
  assert_contains "$OUT" "https://123456789012.signin.aws.amazon.com/console"
}

test_create_iam_user_needs_admin_credentials_and_rejects_root() {
  setup_sandbox; run_in_sandbox ./iam/create-iam-user.sh; assert_exit 1
  assert_contains "$OUT" "ADMIN_AWS_ACCESS_KEY_ID"
  FAKE_ROOT=1 ADMIN_AWS_ACCESS_KEY_ID=AKIAADMINADMINADMIN1 ADMIN_AWS_SECRET_ACCESS_KEY=adminSecret \
    run_in_sandbox ./iam/create-iam-user.sh; assert_exit 1
  assert_contains "$OUT" "루트"; assert_not_contains "$(cat "$FAKE_LOG")" "iam create-user"
}

# ---------------------------------------------------------------- Fix round 1: 리뷰 후속 회귀 테스트

# [1] 셸에 남은 키가 .env를 대신하면 안 된다(다른 계정·루트 키가 조용히 쓰이는 사고 방지)
test_shell_exported_keys_do_not_replace_empty_env_keys() {
  setup_sandbox; printf 'AWS_ACCESS_KEY_ID=\nAWS_SECRET_ACCESS_KEY=\n' > "$SANDBOX/.env"
  run_in_sandbox_env AWS_ACCESS_KEY_ID=AKIASHELLSHELLSHELL1 AWS_SECRET_ACCESS_KEY=shellSecret -- ./deploy.sh
  assert_exit 1; assert_contains "$OUT" "AWS_ACCESS_KEY_ID"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# [1] 셸에 남은 임시 토큰이 .env의 영구 키와 섞이면 AWS가 거부한다
test_shell_session_token_does_not_mix_with_env_keys() {
  setup_sandbox; write_env
  run_in_sandbox_env AWS_SESSION_TOKEN=staleTokenFromShell -- ./deploy.sh --preflight-only
  assert_exit 0; assert_contains "$(cat "$FAKE_LOG")" "sts get-caller-identity"
}

# [1] MY_IP 출처 로그는 실제 출처를 말해야 한다
test_my_ip_source_log_reports_shell_origin() {
  setup_sandbox; write_env
  run_in_sandbox_env MY_IP=203.0.113.88 -- ./deploy.sh --preflight-only; assert_exit 0
  assert_contains "$OUT" "203.0.113.88/32 (셸 환경변수 MY_IP)"
  assert_not_contains "$(cat "$FAKE_LOG")" "checkip"
}

# [2] bash 4 미만이면 아무것도 하기 전에 안내하고 멈춘다(mapfile 등 bash 4 기능 사용)
test_bash_older_than_4_is_rejected_with_guidance() {
  local out rc=0
  out="$( (source lib/common.sh; check_bash_version 3) 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "bash 3인데 통과함"
  assert_contains "$out" "bash 4"
  ( source lib/common.sh; check_bash_version 5 ) || fail "bash 5인데 거부함"
}

# [3] 여러 인스턴스 중 하나가 이미 없어도 나머지는 따로 종료·대기해야 한다
test_cleanup_terminates_each_instance_separately() {
  setup_sandbox; write_env
  mkdir -p "$SANDBOX/state"; echo "INSTANCE_ID=i-0gone" > "$SANDBOX/state/resources.env"
  FAKE_DISCOVER=1 FAKE_NOTFOUND_FOR=i-0gone run_in_sandbox ./cleanup.sh; assert_exit 0
  grep -q '^aws ec2 terminate-instances --instance-ids i-0fake region=' "$FAKE_LOG" || fail "i-0fake 단독 종료 호출 없음"
  grep -q '^aws ec2 wait instance-terminated --instance-ids i-0fake region=' "$FAKE_LOG" || fail "i-0fake 단독 대기 없음"
  assert_contains "$OUT" "이미 없음: EC2 종료 요청 i-0gone"
}

# [4] 내 IP 마스킹은 숫자 경계를 지켜야 한다(다른 IP의 일부를 깨뜨리지 않음)
test_mask_stream_respects_number_boundaries() {
  local out odd='/tmp/b3 (x)+y.[z]'
  out="$( (source lib/common.sh
    MY_IP=1.2.3.4; ACCOUNT_ID=123456789012; ROOT_DIR="$odd"
    printf '%s\n' "src 1.2.3.4/32 a=11.2.3.45 b=1.2.3.45 c=21.2.3.4 d=1.2.3.4,1.2.3.4" \
      "acct 123456789012 long 91234567890123" "$odd/state/k.pem /tmp/b3 (x)+yQ[z]/q" | mask_stream) 2>&1)"
  assert_contains "$out" "src 1.2.*.*/32 a=11.2.3.45 b=1.2.3.45 c=21.2.3.4 d=1.2.*.*,1.2.*.*"
  assert_contains "$out" "acct 1234****9012 long 91234567890123"
  assert_contains "$out" "./state/k.pem /tmp/b3 (x)+yQ[z]/q"
}

# [5] 고른 유형이 계정의 프리 티어 대상이 아니면 경고만 하고 막지는 않는다
test_free_tier_mismatch_warns_without_blocking() {
  setup_sandbox; write_env
  FAKE_FREE_TIER_TYPES="t2.micro" run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_contains "$OUT" "[WARN]"; assert_contains "$OUT" "INSTANCE_TYPE=t2.micro"
  assert_contains "$(cat "$FAKE_LOG")" "describe-instance-types --filters Name=free-tier-eligible,Values=true"
  FAKE_FREE_TIER_TYPES="t3.micro t3.small" run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_not_contains "$OUT" "[WARN]"
}

# [6] 방금 만든 VPC·서브넷이 조회될 때까지 기다린다(최종 일관성)
test_deploy_waits_for_vpc_and_subnet_to_exist() {
  setup_sandbox; write_env
  FAKE_FAIL_ONCE_ON=describe-subnets FAKE_FAIL_ONCE_WITH=InvalidSubnetID.NotFound run_in_sandbox ./deploy.sh; assert_exit 0
  assert_order "wait vpc-exists --vpc-ids vpc-0fake" "wait vpc-available"
  assert_order "describe-subnets --subnet-ids subnet-0fake" "wait subnet-available"
  [ "$(grep -c 'describe-subnets --subnet-ids subnet-0fake' "$FAKE_LOG")" -ge 2 ] || fail "NotFound 뒤 다시 조회하지 않음"
  assert_not_contains "$OUT" "단계 실패"
}

# [9] cleanup 분기: DependencyViolation 재시도, NotFound는 이미 없음, 그 밖의 오류는 재시도 없이 경고
test_cleanup_retries_dependency_violation_then_succeeds() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"
  FAKE_FAIL_ONCE_ON=delete-security-group FAKE_FAIL_ONCE_WITH=DependencyViolation run_in_sandbox ./cleanup.sh; assert_exit 0
  [ "$(grep -c ' delete-security-group ' "$FAKE_LOG")" -eq 2 ] || fail "DependencyViolation 뒤 한 번 더 시도하지 않음"
  assert_contains "$OUT" "다시 시도"
}

test_cleanup_gives_up_after_retry_limit() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"
  CLEANUP_RETRIES=3 FAKE_FAIL_ON=delete-security-group FAKE_FAIL_CODE=DependencyViolation run_in_sandbox ./cleanup.sh; assert_exit 1
  [ "$(grep -c ' delete-security-group ' "$FAKE_LOG")" -eq 3 ] || fail "재시도 상한(3)을 지키지 않음"
  assert_contains "$OUT" "실패: SG 삭제 sg-0fake"
}

test_cleanup_treats_not_found_as_already_deleted() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  FAKE_NOTFOUND_FOR=subnet-0fake run_in_sandbox ./cleanup.sh; assert_exit 0
  assert_contains "$OUT" "이미 없음: Subnet 삭제 subnet-0fake"
  assert_contains "$(cat "$SANDBOX/evidence/aws/05-cleanup.txt")" "→ 이미 없음: Subnet 삭제 subnet-0fake"
}

test_cleanup_does_not_retry_other_errors() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"
  FAKE_FAIL_ON=delete-vpc run_in_sandbox ./cleanup.sh; assert_exit 1
  [ "$(grep -c ' delete-vpc ' "$FAKE_LOG")" -eq 1 ] || fail "일반 오류를 재시도함"
}

# ---------------------------------------------------------------- Fix round 2: 재리뷰 후속 회귀 테스트

# [1] .env의 MY_IP=x.x.x.x/32(허용 형식)가 마스킹 sed를 깨뜨려 cleanup이 삭제 전에 멈추면 안 된다
test_full_flow_survives_my_ip_with_cidr_suffix() {
  setup_sandbox; write_env; echo "MY_IP=203.0.113.5/32" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 0
  run_in_sandbox ./verify.sh; assert_exit 0; assert_not_contains "$OUT" "sed:"
  : > "$FAKE_LOG"; run_in_sandbox ./cleanup.sh; assert_exit 0; assert_not_contains "$OUT" "sed:"
  assert_contains "$(cat "$FAKE_LOG")" "delete-vpc --vpc-id vpc-0fake"
  assert_contains "$(cat "$SANDBOX/evidence/aws/05-cleanup.txt")" "잔여 리소스 0건"
  local E; E="$(cat "$SANDBOX/evidence/aws/00-identity.txt")"
  assert_contains "$E" "203.0.*.*/32"; assert_not_contains "$E" "203.0.113.5"
}

# [1] IP가 아닌 MY_IP·12자리가 아닌 계정 ID에도 마스킹이 무한 반복하지 않고 끝나야 한다
test_mask_stream_terminates_on_invalid_values() {
  local out rc=0
  out="$(timeout 5 bash -c 'source lib/common.sh; MY_IP=abc; ACCOUNT_ID=12; printf "%s\n" "xabc 12 yy" | mask_stream' 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "mask_stream이 끝나지 않거나 실패함(코드 $rc)"
  assert_contains "$out" "xabc 12 yy"
  out="$(timeout 5 bash -c 'source lib/common.sh; MY_IP=203.0.113.5/32; printf "%s\n" "src 203.0.113.5/32" | mask_stream' 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "MY_IP=/32에서 mask_stream 실패(코드 $rc)"
  assert_contains "$out" "src 203.0.*.*/32"
}

# [2] 도움말이 --preflight-only의 프리 티어 확인을 설명한다
test_deploy_help_mentions_free_tier_check() {
  setup_sandbox; run_in_sandbox ./deploy.sh --help; assert_exit 0
  assert_contains "$OUT" "--preflight-only"; assert_contains "$OUT" "프리 티어"
}

# [4] 방금 만든 IGW·Route Table·SG가 조회될 때까지 기다린 뒤 연결·경로·규칙을 추가한다
test_deploy_waits_for_new_igw_route_table_and_sg() {
  setup_sandbox; write_env
  FAKE_FAIL_ONCE_ON=describe-internet-gateways FAKE_FAIL_ONCE_WITH=InvalidInternetGatewayID.NotFound run_in_sandbox ./deploy.sh
  assert_exit 0; assert_not_contains "$OUT" "단계 실패"
  [ "$(lines_before "describe-internet-gateways --internet-gateway-ids igw-0fake" "attach-internet-gateway")" -ge 2 ] ||
    fail "IGW: NotFound 뒤 다시 조회하고 연결해야 함"
  setup_sandbox; write_env
  FAKE_FAIL_ONCE_ON=describe-route-tables FAKE_FAIL_ONCE_WITH=InvalidRouteTableID.NotFound run_in_sandbox ./deploy.sh
  assert_exit 0; assert_not_contains "$OUT" "단계 실패"
  [ "$(lines_before "describe-route-tables --route-table-ids rtb-0fake" "create-route ")" -ge 2 ] ||
    fail "Route Table: NotFound 뒤 다시 조회하고 경로를 추가해야 함"
  setup_sandbox; write_env
  FAKE_FAIL_ONCE_ON=describe-security-groups FAKE_FAIL_ONCE_WITH=InvalidGroup.NotFound run_in_sandbox ./deploy.sh
  assert_exit 0; assert_not_contains "$OUT" "단계 실패"
  [ "$(lines_before "describe-security-groups --group-ids sg-0fake" "authorize-security-group-ingress")" -ge 2 ] ||
    fail "SG: NotFound 뒤 다시 조회하고 규칙을 추가해야 함"
}

# ---------------------------------------------------------------- ai_chatbot 배포: 사전 점검 (AWS 호출 전)

# 앱 소스가 git 저장소가 아니거나 없으면 AWS를 한 번도 부르지 않고 멈춘다
test_deploy_stops_before_aws_when_app_src_is_not_a_git_repo() {
  setup_sandbox; write_env; mkdir -p "$SANDBOX-plain"
  echo "APP_SRC=$SANDBOX-plain" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "APP_SRC"; assert_contains "$OUT" "git 저장소"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
  setup_sandbox; write_env; echo "APP_SRC=$SANDBOX-없는-폴더" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1; assert_contains "$OUT" "APP_SRC"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# 앱 .env가 없으면 AWS를 부르기 전에 멈추고 준비 방법을 알려 준다
test_deploy_stops_before_aws_when_app_env_file_missing() {
  setup_sandbox; write_env; echo "APP_ENV_FILE=$APP_FIX/없는.env" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "APP_ENV_FILE"; assert_contains "$OUT" ".env.example"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
  # 기본값(APP_SRC/.env)이 없을 때도 같다
  setup_sandbox; write_env; rm -f "$APP_FIX/.env"
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 1; assert_contains "$OUT" "APP_ENV_FILE"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# 없는 브랜치·커밋을 APP_REF로 주면 AWS를 부르기 전에 멈춘다
test_deploy_stops_before_aws_when_app_ref_is_unknown() {
  setup_sandbox; write_env; echo "APP_REF=없는-브랜치" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1; assert_contains "$OUT" "APP_REF"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# APP_REF 트리에 app/main.py·requirements.txt가 없으면(ai_chatbot의 main은 초기 커밋뿐) 멈추고 develop을 안내한다
test_deploy_stops_before_aws_when_app_ref_has_no_app_code() {
  setup_sandbox; write_env; echo "APP_REF=no-app" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "APP_REF에 앱 코드가 없습니다"; assert_contains "$OUT" "APP_REF=develop"
  assert_not_contains "$(cat "$FAKE_LOG" 2>/dev/null)" "aws "
}

# LLM_API_KEY가 비었거나 커밋하지 않은 변경이 있으면 경고만 하고 진행한다. 키 값은 어떤 경우에도 내보내지 않는다
test_preflight_warns_but_continues_for_empty_llm_key_and_uncommitted_changes() {
  setup_sandbox; write_env
  printf '%s\n' "SECRET_KEY=$SECRET_MARKER" "LLM_API_KEY=" > "$APP_FIX/llm-empty.env"
  echo "APP_ENV_FILE=$APP_FIX/llm-empty.env" >> "$SANDBOX/.env"
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_contains "$OUT" "[WARN]"; assert_contains "$OUT" "LLM_API_KEY"
  assert_no_secret_leak
  setup_sandbox; write_env; echo "# 아직 커밋 안 함" >> "$APP_FIX/app/main.py"
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_contains "$OUT" "커밋하지 않은 변경"
  # 키가 있고 작업 트리가 깨끗하면 경고 없음
  setup_sandbox; write_env
  run_in_sandbox ./deploy.sh --preflight-only; assert_exit 0
  assert_not_contains "$OUT" "[WARN]"; assert_no_secret_leak
}

# 앱 경로를 비우면 이 프로젝트 기준 ../../../ai_chatbot 을 쓴다(실제 ai_chatbot이 아니라 임시 배치로 확인)
test_app_src_defaults_to_sibling_checkout() {
  local base="$TEST_ROOT/layout" out want
  mkdir -p "$base/mission/b3-1/answers"; make_app_repo "$base/ai_chatbot"
  want="$(cd "$base" && pwd -P)/ai_chatbot"
  out="$( (source lib/common.sh; ROOT_DIR="$base/mission/b3-1/answers"; APP_SRC=""; APP_ENV_FILE=""; APP_REF=""
    resolve_app_source; printf '%s|%s|%s\n' "$APP_SRC" "$APP_ENV_FILE" "$APP_REF") 2>&1)"
  assert_contains "$out" "$want|$want/.env|HEAD"
  # 상대 경로는 이 프로젝트(answers) 기준으로 푼다
  out="$( (source lib/common.sh; ROOT_DIR="$base/mission/b3-1/answers"
    APP_SRC="../../../ai_chatbot"; APP_ENV_FILE="../../../ai_chatbot/prod.env"; APP_REF=develop
    resolve_app_source; printf '%s|%s|%s\n' "$APP_SRC" "$APP_ENV_FILE" "$APP_REF") 2>&1)"
  assert_contains "$out" "$want|$want/prod.env|develop"
}

# ---------------------------------------------------------------- ai_chatbot 배포: 전송·설치

# .env는 파일 경로로 scp한다(값을 명령줄에 싣지 않는다). 비밀 표식은 호출 기록·증거·화면·상태 어디에도 없다
test_deploy_uploads_app_env_by_path_and_never_leaks_secret_values() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local L T E; L="$(cat "$FAKE_LOG")"
  assert_contains "$L" "$APP_FIX/.env ubuntu@203.0.113.10:.b3-1-upload/app.env"
  assert_contains "$L" "ubuntu@203.0.113.10:.b3-1-upload/app.tar.gz"
  assert_contains "$L" "ubuntu@203.0.113.10:.b3-1-upload/provision-app.sh"
  grep '^scp ' "$FAKE_LOG" | grep -q 'StrictHostKeyChecking=accept-new' || fail "scp에 호스트 키 확인 옵션 없음"
  cmp -s "$APP_FIX/.env" "$REMOTE_DIR/app.env" || fail "서버로 간 .env가 원본 파일과 다름"
  # 소스는 git archive라 추적하지 않는 .env가 섞이지 않는다
  T="$(tar -tzf "$REMOTE_DIR/app.tar.gz" 2>&1)"
  assert_contains "$T" "app/main.py"; assert_contains "$T" "requirements.txt"
  assert_not_contains "$T" ".env"
  assert_no_secret_leak
  E="$(cat "$SANDBOX/evidence/aws/03b-app.txt" 2>/dev/null)"
  assert_contains "$E" "provision-app.sh"; assert_contains "$E" "<APP_SRC>"; assert_contains "$E" "<APP_ENV_FILE>"
  assert_not_contains "$E" "$APP_FIX"
}

# 서버 준비(SSH·user-data 완료) → 업로드 → 설치 → 외부 검증 순서
test_deploy_app_step_order() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_order "run-instances" "user-data.done"
  assert_order "user-data.done" "scp "
  assert_order ".b3-1-upload/app.env" "sudo bash .b3-1-upload/provision-app.sh"
  assert_order "sudo bash .b3-1-upload/provision-app.sh" "http://203.0.113.10/health"
}

# 배포한 커밋 SHA를 상태 파일에 적고, 같은 커밋·같은 .env면 다시 올리지 않는다. 커밋이나 .env가 바뀌면 다시 배포한다
test_deploy_records_commit_and_skips_same_commit_redeploy() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local sha1 sha2; sha1="$(git -C "$APP_FIX" rev-parse HEAD)"
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "APP_COMMIT=$sha1"
  assert_contains "$(cat "$FAKE_LOG")" "provision-app.sh /home/ubuntu/.b3-1-upload $sha1"
  : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_contains "$OUT" "재배포 생략"
  assert_not_contains "$(cat "$FAKE_LOG")" "scp "; assert_not_contains "$(cat "$FAKE_LOG")" "provision-app.sh"
  assert_contains "$(cat "$FAKE_LOG")" "http://203.0.113.10/health"
  echo "# v2" >> "$APP_FIX/app/main.py"; tgit -C "$APP_FIX" commit -qam "v2"
  sha2="$(git -C "$APP_FIX" rev-parse HEAD)"
  : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" "provision-app.sh /home/ubuntu/.b3-1-upload $sha2"
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "APP_COMMIT=$sha2"
  # .env만 바뀌어도 다시 올린다(예: 나중에 LLM_API_KEY를 채운 경우)
  printf 'NAVER_TIMEOUT_SECONDS=5\n' >> "$APP_FIX/.env"
  : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_contains "$(cat "$FAKE_LOG")" ".b3-1-upload/app.env"
}

# SSH가 아직 안 되면 기다렸다가 진행하고, user-data가 실패했으면 업로드하지 않고 확인 방법을 알려 준다
test_deploy_waits_for_ssh_then_fails_fast_on_user_data_error() {
  setup_sandbox; write_env
  FAKE_SSH_NOT_READY=2 run_in_sandbox ./deploy.sh; assert_exit 0
  [ "$(grep -c 'user-data.done' "$FAKE_LOG")" -ge 3 ] || fail "접속 실패 뒤 다시 확인하지 않음"
  assert_contains "$(cat "$FAKE_LOG")" "sudo bash .b3-1-upload/provision-app.sh"
  setup_sandbox; write_env
  FAKE_USERDATA_ERROR=1 run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "cloud-init-output.log"; assert_contains "$OUT" "단계 실패"
  assert_not_contains "$(cat "$FAKE_LOG")" "scp "
  [ "$(grep -c 'user-data.done' "$FAKE_LOG")" -eq 1 ] || fail "user-data 오류인데 계속 기다림"
}

# 앱 설치가 실패하면 단계 이름과 함께 멈추고, 커밋을 기록하지 않아 다시 실행하면 설치를 다시 한다
test_deploy_app_install_failure_is_resumable() {
  setup_sandbox; write_env
  FAKE_PROVISION_RC=1 run_in_sandbox ./deploy.sh; assert_exit 1
  assert_contains "$OUT" "단계 실패: 앱 배포"; assert_contains "$OUT" "03b-app.txt"
  assert_not_contains "$(cat "$SANDBOX/state/resources.env")" "APP_COMMIT="
  : > "$FAKE_LOG"; run_in_sandbox ./deploy.sh; assert_exit 0
  assert_not_contains "$(cat "$FAKE_LOG")" "run-instances"
  assert_contains "$(cat "$FAKE_LOG")" "sudo bash .b3-1-upload/provision-app.sh"
  assert_contains "$(cat "$SANDBOX/state/resources.env")" "APP_COMMIT="
}

# 보안 그룹은 80·22만 연다. 앱 포트 8000은 열지 않고 uvicorn은 127.0.0.1에만 바인딩한다
test_security_group_has_no_8000_rule() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  local A; A="$(grep ' authorize-security-group-ingress ' "$FAKE_LOG")"
  assert_contains "$A" "FromPort=80,ToPort=80"; assert_contains "$A" "FromPort=22,ToPort=22"
  assert_not_contains "$A" "8000"
  [ "$(grep -o 'IpProtocol=' <<< "$A" | wc -l)" -eq 2 ] || fail "인바운드 규칙이 2개가 아님"
  ! grep -qE -- '--host[ =]0\.0\.0\.0' server/*.sh || fail "uvicorn을 0.0.0.0에 바인딩하면 안 됨"
  grep -qF -- '--host 127.0.0.1 --port 8000' server/provision-app.sh 2>/dev/null || fail "uvicorn 127.0.0.1:8000 바인딩 없음"
}

# 서버 설치 스크립트: 127.0.0.1:8000·systemd·.env 600·DB 절대 경로·SECRET_KEY 생성, 비밀값을 찍는 xtrace 없음
test_provision_app_static() {
  local f=server/provision-app.sh kw
  [ -f "$f" ] || { fail "$f 없음"; return; }
  bash -n "$f" || fail "$f 문법 오류"
  grep -q 'set -Eeuo pipefail' "$f" || fail "set -Eeuo pipefail 없음"
  ! grep -qE '^[[:space:]]*set -[a-zA-Z]*x' "$f" || fail "xtrace(set -x)는 비밀값을 찍을 수 있어 금지"
  grep -qF -- '--host 127.0.0.1 --port 8000 --workers 1' "$f" || fail "uvicorn 실행 인자 없음"
  for kw in 'User=ubuntu' 'WorkingDirectory=/home/ubuntu/ai_chatbot' 'Restart=always' 'ai-chatbot' \
    'daemon-reload' 'systemctl enable' 'systemctl restart' 'sqlite:////home/ubuntu/ai_chatbot/app.db' \
    'token_hex(32)' '0o600' 'requirements.txt' '/health'; do
    grep -qF -- "$kw" "$f" || fail "$kw 없음"
  done
  grep -q '/run/systemd/system' "$f" || fail "systemd 없는 환경(로컬 리허설) 분기 없음"
}

# ---------------------------------------------------------------- ai_chatbot 배포: 검증

# /health는 앱의 JSON {"status":"ok"}여야 PASS. "OK"만 오면(예전 Nginx 고정 응답) 앱이 응답한 것이 아니므로 FAIL
test_verify_health_requires_app_json() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; assert_exit 0
  run_in_sandbox ./verify.sh; assert_exit 0
  assert_contains "$(grep -F '외부 GET /health' "$SANDBOX/evidence/aws/04-verify.txt")" "PASS"
  assert_contains "$(cat "$SANDBOX/evidence/aws/04-verify.txt")" '{"status":"ok"}'
  FAKE_HEALTH_BODY=OK run_in_sandbox ./verify.sh; assert_exit 1
  assert_contains "$(grep -F '외부 GET /health' "$SANDBOX/evidence/aws/04-verify.txt")" "FAIL"
}

# 비로그인 / 는 원래 303(→ /login). 그대로 기록하고, -L로 따라간 로그인 화면 200과 ai-chatbot 서비스 상태를 판정한다
test_verify_root_redirect_and_follow_and_app_service() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh; : > "$FAKE_LOG"
  run_in_sandbox ./verify.sh; assert_exit 0
  local E S; E="$(cat "$SANDBOX/evidence/aws/04-verify.txt")"; S="$(grep '^ssh ' "$FAKE_LOG")"
  assert_contains "$(grep -F '외부 GET / (원 응답' <<< "$E")" "| 303 | PASS |"
  assert_contains "$(grep -F '외부 GET -L /' <<< "$E")" "| 200 | PASS |"
  assert_contains "$(grep -F 'ai-chatbot 서비스' <<< "$E")" "| active | PASS |"
  assert_contains "$(grep -F '인스턴스 안 curl -L http://localhost' <<< "$E")" "| 200 | PASS |"
  assert_contains "$(grep -F '인스턴스 안 curl http://localhost/health' <<< "$E")" "PASS"
  assert_contains "$S" "systemctl is-active ai-chatbot"; assert_contains "$S" "curl -sL"
  grep '^curl ' "$FAKE_LOG" | grep -q -- '-L' || fail "외부에서 -L로 따라가 보지 않음"
  FAKE_APP_STATE=failed run_in_sandbox ./verify.sh; assert_exit 1
  assert_contains "$(grep -F 'ai-chatbot 서비스' "$SANDBOX/evidence/aws/04-verify.txt")" "FAIL"
}

# LLM API에 닿지 않으면(000) WARN만 남기고 종료 코드는 0(미션 필수 항목이 아니다)
test_verify_llm_unreachable_is_warning_only() {
  setup_sandbox; write_env; run_in_sandbox ./deploy.sh
  FAKE_LLM_CODE=000 run_in_sandbox ./verify.sh; assert_exit 0
  local E; E="$(cat "$SANDBOX/evidence/aws/04-verify.txt")"
  assert_contains "$(grep -F 'LLM API' <<< "$E")" "| 000 | WARN |"
  assert_not_contains "$E" "FAIL"
  assert_contains "$(grep '^ssh ' "$FAKE_LOG")" "https://copa.codyssey.kr/v1/models"
  run_in_sandbox ./verify.sh; assert_exit 0
  assert_contains "$(grep -F 'LLM API' "$SANDBOX/evidence/aws/04-verify.txt")" "| 401 | PASS |"
}

# ---------------------------------------------------------------- 실행

main() {
  local tests=() t pass=0 failed=0 rc
  if [ "$#" -gt 0 ]; then
    tests=("$@")
  else
    # 파일에 적힌 순서대로 test_ 함수를 모은다
    mapfile -t tests < <(grep -oE '^test_[A-Za-z0-9_]+\(\)' "${BASH_SOURCE[0]}" | tr -d '()')
  fi
  for t in "${tests[@]}"; do
    FAIL_MARK="$(mktemp "$TEST_ROOT/fail.XXXXXX")"
    ( cd "$PROJECT_DIR" && "$t" )
    rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$FAIL_MARK" ]; then
      fail "테스트 함수가 비정상 종료(코드 $rc)"
    fi
    if [ -s "$FAIL_MARK" ]; then
      echo "FAIL $t"; failed=$((failed + 1))
    else
      echo "PASS $t"; pass=$((pass + 1))
    fi
  done
  echo "PASS $pass / FAIL $failed"
  [ "$failed" -eq 0 ]
}

main "$@"
