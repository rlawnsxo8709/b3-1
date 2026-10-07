# shellcheck shell=bash
# shellcheck disable=SC2034 # STACK_* 변수는 이 파일을 source 하는 스크립트가 쓴다
# 로컬 리허설 공용 (AWS 아님) — 컨테이너에 EC2와 같은 순서로 서버를 만들 때 쓰는 준비물.
#   server/user-data.sh → (deploy.sh의 scp 대신 docker cp) 앱 소스 git archive + 리허설 전용 가짜 .env
#   → server/provision-app.sh
# 실제 ai_chatbot의 .env는 읽지 않는다. 가짜 .env는 앱의 .env.example에서 만들고 SECRET_KEY만 채운다(LLM·NAVER 키는 비움).
# local/rehearsal.sh·local/repro-port-blocked.sh가 프로젝트 폴더로 cd 한 뒤 source 한다.

STACK_UPLOAD="/home/ubuntu/.b3-1-upload" # 서버(EC2)와 같은 업로드 경로
STACK_APP_SRC=""
STACK_APP_REF=""
STACK_COMMIT=""
STACK_SUBJECT=""

# 배포할 앱 체크아웃: 환경변수 APP_SRC(없으면 이 프로젝트 기준 ../../../ai_chatbot), APP_REF(기본 HEAD)
stack_app_src() {
  STACK_APP_SRC="${APP_SRC:-../../../ai_chatbot}"
  STACK_APP_REF="${APP_REF:-HEAD}"
  if ! STACK_COMMIT="$(git -C "$STACK_APP_SRC" rev-parse --verify --quiet "${STACK_APP_REF}^{commit}")"; then
    echo "[ERROR] 앱 소스를 찾지 못했습니다(APP_SRC=$STACK_APP_SRC, APP_REF=$STACK_APP_REF). APP_SRC=<ai_chatbot 경로>로 실행하세요." >&2
    return 1
  fi
  if ! git -C "$STACK_APP_SRC" cat-file -e "$STACK_COMMIT:app/main.py" 2> /dev/null; then
    echo "[ERROR] APP_REF에 앱 코드가 없습니다. ai_chatbot은 develop 브랜치에 코드가 있습니다(APP_REF=develop)." >&2
    return 1
  fi
  STACK_SUBJECT="$(git -C "$STACK_APP_SRC" log -1 --format=%s "$STACK_COMMIT")"
}

# stack_archive 폴더 : 폴더에 app.tar.gz를 만든다(커밋된 파일만. 추적하지 않는 .env는 들어가지 않는다).
# git -C 아래에서 -o는 앱 폴더 기준 경로가 되므로 표준 출력으로 받는다
stack_archive() {
  git -C "$STACK_APP_SRC" archive --format=tar.gz "$STACK_COMMIT" > "$1/app.tar.gz"
}

# stack_fake_env 폴더 generate|empty : 폴더에 리허설 전용 app.env를 만든다(앱의 .env.example 기준).
#   generate = SECRET_KEY를 여기서 만들어 넣는다 / empty = 비워 두어 서버(provision-app.sh)가 만들게 한다
#   LLM_API_KEY·NAVER 키는 항상 비운다. 값은 파일에만 쓰고 명령줄·화면에 내지 않는다
stack_fake_env() {
  local dir="$1" mode="$2" secret="" line
  if [ "$mode" = generate ]; then
    secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  {
    echo "# 리허설 전용 가짜 .env — 실제 키 없음(LLM·NAVER 비움), AWS 아님"
    git -C "$STACK_APP_SRC" show "$STACK_COMMIT:.env.example" | while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        SECRET_KEY=*) printf 'SECRET_KEY=%s\n' "$secret" ;;
        LLM_API_KEY=* | NAVER_CLIENT_ID=* | NAVER_CLIENT_SECRET=*) printf '%s=\n' "${line%%=*}" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
  } > "$dir/app.env"
  chmod 600 "$dir/app.env"
}
