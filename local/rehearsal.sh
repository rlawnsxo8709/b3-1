#!/usr/bin/env bash
# 로컬 리허설 — ubuntu:24.04 컨테이너에서 EC2와 같은 순서로 서버를 만들고 응답을 검증한다.
#   1) server/user-data.sh를 "그대로" 실행(Nginx 프록시·python3-venv)
#   2) 앱 소스(로컬 ai_chatbot의 git archive) + 리허설 전용 가짜 .env를 docker cp(= deploy.sh의 scp)
#   3) server/provision-app.sh를 "그대로" 실행(systemd가 없으므로 uvicorn을 백그라운드로)
#   4) 컨테이너 안(= EC2 안의 curl localhost)과 호스트(= 외부 접속)에서 /health·/·/signup, 가입·로그인·채팅 확인
#   5) 같은 provision-app.sh를 한 번 더 실행해 재실행 안전성 확인
# AWS가 아니다. VPC·보안 그룹·IAM·SSH·systemd는 검증하지 않으며 결과는 evidence/local/rehearsal.txt에 남는다.
# 실제 ai_chatbot/.env는 읽지 않는다(가짜 .env는 SECRET_KEY만 만들고 LLM·NAVER 키는 비운다).
#   APP_SRC=<ai_chatbot 경로> APP_REF=<브랜치> bash local/rehearsal.sh   # 기본: ../../../ai_chatbot, HEAD
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="b3-1-rehearsal"
IMAGE="ubuntu:24.04"
HOST_PORT="18080"
BASE="http://127.0.0.1:${HOST_PORT}"
OUT_DIR="evidence/local"
OUT="$OUT_DIR/rehearsal.txt"
FAILED=0
cd "$ROOT_DIR" # 기록에 개인 절대 경로가 남지 않도록 프로젝트 기준 상대 경로로 실행한다
# shellcheck source=local/stack.sh
source local/stack.sh

mkdir -p state
TMP="$(mktemp -d state/.rehearsal.XXXXXX)" # state/는 git 제외. 가짜 .env·쿠키도 여기에만 둔다
remove_container() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap 'remove_container; rm -rf "$TMP"' EXIT

note() { printf '%s\n' "$*" | tee -a "$OUT"; }

# "$ 명령" 머리말은 화면(stderr)과 파일에, 명령 출력은 stdout과 파일에 남긴다.
# 그래서 x="$(run ...)"으로 출력만 받아 판정에 쓸 수 있다
run() {
  local rc=0
  printf '\n$ %s\n' "$*" | tee -a "$OUT" >&2
  "$@" 2>&1 | tee -a "$OUT" || rc="${PIPESTATUS[0]}"
  # curl -w '%{http_code}'처럼 줄바꿈 없이 끝난 출력 뒤에 판정 줄이 붙지 않게 한다
  if [ -n "$(tail -c 1 "$OUT")" ]; then printf '\n' >> "$OUT"; fi
  return "$rc"
}

check() {
  if [ "$2" = "$3" ]; then
    note "[PASS] $1 — 기대: $2 / 실제: $3"
  else
    note "[FAIL] $1 — 기대: $2 / 실제: ${3:-없음}"
    FAILED=1
  fi
}

# check_has 이름 찾을문자열 실제출력 [없어야하면 not]
check_has() {
  local found=1
  [[ "$3" == *"$2"* ]] || found=0
  if [ "${4:-}" = not ]; then found=$((1 - found)); fi
  if [ "$found" = 1 ]; then
    note "[PASS] $1"
  else
    note "[FAIL] $1"
    FAILED=1
  fi
}

code() { tr -d '\r\n' <<< "$1"; }

# 업로드 폴더를 만들고 세 파일을 넣는다(EC2에서는 deploy.sh가 scp로 한다)
upload() {
  run docker exec "$NAME" install -d -m 700 -o ubuntu -g ubuntu "$STACK_UPLOAD"
  run docker cp "$TMP/app.tar.gz" "$NAME:$STACK_UPLOAD/app.tar.gz"
  run docker cp server/provision-app.sh "$NAME:$STACK_UPLOAD/provision-app.sh"
  run docker cp "$TMP/app.env" "$NAME:$STACK_UPLOAD/app.env"
}

command -v docker > /dev/null 2>&1 || { echo "[ERROR] docker가 필요합니다." >&2; exit 1; }
stack_app_src
mkdir -p "$OUT_DIR"
{
  echo "# 로컬 리허설 (AWS 아님)"
  echo "# EC2와 같은 순서로 $IMAGE 컨테이너에 서버를 만든다: server/user-data.sh → 앱 소스·가짜 .env 전송 → server/provision-app.sh"
  echo "# EC2·VPC·보안 그룹·IAM·SSH·systemd는 이 리허설의 검증 대상이 아니다. AWS 실행 결과는 evidence/aws/에 따로 남는다."
  echo "# 실제 ai_chatbot/.env는 쓰지 않는다. 가짜 .env는 SECRET_KEY만 만들고 LLM_API_KEY·NAVER 키는 비운다(채팅은 502가 정상)."
  echo "# 컨테이너 포트 80 → 호스트 127.0.0.1:$HOST_PORT (호스트 curl = '외부에서 접속'에 해당). 앱 포트 8000은 게시하지 않는다."
  echo "# 앱: APP_SRC=$STACK_APP_SRC, APP_REF=$STACK_APP_REF → 커밋 $STACK_COMMIT ($STACK_SUBJECT)"
  echo "# 실행 시각: $(date '+%Y-%m-%d %H:%M:%S %z') / 호스트: $(uname -sm) / Docker $(docker version --format '{{.Server.Version}}')"
} > "$OUT"

remove_container
note ""
note "## 1. 컨테이너 기동과 user-data 실행 (EC2 첫 부팅에 해당)"
run docker run -d --name "$NAME" -p "127.0.0.1:${HOST_PORT}:80" "$IMAGE" sleep infinity
run docker cp server/user-data.sh "$NAME:/tmp/user-data.sh"
run docker exec "$NAME" bash /tmp/user-data.sh
marker="$(run docker exec "$NAME" cat /var/lib/b3-1/user-data.done)" || true
check_has "user-data 완료 표식(/var/lib/b3-1/user-data.done)" "20" "$marker"
before="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/health)" || true
check "앱 설치 전 Nginx 경유 /health (Nginx는 떴고 앱은 아직 없음)" "502" "$(code "$before")"

note ""
note "## 2. 앱 소스와 리허설 전용 가짜 .env 전송 (EC2에서는 deploy.sh가 SSH로 scp)"
note ""
note "\$ git -C $STACK_APP_SRC archive --format=tar.gz $STACK_COMMIT > $TMP/app.tar.gz"
stack_archive "$TMP"
listing="$(tar -tzf "$TMP/app.tar.gz")"
note "# 압축 파일: $(wc -l <<< "$listing" | tr -d ' ')개 항목, $(wc -c < "$TMP/app.tar.gz" | tr -d ' ') bytes"
check "압축 파일에 추적하지 않는 .env가 없음(git archive)" "0" "$(grep -c '\(^\|/\)\.env$' <<< "$listing" || true)"
stack_fake_env "$TMP" generate
note "# 가짜 .env 항목(값은 표시하지 않음): $(sed -E -n 's/^([A-Z_]+)=(.*)$/\1/p' "$TMP/app.env" | tr '\n' ' ')"
note "# SECRET_KEY 길이: $(sed -n 's/^SECRET_KEY=//p' "$TMP/app.env" | tr -d '\n' | wc -c) / LLM_API_KEY 길이: $(sed -n 's/^LLM_API_KEY=//p' "$TMP/app.env" | tr -d '\n' | wc -c)"
upload

note ""
note "## 3. 앱 설치 — deploy.sh가 SSH로 실행하는 것과 같은 server/provision-app.sh"
run docker exec "$NAME" bash "$STACK_UPLOAD/provision-app.sh" "$STACK_UPLOAD" "$STACK_COMMIT"

note ""
note "## 4. 컨테이너 안에서 확인 (EC2 안에서 curl localhost 에 해당)"
in_health="$(run docker exec "$NAME" curl -s -i http://localhost/health)" || true
in_health_code="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/health)" || true
in_root="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/)" || true
in_follow="$(run docker exec "$NAME" curl -sL -o /dev/null -w '%{http_code} %{url_effective}' http://localhost/)" || true
in_signup="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/signup)" || true
check "컨테이너 안 GET /health 코드" "200" "$(code "$in_health_code")"
check_has '컨테이너 안 GET /health 본문 {"status":"ok"}' '{"status":"ok"}' "$in_health"
check "컨테이너 안 GET / 원 응답(비로그인 → /login)" "303" "$(code "$in_root")"
check "컨테이너 안 GET -L / (로그인 화면)" "200 http://localhost/login" "$(code "$in_follow")"
check "컨테이너 안 GET /signup" "200" "$(code "$in_signup")"
sockets="$(run docker exec "$NAME" ss -ltnp)" || true
check_has "uvicorn은 127.0.0.1:8000에만 리슨" "127.0.0.1:8000" "$sockets"
check_has "8000을 모든 인터페이스(0.0.0.0:8000)에 열지 않음" "0.0.0.0:8000" "$sockets" not
check_has "Nginx는 0.0.0.0:80에 리슨" "0.0.0.0:80" "$sockets"
envmode="$(run docker exec "$NAME" stat -c '%a %U:%G' /home/ubuntu/ai_chatbot/.env)" || true
check "서버 .env 권한" "600 ubuntu:ubuntu" "$(code "$envmode")"
dburl="$(run docker exec "$NAME" grep '^DATABASE_URL=' /home/ubuntu/ai_chatbot/.env)" || true
check "서버 .env DATABASE_URL(절대 경로)" "DATABASE_URL=sqlite:////home/ubuntu/ai_chatbot/app.db" "$(code "$dburl")"
leftover="$(run docker exec "$NAME" bash -c 'ls -A /home/ubuntu/.b3-1-upload 2>&1 || true')" || true
check_has "업로드한 .env·소스 묶음은 설치 후 삭제" "No such file or directory" "$leftover"

note ""
note "## 5. 호스트에서 확인 (외부 접속 경로에 해당)"
run curl -sS -i "$BASE/health" > /dev/null || true
host_health="$(run curl -s "$BASE/health")" || true
host_health_code="$(run curl -s -o /dev/null -w '%{http_code}' "$BASE/health")" || true
host_root="$(run curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/")" || true
host_follow="$(run curl -sL -o /dev/null -w '%{http_code}' "$BASE/")" || true
host_signup="$(run curl -s -o /dev/null -w '%{http_code}' "$BASE/signup")" || true
check "호스트 GET /health 코드" "200" "$(code "$host_health_code")"
check "호스트 GET /health 본문" '{"status":"ok"}' "$(code "$host_health")"
check "호스트 GET / 원 응답(비로그인 → /login)" "303 $BASE/login" "$(code "$host_root")"
check "호스트 GET -L / (로그인 화면, 방식 A)" "200" "$(code "$host_follow")"
check "호스트 GET /signup" "200" "$(code "$host_signup")"

note ""
note "## 6. 앱 동작 — 테스트 계정으로 가입 → 로그인 → 채팅 화면 → 질문(LLM 키를 비웠으므로 502가 정상) → 내 기록"
JAR="$TMP/cookies.txt"
ACCOUNT='{"email":"rehearsal@example.com","password":"rehearsal-pass-2026"}'
signup="$(run curl -s -w ' %{http_code}' -H 'Content-Type: application/json' -d "$ACCOUNT" "$BASE/api/auth/signup")" || true
login="$(run curl -s -w ' %{http_code}' -c "$JAR" -H 'Content-Type: application/json' -d "$ACCOUNT" "$BASE/api/auth/login")" || true
chat_page="$(run curl -s -o /dev/null -w '%{http_code}' -b "$JAR" "$BASE/")" || true
chat="$(run curl -s -w ' %{http_code}' -b "$JAR" -H 'Content-Type: application/json' -d '{"mode":"free","message":"리허설 질문입니다"}' "$BASE/api/chat")" || true
history="$(run curl -s -w ' %{http_code}' -b "$JAR" "$BASE/api/me/chats?limit=5")" || true
dbfile="$(run docker exec "$NAME" ls -l /home/ubuntu/ai_chatbot/app.db)" || true
check "회원가입 POST /api/auth/signup" "201" "${signup##* }"
check "로그인 POST /api/auth/login" "200" "${login##* }"
check "로그인 후 GET / (채팅 화면)" "200" "$(code "$chat_page")"
check "질문 POST /api/chat — LLM_API_KEY 비움 → AI_ERROR" "502" "${chat##* }"
check_has "질문 실패 응답 코드 AI_ERROR" "AI_ERROR" "$chat"
check "내 기록 GET /api/me/chats" "200" "${history##* }"
check_has "실패한 질문도 기록됨(status error)" '"status":"error"' "$history"
check_has "SQLite 파일이 DATABASE_URL 위치에 생성됨" "/home/ubuntu/ai_chatbot/app.db" "$dbfile"

note ""
note "## 7. 재실행 안전성 — 같은 provision-app.sh를 한 번 더(이번 가짜 .env는 SECRET_KEY를 비워 서버가 만들게 한다)"
stack_fake_env "$TMP" empty
note "# 가짜 .env SECRET_KEY 길이: $(sed -n 's/^SECRET_KEY=//p' "$TMP/app.env" | tr -d '\n' | wc -c) (비움)"
upload
run docker exec "$NAME" bash "$STACK_UPLOAD/provision-app.sh" "$STACK_UPLOAD" "$STACK_COMMIT"
keylen="$(run docker exec "$NAME" bash -c "sed -n 's/^SECRET_KEY=//p' /home/ubuntu/ai_chatbot/.env | tr -d '\n' | wc -c")" || true
again_health="$(run curl -s -o /dev/null -w '%{http_code}' "$BASE/health")" || true
relogin="$(run curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$ACCOUNT" "$BASE/api/auth/login")" || true
check "서버가 만든 SECRET_KEY 길이(secrets.token_hex(32), 값은 표시 안 함)" "64" "$(code "$keylen")"
check "재설치 후 호스트 GET /health" "200" "$(code "$again_health")"
check "재설치 후 같은 계정 로그인(SQLite 데이터 유지)" "200" "$(code "$relogin")"

note ""
note "## 8. 적용된 Nginx 사이트 설정과 서비스 파일"
run docker exec "$NAME" bash -c "nginx -T 2>/dev/null | awk '/# configuration file \/etc\/nginx\/sites-enabled\/default/{f=1} /# configuration file/{if(\$0 !~ /sites-enabled\/default/) f=0} f'"
run docker exec "$NAME" cat /etc/systemd/system/ai-chatbot.service

note ""
if [ "$FAILED" -eq 0 ]; then
  note "리허설 결과: 전체 통과 — Nginx 경유 /health 200 {\"status\":\"ok\"}, / 303 → -L 200(로그인 화면), /signup 200, 가입·로그인 동작, uvicorn 127.0.0.1:8000만 리슨"
else
  note "리허설 결과: 실패 항목 있음 — 위 [FAIL] 줄을 확인"
fi
note "# 컨테이너 $NAME 와 가짜 .env는 종료 시 자동 삭제된다 (trap)"
exit "$FAILED"
