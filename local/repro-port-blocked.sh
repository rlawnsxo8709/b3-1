#!/usr/bin/env bash
# 트러블슈팅 재현 (로컬 리허설, AWS 아님) — "서버는 떠 있는데 밖에서 안 들어온다"
# 포트를 게시하지 않은 컨테이너(-p 생략)는 보안 그룹 인바운드 80이 닫힌 EC2와 같은 증상을 보인다.
# 증상 → 가설(프로세스 / 리슨 주소 / 네트워크 경로) → 검증 → 조치 → 결과를 evidence/local/troubleshooting-port.txt에 기록한다.
# 서버는 EC2와 같은 순서(user-data.sh → 앱 소스·리허설 전용 가짜 .env → provision-app.sh)로 만든다(local/stack.sh).
#   REPRO_OUT=<파일> 로 기록 위치를 바꿀 수 있다(보관 중인 증거를 덮어쓰지 않고 다시 돌려 볼 때)
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" # 기록에 개인 절대 경로가 남지 않도록 프로젝트 기준 상대 경로로 실행한다
# shellcheck source=local/stack.sh
source local/stack.sh
NAME="b3-1-repro"
IMAGE="ubuntu:24.04"
HOST_PORT="18080"
OUT="${REPRO_OUT:-evidence/local/troubleshooting-port.txt}"
URL="http://127.0.0.1:${HOST_PORT}/health"
mkdir -p state
TMP="$(mktemp -d state/.repro.XXXXXX)" # state/는 git 제외. 가짜 .env는 여기에만 둔다

remove_container() { docker rm -f "$NAME" > /dev/null 2>&1 || true; }
trap 'remove_container; rm -rf "$TMP"' EXIT

note() { printf '%s\n' "$*" | tee -a "$OUT"; }

run() {
  local rc=0
  printf '\n$ %s\n' "$*" | tee -a "$OUT" >&2
  "$@" 2>&1 | tee -a "$OUT" || rc="${PIPESTATUS[0]}"
  if [ -n "$(tail -c 1 "$OUT")" ]; then printf '\n' >> "$OUT"; fi
  printf '(종료 코드 %s)\n' "$rc" | tee -a "$OUT" >&2
  return "$rc"
}

# user-data 실행과 앱 설치(출력은 rehearsal.txt와 같으므로 마지막 몇 줄만 남긴다), 리허설용 진단 도구(ss) 설치
provision() {
  docker cp server/user-data.sh "$NAME:/tmp/user-data.sh"
  note ""
  note "\$ docker exec $NAME bash /tmp/user-data.sh   # 출력은 마지막 3줄만 발췌"
  docker exec "$NAME" bash /tmp/user-data.sh 2>&1 | tail -n 3 | tee -a "$OUT"
  stack_archive "$TMP"
  stack_fake_env "$TMP" generate
  docker exec "$NAME" install -d -m 700 -o ubuntu -g ubuntu "$STACK_UPLOAD"
  docker cp "$TMP/app.tar.gz" "$NAME:$STACK_UPLOAD/app.tar.gz"
  docker cp server/provision-app.sh "$NAME:$STACK_UPLOAD/provision-app.sh"
  docker cp "$TMP/app.env" "$NAME:$STACK_UPLOAD/app.env"
  note "\$ docker exec $NAME bash $STACK_UPLOAD/provision-app.sh $STACK_UPLOAD ${STACK_COMMIT:0:12}   # 앱 설치(리허설 전용 가짜 .env), 마지막 줄만 발췌"
  docker exec "$NAME" bash "$STACK_UPLOAD/provision-app.sh" "$STACK_UPLOAD" "$STACK_COMMIT" 2>&1 | tail -n 1 | tee -a "$OUT"
  docker exec "$NAME" bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 > /dev/null 2>&1'
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true; }

command -v docker > /dev/null 2>&1 || { echo "[ERROR] docker가 필요합니다." >&2; exit 1; }
stack_app_src
mkdir -p "$(dirname "$OUT")"
{
  echo "# 트러블슈팅 재현 — 로컬 리허설 (AWS 아님)"
  echo "# 상황: 웹 서버는 실행 중인데 바깥(호스트)에서 접속이 안 된다."
  echo "# 대응 관계: 컨테이너 포트 게시(-p) ≈ 보안 그룹 인바운드 규칙, 호스트 curl ≈ 인터넷에서의 접속"
  echo "# 실행 시각: $(date '+%Y-%m-%d %H:%M:%S %z') / Docker $(docker version --format '{{.Server.Version}}')"
} > "$OUT"

remove_container
note ""
note "## 0. 재현 — 포트를 게시하지 않고(-p 생략) 같은 user-data·앱 설치로 서버를 띄운다"
run docker run -d --name "$NAME" "$IMAGE" sleep infinity
provision

note ""
note "## 1. 증상 — 서버 안에서는 200, 바깥에서는 접속 실패"
run docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}\n' http://localhost/health || true
run curl -sS --max-time 5 "$URL" || true
symptom_code="$(http_code "$URL")"
note "판정: 컨테이너 안 200 / 호스트 ${symptom_code} → 서버는 응답하지만 외부 경로가 막혀 있다"

note ""
note "## 2. 가설 검증 — 안쪽부터 하나씩 배제한다"
note "### 가설 1: Nginx 프로세스가 떠 있지 않다"
note "### 가설 2: 127.0.0.1에만 리슨해 외부 인터페이스로 오는 요청을 받지 않는다"
run docker exec "$NAME" ss -tlnp
note "→ nginx가 0.0.0.0:80과 [::]:80에서 LISTEN 중이다. 가설 1·2 기각"
note "### 가설 3: 바깥에서 서버까지 오는 네트워크 경로(포트 게시 = 인바운드 허용)가 없다"
run docker port "$NAME" || true
run docker inspect -f 'PortBindings={{json .HostConfig.PortBindings}}' "$NAME"
container_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")"
run curl -sS --max-time 5 -o /dev/null -w 'container-ip %{http_code}\n' "http://${container_ip}/health" || true
note "→ 게시된 포트가 없다(docker port 빈 출력, PortBindings={}). 컨테이너 IP로 직접 부르면 200이므로 서버는 정상이고 호스트 포트 경로만 없다. 가설 3 채택"

note ""
note "## 3. 조치 — 포트를 게시해 다시 띄운다 (-p 127.0.0.1:${HOST_PORT}:80, SG 인바운드 80 허용에 해당)"
note "# 실행 중인 컨테이너에는 포트 게시를 추가할 수 없어 새로 만든다 (SG는 규칙만 추가하면 즉시 반영된다)"
run docker rm -f "$NAME" > /dev/null
run docker run -d --name "$NAME" -p "127.0.0.1:${HOST_PORT}:80" "$IMAGE" sleep infinity
provision

note ""
note "## 4. 결과"
run docker port "$NAME"
run curl -sS -i --max-time 5 "$URL"
fixed_code="$(http_code "$URL")"
if [ "$fixed_code" = 200 ]; then
  note "판정: 조치 전 호스트 ${symptom_code} → 조치 후 호스트 ${fixed_code}. 해결"
  rc=0
else
  note "판정: 조치 후에도 ${fixed_code}. 미해결"
  rc=1
fi
note "# 컨테이너 $NAME 는 종료 시 자동 삭제된다 (trap)"
exit "$rc"
