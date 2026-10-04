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

# 프로젝트 사본을 만든다. 사용자의 실제 .env·state·evidence/aws·.tools는 복사하지 않는다
setup_sandbox() {
  SANDBOX="$(mktemp -d "$TEST_ROOT/sandbox.XXXXXX")"
  rsync -a \
    --exclude .git --exclude /state --exclude /.tools --exclude /evidence/aws --exclude __pycache__ \
    --include /.env.example --exclude '/.env' --exclude '/.env.*' \
    "$PROJECT_DIR/" "$SANDBOX/"
  FAKE_LOG="$SANDBOX/calls.log"
}

# 가짜 키 두 개만 채운 .env
write_env() {
  printf '%s\n' \
    "AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE" \
    "AWS_SECRET_ACCESS_KEY=fakeSecretKeyForTestsOnly000000000000000" > "$SANDBOX/.env"
}

# 사본에서 명령을 실행한다. 호스트의 AWS 관련 환경변수는 지우고 가짜 명령을 PATH 앞에 둔다
run_in_sandbox() {
  OUT="$(cd "$SANDBOX" && env \
    -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_REGION -u AWS_DEFAULT_REGION \
    -u MY_IP -u INSTANCE_TYPE -u AZ -u PROJECT \
    PATH="$SANDBOX/tests/fake-bin:$PATH" FAKE_LOG="$FAKE_LOG" \
    VERIFY_WAIT_INTERVAL=0 CLEANUP_RETRY_SLEEP=0 \
    timeout 120 "$@" 2>&1)"
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
    "MY_IP=203.0.113.77   # 내 IP" > "$SANDBOX/.env"
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

test_user_data_static() {
  local f=server/user-data.sh
  [ -f "$f" ] || { fail "$f 없음"; return; }
  bash -n "$f" || fail "$f 문법 오류"
  grep -q 'set -euxo pipefail' "$f" || fail "set -euxo pipefail 없음"
  grep -q 'location = /health' "$f" || fail "/health 블록 없음"
  grep -qF 'return 200 "OK' "$f" || fail '/health 고정 응답(return 200 "OK) 없음'
  grep -q 'listen 80 default_server' "$f" || fail "80 포트 리슨 설정 없음"
  grep -q 'Hello Cloud' "$f" || fail "index.html 문구 없음"
  grep -q '/run/systemd/system' "$f" || fail "systemd 유무 분기 없음"
  grep -q 'nginx -t' "$f" || fail "nginx -t 설정 검사 없음"
  ! grep -qF '0.0.0.0/0' "$f" || fail "user-data에 0.0.0.0/0 문자열이 있으면 안 됨"
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
