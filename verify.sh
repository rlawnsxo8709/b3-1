#!/usr/bin/env bash
# B3-1 외부 접속 검증 — 방식 B(GET /health)가 주 검증이고, 같은 서버의 / 와 SSH 안쪽 점검을 함께 한다.
#   1) 외부 GET http://<퍼블릭IP>/health → 200 + {"status":"ok"} (Nginx를 거쳐 ai_chatbot 앱이 답해야 한다)
#   2) 외부 GET / → 원 응답 기록(비로그인은 303 → /login), curl -L / → 200(로그인 화면, 방식 A)
#   3) SSH(내 IP에서 22) → nginx·ai-chatbot 서비스 상태, 인스턴스 안 curl http://localhost(원 응답)·curl -L(200)·/health,
#      아웃바운드 curl https://example.com(200), LLM API(copa.codyssey.kr) 도달성(키 없이 HTTP 응답이 오면 도달 가능)
# 결과 표(PASS/FAIL/WARN)를 화면과 evidence/aws/04-verify.txt에 남긴다. FAIL이 하나라도 있으면 종료 코드 1.
# WARN은 미션 필수가 아닌 참고 항목(원 응답 코드, LLM API 도달성)이라 종료 코드에 영향을 주지 않는다.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/awscli.sh
source "$SCRIPT_DIR/lib/awscli.sh"

WAIT_TRIES="${VERIFY_WAIT_TRIES:-120}"
WAIT_INTERVAL="${VERIFY_WAIT_INTERVAL:-5}"
EVIDENCE="04-verify.txt"
HEALTH_OK='{"status":"ok"}'
# 서버 안에서 실행할 점검. 한 줄에 key=value 하나씩 돌려준다(값이 비어도 줄 순서가 어긋나지 않게).
# $(...)는 서버에서 펼쳐야 하므로 작은따옴표로 그대로 보낸다
# shellcheck disable=SC2016
REMOTE_CHECKS=(
  'echo "nginx=$(systemctl is-active nginx 2>/dev/null)"'
  'echo "app=$(systemctl is-active ai-chatbot 2>/dev/null)"'
  'echo "local_root=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://localhost)"'
  'echo "local_root_follow=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 10 http://localhost)"'
  'echo "local_health=$(curl -s -w " %{http_code}" --max-time 10 http://localhost/health)"'
  'echo "outbound=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://example.com)"'
  'echo "llm=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://copa.codyssey.kr/v1/models)"'
)
printf -v REMOTE_CMD '%s; ' "${REMOTE_CHECKS[@]}"
REMOTE_CMD="${REMOTE_CMD%; }"
PUBLIC_IP=""
HTTP_CODE=""
HTTP_BODY=""
ROWS=()
FAILS=0
WARNS=0

usage() {
  cat << 'EOF'
사용법: ./verify.sh [--wait]

  (옵션 없음)  바로 검증한다
  --wait       /health가 200을 돌려줄 때까지 5초 간격으로 최대 120번(10분) 기다린 뒤 검증한다
               (첫 부팅의 Nginx·python3-venv 설치와 앱 설치 직후에 사용. deploy.sh가 이 옵션으로 부른다)

판정: PASS/FAIL/WARN. FAIL이 있으면 종료 코드 1. WARN(원 응답 코드, LLM API 도달성)은 참고용이다.
EOF
}

# 외부에서 http://<IP><경로>를 호출해 HTTP_CODE와 HTTP_BODY를 채운다. 연결 실패면 코드 000.
# 추가 curl 옵션(예: -L)은 둘째 인자부터 받는다
http_get() {
  local body path="$1"
  shift
  body="$(mktemp)"
  HTTP_CODE="$(curl -sS "$@" -o "$body" -w '%{http_code}' --max-time 10 "http://${PUBLIC_IP}${path}" 2> /dev/null)" || true
  HTTP_CODE="${HTTP_CODE:-000}"
  HTTP_BODY="$(head -c 2000 "$body" | tr -d '\r')"
  rm -f "$body"
}

# add_row 항목 기대 실제 판정(PASS|FAIL|WARN)
add_row() {
  case "$4" in
    FAIL) FAILS=$((FAILS + 1)) ;;
    WARN) WARNS=$((WARNS + 1)) ;;
  esac
  ROWS+=("| $1 | $2 | $3 | $4 |")
}

# verdict 조건결과(0=참) 거짓일때판정 : PASS 또는 FAIL/WARN을 출력한다
verdict() { if [ "$1" -eq 0 ]; then echo PASS; else echo "$2"; fi; }

# 본문이 앱의 정상 응답 {"status":"ok"}인지(공백 무시)
is_health_ok() { [ "$(printf '%s' "$1" | tr -d '[:space:]')" = "$HEALTH_OK" ]; }

wait_for_health() {
  local i
  log "http://${PUBLIC_IP}/health 가 200을 돌려줄 때까지 기다립니다(최대 $((WAIT_TRIES * WAIT_INTERVAL))초). 첫 부팅 설치와 앱 설치(pip) 때문에 처음에는 3~6분 걸릴 수 있습니다. 502는 Nginx는 떴지만 앱이 아직 안 뜬 상태입니다."
  for ((i = 1; i <= WAIT_TRIES; i++)); do
    http_get /health
    if [ "$HTTP_CODE" = "200" ]; then
      log "/health 응답 확인 (${i}번째 시도)"
      return 0
    fi
    log "대기 중 ${i}/${WAIT_TRIES} — HTTP ${HTTP_CODE}"
    sleep "$WAIT_INTERVAL"
  done
  warn "기다리는 동안 200 응답을 받지 못했습니다. 그대로 검증해 결과를 남깁니다."
}

main() {
  local wait=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait) wait=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "알 수 없는 옵션: $1 (./verify.sh --help)" ;;
    esac
    shift
  done

  local instance_id
  instance_id="$(state_get INSTANCE_ID)"
  if [ -z "$instance_id" ]; then
    die "배포 기록(state/resources.env의 INSTANCE_ID)이 없습니다. 먼저 ./deploy.sh를 실행하세요."
  fi
  load_env
  ensure_awscli

  # 중지 후 재시작하면 퍼블릭 IP가 바뀌므로 매번 다시 조회한다
  PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)" ||
    die "인스턴스 $instance_id 정보를 조회하지 못했습니다. 이미 정리됐다면 ./deploy.sh로 다시 배포하세요."
  if ! is_ipv4 "$PUBLIC_IP"; then
    die "인스턴스 $instance_id 에 퍼블릭 IP가 없습니다(값: $PUBLIC_IP). 인스턴스가 running인지, 서브넷의 퍼블릭 IP 자동 할당이 켜져 있는지 확인하세요."
  fi
  state_set PUBLIC_IP "$PUBLIC_IP"

  if [ "$wait" = 1 ]; then
    wait_for_health
  fi

  evidence_begin "$EVIDENCE" "외부 접속 검증 — 방식 B: GET http://${PUBLIC_IP}/health (200 + {\"status\":\"ok\"}, ai_chatbot 앱 응답)"
  evidence_note "$EVIDENCE" "# 대상 인스턴스: $instance_id / 배포한 앱 커밋: $(state_get APP_COMMIT)"

  # 1) 방식 B — 외부에서 /health. Nginx(80)를 거쳐 앱(127.0.0.1:8000)이 답해야 200 + {"status":"ok"}
  record "$EVIDENCE" -- curl -sS -i --max-time 10 "http://${PUBLIC_IP}/health" > /dev/null || true
  http_get /health
  local body_line="${HTTP_BODY%%$'\n'*}" ok=1
  if [ "$HTTP_CODE" = "200" ] && is_health_ok "$HTTP_BODY"; then ok=0; fi
  add_row "외부 GET /health (방식 B)" "200 + $HEALTH_OK" "$HTTP_CODE + ${body_line:-빈 본문}" "$(verdict "$ok" FAIL)"

  # 2) 같은 서버의 / — 비로그인이면 앱이 303으로 /login에 보낸다(앱 코드 그대로). 원 응답을 기록하고,
  #    리다이렉트를 따라간 로그인 화면 200으로 "페이지가 정상 표시된다"(방식 A)를 판정한다
  record "$EVIDENCE" -- curl -sS -i --max-time 10 "http://${PUBLIC_IP}/" > /dev/null || true
  http_get /
  add_row "외부 GET / (원 응답, 비로그인)" "303 → /login" "$HTTP_CODE" "$(verdict "$([ "$HTTP_CODE" = 303 ] && echo 0 || echo 1)" WARN)"
  record "$EVIDENCE" -- curl -sS -L -o /dev/null -w '%{http_code} %{url_effective}\n' --max-time 10 "http://${PUBLIC_IP}/" > /dev/null || true
  http_get / -L
  add_row "외부 GET -L / (방식 A, 로그인 화면)" "200" "$HTTP_CODE" "$(verdict "$([ "$HTTP_CODE" = 200 ] && echo 0 || echo 1)" FAIL)"

  # 3) SSH로 들어가 서버 안쪽을 확인한다(22번이 내 IP에서 열려 있어야 성공)
  ssh_setup
  local ssh_out="" ssh_rc=0
  if ! command -v ssh > /dev/null 2>&1; then
    ssh_out="ssh 명령이 없습니다"
    ssh_rc=255
  elif [ ! -f "$SSH_PEM" ]; then
    ssh_out="개인키 파일이 없습니다: state/$(basename "$SSH_PEM")"
    ssh_rc=255
  else
    ssh_out="$(record "$EVIDENCE" -- ssh "${SSH_OPTS[@]}" "ubuntu@${PUBLIC_IP}" "$REMOTE_CMD")" || ssh_rc=$?
  fi
  # ssh는 접속 자체가 실패하면 255, 접속했으면 원격 명령의 종료 코드를 돌려준다
  if [ "$ssh_rc" -eq 255 ]; then
    add_row "SSH 접속 (22, 내 IP/32)" "접속 성공" "실패 (${ssh_out%%$'\n'*})" FAIL
    local item
    for item in "nginx 서비스 상태" "ai-chatbot 서비스 상태" "인스턴스 안 curl -L http://localhost" \
      "인스턴스 안 curl http://localhost/health" "아웃바운드 curl https://example.com"; do
      add_row "$item" "-" "확인 불가" FAIL
    done
  else
    local line key val
    local r_nginx="" r_app="" r_root="" r_follow="" r_health="" r_out="" r_llm=""
    while IFS= read -r line; do
      line="${line%$'\r'}"
      key="${line%%=*}"
      val="${line#*=}"
      case "$key" in
        nginx) r_nginx="$val" ;;
        app) r_app="$val" ;;
        local_root) r_root="$val" ;;
        local_root_follow) r_follow="$val" ;;
        local_health) r_health="$val" ;;
        outbound) r_out="$val" ;;
        llm) r_llm="$val" ;;
      esac
    done <<< "$ssh_out"
    local h_code="${r_health##* }" h_body="${r_health% *}"
    add_row "SSH 접속 (22, 내 IP/32)" "접속 성공" "접속 성공" PASS
    add_row "nginx 서비스 상태" "active" "${r_nginx:-없음}" "$(verdict "$([ "$r_nginx" = active ] && echo 0 || echo 1)" FAIL)"
    add_row "ai-chatbot 서비스 상태" "active" "${r_app:-없음}" "$(verdict "$([ "$r_app" = active ] && echo 0 || echo 1)" FAIL)"
    add_row "인스턴스 안 curl http://localhost (원 응답)" "303 → /login" "${r_root:-없음}" "$(verdict "$([ "$r_root" = 303 ] && echo 0 || echo 1)" WARN)"
    add_row "인스턴스 안 curl -L http://localhost" "200" "${r_follow:-없음}" "$(verdict "$([ "$r_follow" = 200 ] && echo 0 || echo 1)" FAIL)"
    ok=1
    if [ "$h_code" = 200 ] && is_health_ok "$h_body"; then ok=0; fi
    add_row "인스턴스 안 curl http://localhost/health" "200 + $HEALTH_OK" "${h_code:-없음} + ${h_body:-빈 본문}" "$(verdict "$ok" FAIL)"
    add_row "아웃바운드 curl https://example.com" "200" "${r_out:-없음}" "$(verdict "$([ "$r_out" = 200 ] && echo 0 || echo 1)" FAIL)"
    # 키 없이 부르므로 401 등이 정상이다. 000(연결 실패)일 때만 도달 불가. 미션 필수가 아니라 WARN만 남긴다
    add_row "LLM API 도달성 (copa.codyssey.kr, 키 없이 호출)" "HTTP 응답 있음(000 아님)" "${r_llm:-000}" \
      "$(verdict "$([ -n "$r_llm" ] && [ "$r_llm" != 000 ] && echo 0 || echo 1)" WARN)"
  fi

  local total="${#ROWS[@]}" summary
  if [ "$FAILS" -eq 0 ]; then
    summary="종합: ${total}개 항목 중 PASS $((total - WARNS)) · WARN ${WARNS} — 외부 접속 확인(방식 B) http://${PUBLIC_IP}/health"
  else
    summary="종합: ${FAILS}개 항목 실패(WARN ${WARNS}) — 점검 순서는 docs/troubleshooting.md (라우팅 → SG → 퍼블릭 IP → 프로세스·로그, 502면 ai-chatbot 서비스)"
  fi
  {
    echo ""
    echo "| 항목 | 기대 | 실제 | 결과 |"
    echo "|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
    echo ""
    echo "$summary"
  } | mask_stream | tee -a "$EVIDENCE_DIR/$EVIDENCE"
  if [ "$WARNS" -gt 0 ]; then
    warn "WARN ${WARNS}개: 미션 필수 항목은 아니다. LLM API가 000이면 채팅만 안 될 수 있다(인스턴스 아웃바운드·DNS 확인)."
  fi
  log "검증 기록: evidence/aws/$EVIDENCE"
  [ "$FAILS" -eq 0 ]
}

main "$@"
