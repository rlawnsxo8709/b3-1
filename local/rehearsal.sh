#!/usr/bin/env bash
# 로컬 리허설 — ubuntu:24.04 컨테이너에서 server/user-data.sh를 "그대로" 실행하고
# 컨테이너 안(=EC2 안의 curl localhost)과 호스트(=외부 접속)에서 /, /health를 검증한다.
# AWS가 아니다. VPC·보안 그룹·IAM은 검증하지 않으며 결과는 evidence/local/rehearsal.txt에 남는다.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="b3-1-rehearsal"
IMAGE="ubuntu:24.04"
HOST_PORT="18080"
OUT_DIR="evidence/local"
OUT="$OUT_DIR/rehearsal.txt"
FAILED=0
cd "$ROOT_DIR" # 기록에 개인 절대 경로가 남지 않도록 프로젝트 기준 상대 경로로 실행한다

remove_container() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap remove_container EXIT

note() { printf '%s\n' "$*" | tee -a "$OUT"; }

# "$ 명령" 머리말은 화면(stderr)과 파일에, 명령 출력은 stdout과 파일에 남긴다.
# 그래서 x="$(run ...)"으로 출력만 받아 판정에 쓸 수 있다
run() {
  local rc=0
  printf '\n$ %s\n' "$*" | tee -a "$OUT" >&2
  "$@" 2>&1 | tee -a "$OUT" || rc="${PIPESTATUS[0]}"
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

command -v docker > /dev/null 2>&1 || { echo "[ERROR] docker가 필요합니다." >&2; exit 1; }
mkdir -p "$OUT_DIR"
{
  echo "# 로컬 리허설 (AWS 아님)"
  echo "# server/user-data.sh를 $IMAGE 컨테이너에서 그대로 실행해 Nginx 설정과 /, /health 응답을 확인한다."
  echo "# EC2·VPC·보안 그룹·IAM은 이 리허설의 검증 대상이 아니다. AWS 실행 결과는 evidence/aws/에 따로 남는다."
  echo "# 컨테이너 포트 80 → 호스트 127.0.0.1:$HOST_PORT (호스트 curl = '외부에서 접속'에 해당)"
  echo "# 실행 시각: $(date '+%Y-%m-%d %H:%M:%S %z') / 호스트: $(uname -sm) / Docker $(docker version --format '{{.Server.Version}}')"
} > "$OUT"

remove_container
note ""
note "## 1. 컨테이너 기동과 user-data 실행"
run docker run -d --name "$NAME" -p "127.0.0.1:${HOST_PORT}:80" "$IMAGE" sleep infinity
run docker cp server/user-data.sh "$NAME:/tmp/user-data.sh"
run docker exec "$NAME" bash /tmp/user-data.sh

note ""
note "## 2. 컨테이너 안에서 확인 (EC2 안에서 curl localhost 에 해당)"
in_root="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/)"
in_health_code="$(run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' http://localhost/health)"
in_health_body="$(run docker exec "$NAME" curl -s http://localhost/health)"
run docker exec "$NAME" curl -s -i http://localhost/health > /dev/null
check "컨테이너 안 GET /" "200" "$in_root"
check "컨테이너 안 GET /health 코드" "200" "$in_health_code"
check "컨테이너 안 GET /health 본문" "OK" "$(printf '%s' "$in_health_body" | tr -d '\r\n')"

note ""
note "## 3. 호스트에서 확인 (외부 접속 경로에 해당)"
host_health_code="$(run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/health")"
run curl -sS -i "http://127.0.0.1:${HOST_PORT}/health" > /dev/null
host_root="$(run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HOST_PORT}/")"
run curl -sS "http://127.0.0.1:${HOST_PORT}/" > /dev/null
check "호스트 GET /health 코드" "200" "$host_health_code"
check "호스트 GET / 코드" "200" "$host_root"

note ""
note "## 4. 리슨 소켓과 적용된 Nginx 설정"
# ss는 리허설 전용 진단 도구다. EC2의 Ubuntu 이미지에는 기본으로 있어 user-data에는 넣지 않았다
docker exec "$NAME" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 > /dev/null 2>&1'
run docker exec "$NAME" ss -tlnp
run docker exec "$NAME" bash -c "nginx -T 2>/dev/null | awk '/# configuration file \/etc\/nginx\/sites-enabled\/default/{f=1} /# configuration file/{if(\$0 !~ /sites-enabled\/default/) f=0} f'"

note ""
if [ "$FAILED" -eq 0 ]; then
  note "리허설 결과: 전체 통과 — 컨테이너 안 / 200, /health 200 OK, 호스트 /health 200, 호스트 / 200"
else
  note "리허설 결과: 실패 항목 있음 — 위 [FAIL] 줄을 확인"
fi
note "# 컨테이너 $NAME 는 종료 시 자동 삭제된다 (trap)"
exit "$FAILED"
