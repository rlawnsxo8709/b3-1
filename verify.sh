#!/usr/bin/env bash
# B3-1 외부 접속 검증 — 방식 B(GET /health)가 주 검증이고, 같은 서버의 / 와 SSH 안쪽 점검을 함께 한다.
#   1) 외부 GET http://<퍼블릭IP>/health → 200 + "OK"      2) 외부 GET http://<퍼블릭IP>/ → 200
#   3) SSH(내 IP에서 22) → systemctl is-active nginx / curl http://localhost(200) / curl https://example.com(아웃바운드 200)
# 결과 표를 화면과 evidence/aws/04-verify.txt에 남기고, 하나라도 FAIL이면 종료 코드 1.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/awscli.sh
source "$SCRIPT_DIR/lib/awscli.sh"

WAIT_TRIES="${VERIFY_WAIT_TRIES:-60}"
WAIT_INTERVAL="${VERIFY_WAIT_INTERVAL:-5}"
EVIDENCE="04-verify.txt"
REMOTE_CMD="systemctl is-active nginx; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 http://localhost; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 https://example.com"
PUBLIC_IP=""
HTTP_CODE=""
HTTP_BODY=""
ROWS=()
FAILS=0

usage() {
  cat << 'EOF'
사용법: ./verify.sh [--wait]

  (옵션 없음)  바로 검증한다
  --wait       /health가 200을 돌려줄 때까지 5초 간격으로 최대 60번 기다린 뒤 검증한다
               (user-data가 Nginx를 설치하는 첫 부팅 직후에 사용. deploy.sh가 이 옵션으로 부른다)
EOF
}

# 외부에서 http://<IP><경로>를 호출해 HTTP_CODE와 HTTP_BODY를 채운다. 연결 실패면 코드 000
http_get() {
  local body
  body="$(mktemp)"
  HTTP_CODE="$(curl -sS -o "$body" -w '%{http_code}' --max-time 10 "http://${PUBLIC_IP}$1" 2> /dev/null)" || true
  HTTP_CODE="${HTTP_CODE:-000}"
  HTTP_BODY="$(head -c 2000 "$body" | tr -d '\r')"
  rm -f "$body"
}

# add_row 항목 기대 실제 통과여부(0=통과)
add_row() {
  local verdict="PASS"
  if [ "$4" -ne 0 ]; then
    verdict="FAIL"
    FAILS=$((FAILS + 1))
  fi
  ROWS+=("| $1 | $2 | $3 | $verdict |")
}

wait_for_health() {
  local i
  log "http://${PUBLIC_IP}/health 가 200을 돌려줄 때까지 기다립니다(최대 $((WAIT_TRIES * WAIT_INTERVAL))초). 첫 부팅 때 user-data가 Nginx를 설치하느라 보통 1~3분 걸립니다."
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

  local instance_id key_name pem
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

  evidence_begin "$EVIDENCE" "외부 접속 검증 — 방식 B: GET http://${PUBLIC_IP}/health (200 + OK)"
  evidence_note "$EVIDENCE" "# 대상 인스턴스: $instance_id"

  # 1) 방식 B — 외부에서 /health
  record "$EVIDENCE" -- curl -sS -i --max-time 10 "http://${PUBLIC_IP}/health" > /dev/null || true
  http_get /health
  local body_line="${HTTP_BODY%%$'\n'*}"
  if [ "$HTTP_CODE" = "200" ] && [ "$body_line" = "OK" ]; then
    add_row "외부 GET /health (방식 B)" "200 + OK" "$HTTP_CODE + ${body_line:-빈 본문}" 0
  else
    add_row "외부 GET /health (방식 B)" "200 + OK" "$HTTP_CODE + ${body_line:-빈 본문}" 1
  fi

  # 2) 같은 서버의 / (방식 A 화면)
  record "$EVIDENCE" -- curl -sS -i --max-time 10 "http://${PUBLIC_IP}/" > /dev/null || true
  http_get /
  if [ "$HTTP_CODE" = "200" ]; then
    add_row "외부 GET / (방식 A 페이지)" "200" "$HTTP_CODE" 0
  else
    add_row "외부 GET / (방식 A 페이지)" "200" "$HTTP_CODE" 1
  fi

  # 3) SSH로 들어가 서버 안쪽을 확인한다(22번이 내 IP에서 열려 있어야 성공)
  key_name="$(state_get KEY_NAME)"
  pem="$STATE_DIR/${key_name:-$PROJECT-key}.pem"
  local ssh_out="" ssh_rc=0 lines=()
  if ! command -v ssh > /dev/null 2>&1; then
    ssh_out="ssh 명령이 없습니다"
    ssh_rc=255
  elif [ ! -f "$pem" ]; then
    ssh_out="개인키 파일이 없습니다: state/${key_name:-$PROJECT-key}.pem"
    ssh_rc=255
  else
    ssh_out="$(record "$EVIDENCE" -- ssh -i "$pem" \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
      -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -o LogLevel=ERROR \
      "ubuntu@${PUBLIC_IP}" "$REMOTE_CMD")" || ssh_rc=$?
  fi
  # ssh는 접속 자체가 실패하면 255, 접속했으면 원격 명령의 종료 코드를 돌려준다
  if [ "$ssh_rc" -eq 255 ]; then
    add_row "SSH 접속 (22, 내 IP/32)" "접속 성공" "실패 (${ssh_out%%$'\n'*})" 1
    add_row "nginx 서비스 상태" "active" "확인 불가" 1
    add_row "인스턴스 안 curl http://localhost" "200" "확인 불가" 1
    add_row "아웃바운드 curl https://example.com" "200" "확인 불가" 1
  else
    mapfile -t lines < <(printf '%s\n' "$ssh_out" | tr -d '\r')
    local nginx_state="${lines[0]:-}" local_code="${lines[1]:-}" out_code="${lines[2]:-}"
    add_row "SSH 접속 (22, 내 IP/32)" "접속 성공" "접속 성공" 0
    if [ "$nginx_state" = "active" ]; then
      add_row "nginx 서비스 상태" "active" "$nginx_state" 0
    else
      add_row "nginx 서비스 상태" "active" "${nginx_state:-없음}" 1
    fi
    if [ "$local_code" = "200" ]; then
      add_row "인스턴스 안 curl http://localhost" "200" "$local_code" 0
    else
      add_row "인스턴스 안 curl http://localhost" "200" "${local_code:-없음}" 1
    fi
    if [ "$out_code" = "200" ]; then
      add_row "아웃바운드 curl https://example.com" "200" "$out_code" 0
    else
      add_row "아웃바운드 curl https://example.com" "200" "${out_code:-없음}" 1
    fi
  fi

  local total="${#ROWS[@]}" summary
  if [ "$FAILS" -eq 0 ]; then
    summary="종합: ${total}/${total} 통과 — 외부 접속 확인(방식 B) http://${PUBLIC_IP}/health"
  else
    summary="종합: ${FAILS}개 항목 실패 — 점검 순서는 docs/troubleshooting.md (라우팅 → SG → 퍼블릭 IP → 프로세스·로그)"
  fi
  {
    echo ""
    echo "| 항목 | 기대 | 실제 | 결과 |"
    echo "|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
    echo ""
    echo "$summary"
  } | tee -a "$EVIDENCE_DIR/$EVIDENCE"
  log "검증 기록: evidence/aws/$EVIDENCE"
  [ "$FAILS" -eq 0 ]
}

main "$@"
