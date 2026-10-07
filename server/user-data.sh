#!/bin/bash
# B3-1 EC2 user-data — 첫 부팅 때 cloud-init이 root로 한 번 실행한다.
# 실행 기록은 EC2의 /var/log/cloud-init-output.log 에 남는다(set -x로 각 명령이 찍힌다).
# 하는 일: Nginx(80 → 127.0.0.1:8000 프록시)·python3-venv 설치, 앱 폴더 준비, 완료 표식.
# 앱 코드와 비밀값(.env)은 여기에 넣지 않는다. user-data는 인스턴스 메타데이터·콘솔에서 보이므로,
# 앱은 deploy.sh가 SSH로 보내 server/provision-app.sh로 설치한다.
# 로컬 리허설(local/rehearsal.sh)도 이 파일을 그대로 컨테이너에서 실행한다.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

APP_USER=ubuntu
APP_DIR=/home/ubuntu/ai_chatbot
DONE_MARKER=/var/lib/b3-1/user-data.done

# 첫 부팅 직후에는 자동 업데이트가 apt 잠금을 잡고 있을 수 있어 잠금이 풀릴 때까지 기다리고,
# 미러 일시 오류에 대비해 update를 3번까지 시도한다
APT=(apt-get -o DPkg::Lock::Timeout=300)
for attempt in 1 2 3; do
  if "${APT[@]}" update; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    exit 1
  fi
  sleep 10
done
"${APT[@]}" install -y nginx curl python3-venv

# 앱이 돌 폴더(소유 ubuntu). Ubuntu AMI에는 ubuntu 사용자가 있다(없는 환경 대비)
id "$APP_USER" > /dev/null 2>&1 || useradd -m -s /bin/bash "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$APP_DIR"

# 사이트 설정 — 80번으로 받은 요청을 모두 앱(uvicorn, 127.0.0.1:8000)으로 넘긴다. /health도 앱이 답한다.
# 앱 포트 8000은 서버 안(127.0.0.1)에서만 쓰고 보안 그룹에도 열지 않는다.
# LLM 응답이 최대 50초(LLM_TIMEOUT_SECONDS)라 읽기 타임아웃을 90초로 둔다(기본 60초면 504가 날 수 있다)
cat > /etc/nginx/sites-available/default << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 1m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_send_timeout 90s;
        proxy_read_timeout 90s;
    }
}
EOF
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

nginx -t

# EC2는 systemd로 등록해 재부팅 뒤에도 켜지게 하고, systemd가 없는 컨테이너(로컬 리허설)에서는 직접 띄운다
if [ -d /run/systemd/system ]; then
  systemctl enable nginx
  systemctl restart nginx
else
  nginx -s reload 2> /dev/null || nginx
fi

# deploy.sh가 SSH로 이 표식을 확인한 뒤 앱을 올린다(앱 설치 전이라 지금 /health는 502가 정상)
install -d -m 755 "$(dirname "$DONE_MARKER")"
date '+%Y-%m-%d %H:%M:%S %Z' > "$DONE_MARKER"
