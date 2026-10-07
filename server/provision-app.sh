#!/bin/bash
# B3-1 앱 설치 — deploy.sh가 scp로 올린 뒤 SSH로 실행한다:  sudo bash provision-app.sh <업로드 폴더> [커밋]
#   업로드 폴더: app.tar.gz(ai_chatbot의 git archive), app.env(ai_chatbot의 .env), 이 스크립트
# 하는 일: 소스 교체(.venv·.env·app.db 유지) → venv·pip 설치 → .env 보정(600, DATABASE_URL 절대 경로,
#          SECRET_KEY가 비었거나 16자 미만이면 새로 생성) → systemd ai-chatbot.service(uvicorn 127.0.0.1:8000) 등록·재시작
#          → 서버 안 /health 대기
# 비밀값은 출력하지 않는다(set -x 금지, .env 항목은 "있음/비어 있음"만). 여러 번 실행해도 안전하다.
# 로컬 리허설(local/rehearsal.sh)도 같은 파일을 컨테이너에서 실행한다(systemd가 없으면 같은 명령을 백그라운드로 띄운다).
set -Eeuo pipefail

UPLOAD_DIR="${1:?사용법: sudo bash provision-app.sh <업로드 폴더> [커밋]}"
COMMIT="${2:-알 수 없음}"
APP_USER="ubuntu"
APP_HOME="/home/ubuntu"
APP_DIR="/home/ubuntu/ai_chatbot"
DB_URL="sqlite:////home/ubuntu/ai_chatbot/app.db"
SERVICE="ai-chatbot"
UNIT_FILE="/etc/systemd/system/ai-chatbot.service"
HEALTH_URL="http://127.0.0.1:8000/health"
HEALTH_OK='{"status":"ok"}'
HEALTH_TRIES="${PROVISION_HEALTH_TRIES:-60}"
PIDFILE="/run/ai-chatbot.pid"
LOGFILE="/var/log/ai-chatbot.log"
# 앱은 서버 안(127.0.0.1)에서만 받는다. 바깥 요청은 Nginx(80)가 넘겨준다. SQLite라 워커는 1개
EXEC=("$APP_DIR/.venv/bin/uvicorn" app.main:app --host 127.0.0.1 --port 8000 --workers 1)

log() { printf '[provision] %s\n' "$*"; }
fail() {
  printf '[provision][ERROR] %s\n' "$*" >&2
  exit 1
}
trap 'fail "예상하지 못한 오류(줄 $LINENO): $BASH_COMMAND"' ERR

# 앱 사용자 권한으로 실행한다(setpriv는 exec만 하므로 백그라운드 PID가 곧 uvicorn PID다)
as_app() {
  setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups \
    env HOME="$APP_HOME" USER="$APP_USER" LOGNAME="$APP_USER" PATH=/usr/local/bin:/usr/bin:/bin "$@"
}

# 로그를 보여 줄 때 혹시 섞일 수 있는 설정 값(pydantic 검증 오류의 input_value)을 가린다
masked() { sed -E "s/(input_value=)('[^']*'|\"[^\"]*\"|[^ ,]*)/\1***/g"; }

show_app_logs() {
  log "최근 앱 로그(값은 가림):"
  if [ -d /run/systemd/system ]; then
    journalctl -u "$SERVICE" -n 40 --no-pager 2>&1 | masked || true
  else
    tail -n 40 "$LOGFILE" 2>&1 | masked || true
  fi
}

# 업로드한 .env와 소스 묶음은 성공·실패와 관계없이 지운다(앱 폴더에는 600 권한 사본만 남긴다)
trap 'rm -f "$UPLOAD_DIR/app.env" "$UPLOAD_DIR/app.tar.gz" "$UPLOAD_DIR/provision-app.sh"; rmdir "$UPLOAD_DIR" 2> /dev/null || true' EXIT
[ "$(id -u)" -eq 0 ] || fail "root로 실행해야 합니다(sudo bash provision-app.sh …)."
[ -f "$UPLOAD_DIR/app.tar.gz" ] || fail "$UPLOAD_DIR/app.tar.gz 가 없습니다."
[ -f "$UPLOAD_DIR/app.env" ] || fail "$UPLOAD_DIR/app.env 가 없습니다."
id "$APP_USER" > /dev/null 2>&1 || fail "사용자 $APP_USER 가 없습니다."
command -v python3 > /dev/null 2>&1 || fail "python3가 없습니다(user-data가 끝났는지 확인)."

log "배포 커밋: $COMMIT"

# 1) 소스 교체 — 이전 커밋에서 지워진 파일이 남지 않게 비우고 푼다. venv·.env·SQLite DB는 남긴다
install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$APP_DIR"
find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name .venv ! -name .env ! -name 'app.db*' -exec rm -rf {} +
tar -xzf "$UPLOAD_DIR/app.tar.gz" -C "$APP_DIR" --no-same-owner
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
[ -f "$APP_DIR/app/main.py" ] && [ -f "$APP_DIR/requirements.txt" ] || fail "소스에 app/main.py·requirements.txt가 없습니다."
cd "$APP_DIR"
log "소스 배치: $APP_DIR ($(find "$APP_DIR" -path "$APP_DIR/.venv" -prune -o -type f -print | wc -l)개 파일)"

# 2) 가상환경과 의존성 — 있으면 재사용한다. PyPI 일시 오류에 대비해 3번까지 시도한다
if [ -x "$APP_DIR/.venv/bin/python" ]; then
  log "venv 재사용: $APP_DIR/.venv ($("$APP_DIR/.venv/bin/python" --version 2>&1))"
else
  as_app python3 -m venv "$APP_DIR/.venv"
  log "venv 생성: $APP_DIR/.venv ($("$APP_DIR/.venv/bin/python" --version 2>&1))"
fi
for attempt in 1 2 3; do
  if as_app "$APP_DIR/.venv/bin/pip" install --disable-pip-version-check --no-input --progress-bar off -q \
    -r "$APP_DIR/requirements.txt"; then
    break
  fi
  [ "$attempt" -lt 3 ] || fail "pip install이 3번 모두 실패했습니다(네트워크·PyPI 확인)."
  log "pip install 실패 — 10초 뒤 다시 시도합니다(${attempt}/3)"
  sleep 10
done
log "의존성 설치 완료: $(as_app "$APP_DIR/.venv/bin/pip" freeze --disable-pip-version-check 2> /dev/null |
  grep -iE '^(fastapi|uvicorn|sqlalchemy|pydantic-settings)==' | paste -sd ' ' - || true)"

# 3) .env — 서버 경로에 맞게 고치고 소유자만 읽게(600) 둔다. 앱과 같은 파서(python-dotenv)로 읽는다.
#    DATABASE_URL은 절대 경로로, SECRET_KEY가 비었거나 16자 미만이면 secrets.token_hex(32)로 새로 만든다.
#    값은 출력하지 않는다
"$APP_DIR/.venv/bin/python" - "$UPLOAD_DIR/app.env" "$APP_DIR/.env.new" "$DB_URL" << 'PY'
import os
import re
import secrets
import sys

from dotenv import dotenv_values

src, dst, db_url = sys.argv[1:4]
values = dotenv_values(src)
key = values.get("SECRET_KEY") or ""
regenerate = len(key) < 16
drop = re.compile(r"^\s*(export\s+)?(DATABASE_URL" + ("|SECRET_KEY" if regenerate else "") + r")\s*=")
with open(src, encoding="utf-8-sig") as f:
    lines = [line for line in f.read().splitlines() if not drop.match(line)]
lines.append(f"DATABASE_URL={db_url}")
if regenerate:
    lines.append(f"SECRET_KEY={secrets.token_hex(32)}")
fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(dst, 0o600)


def state(name):
    return "있음" if (values.get(name) or "").strip() else "비어 있음"


print("[provision] .env SECRET_KEY: " + ("비어 있거나 16자 미만 → 서버에서 새로 생성(secrets.token_hex(32))" if regenerate else "있음(16자 이상, 그대로 사용)"))
print(f"[provision] .env DATABASE_URL: {db_url}")
print(f"[provision] .env LLM_API_KEY: {state('LLM_API_KEY')}" + ("" if state("LLM_API_KEY") == "있음" else " (채팅만 동작하지 않음)"))
print(f"[provision] .env NAVER_CLIENT_ID·SECRET: {state('NAVER_CLIENT_ID')}·{state('NAVER_CLIENT_SECRET')}")
PY
chown "$APP_USER:$APP_USER" "$APP_DIR/.env.new"
mv -f "$APP_DIR/.env.new" "$APP_DIR/.env"
log ".env 권한: $(stat -c '%a %U:%G' "$APP_DIR/.env")"

# 4) 서비스 — EC2는 systemd(ai-chatbot.service, 죽으면 다시 시작). systemd가 없는 컨테이너는 같은 명령을 백그라운드로
install -d -m 755 "$(dirname "$UNIT_FILE")"
cat > "$UNIT_FILE" << EOF
# B3-1 deploy.sh가 만든 파일(server/provision-app.sh). 앱 코드는 $APP_DIR, 설정은 $APP_DIR/.env(600)
[Unit]
Description=PULSE economy short-form trend chatbot (FastAPI) - B3-1
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/home/ubuntu/ai_chatbot
# 127.0.0.1에만 바인딩한다. 바깥 요청은 Nginx(80)가 넘겨주고, 보안 그룹은 8000을 열지 않는다
ExecStart=${EXEC[*]}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable "$SERVICE" 2>&1
  systemctl restart "$SERVICE"
  log "systemd: $SERVICE enable·restart ($UNIT_FILE)"
else
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2> /dev/null; then
    kill "$(cat "$PIDFILE")"
    for _ in $(seq 1 20); do
      kill -0 "$(cat "$PIDFILE")" 2> /dev/null || break
      sleep 0.5
    done
    log "이전 uvicorn 종료(PID $(cat "$PIDFILE"))"
  fi
  touch "$LOGFILE"
  setsid setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups \
    env HOME="$APP_HOME" USER="$APP_USER" PATH=/usr/local/bin:/usr/bin:/bin "${EXEC[@]}" >> "$LOGFILE" 2>&1 < /dev/null &
  echo "$!" > "$PIDFILE"
  log "systemd 없음(로컬 리허설): 같은 명령을 백그라운드로 실행 — PID $(cat "$PIDFILE"), 로그 $LOGFILE"
fi

# 5) 서버 안에서 앱이 응답할 때까지 기다린다
ok=0
for ((i = 1; i <= HEALTH_TRIES; i++)); do
  body="$(curl -fsS --max-time 3 "$HEALTH_URL" 2> /dev/null || true)"
  if [ "$body" = "$HEALTH_OK" ]; then
    ok=1
    log "로컬 /health 응답: $body (${i}번째 확인)"
    break
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  show_app_logs
  fail "앱이 ${HEALTH_TRIES}초 안에 $HEALTH_URL 에 응답하지 않았습니다. 위 로그를 확인하세요."
fi

# 증거용 요약 — 리슨 주소(8000은 127.0.0.1만), Nginx를 거친 응답 코드
if [ -d /run/systemd/system ]; then
  log "서비스 상태: nginx=$(systemctl is-active nginx || true), $SERVICE=$(systemctl is-active "$SERVICE" || true)"
fi
if command -v ss > /dev/null 2>&1; then
  log "리슨 소켓(:80, :8000):"
  ss -ltn | awk 'NR == 1 || $4 ~ /:(80|8000)$/' || true
fi
log "Nginx 경유: GET /health → $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/health), GET / → $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/) (비로그인 303 → /login), GET -L / → $(curl -sL -o /dev/null -w '%{http_code}' --max-time 10 http://localhost/)"
log "완료: 커밋 $COMMIT, 서비스 $SERVICE (uvicorn 127.0.0.1:8000, Nginx :80 → 프록시)"
