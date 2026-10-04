#!/bin/bash
# B3-1 EC2 user-data — 첫 부팅 때 cloud-init이 root로 한 번 실행한다.
# 실행 기록은 EC2의 /var/log/cloud-init-output.log 에 남는다(set -x로 각 명령이 찍힌다).
# 로컬 리허설(local/rehearsal.sh)도 이 파일을 그대로 컨테이너에서 실행한다.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

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
"${APT[@]}" install -y nginx curl

# 정적 페이지 (방식 A 확인용)
SERVER_HOST="$(hostname)"
DEPLOYED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"
cat > /var/www/html/index.html <<EOF
<!doctype html>
<html lang="ko">
<head><meta charset="utf-8"><title>Hello Cloud — Codyssey B3-1</title></head>
<body>
  <h1>Hello Cloud — Codyssey B3-1</h1>
  <p>host: ${SERVER_HOST}</p>
  <p>deployed at: ${DEPLOYED_AT}</p>
  <p>health check: <a href="/health">/health</a></p>
</body>
</html>
EOF

# 사이트 설정 — /health는 파일 없이 Nginx가 고정 응답을 돌려준다 (방식 B 검증 대상)
cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    location = /health { default_type text/plain; return 200 "OK\n"; }
    location / { try_files $uri $uri/ =404; }
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
