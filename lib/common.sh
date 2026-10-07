# shellcheck shell=bash
# B3-1 공통 함수 — deploy.sh·verify.sh·cleanup.sh가 source 한다.
# .env 로드, 로그, 상태 파일(state/resources.env), 증거 기록(evidence/aws), 태그, 사전 점검,
# 배포할 앱(ai_chatbot) 소스 확인, SSH 옵션을 모은다.

# mapfile 등 bash 4 기능을 쓴다. macOS 기본 bash(3.2)로 배포만 되고 정리가 막히는 일을 아무것도 하기 전에 막는다
check_bash_version() {
  local major="${1:-${BASH_VERSINFO[0]}}"
  if [ "$major" -lt 4 ]; then
    printf '[ERROR] bash 4 이상이 필요합니다(현재 bash %s). macOS라면 "brew install bash" 후 "bash ./deploy.sh"처럼 새 bash로 실행하세요.\n' "$major" >&2
    return 1
  fi
}
check_bash_version || exit 1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/state"
STATE_FILE="$STATE_DIR/resources.env"
EVIDENCE_DIR="$ROOT_DIR/evidence/aws"
REQUIRED_REGION="ap-northeast-2"
ACCOUNT_ID=""
CALLER_ARN=""
MY_IP_SOURCE=""

# .env에서 받아들이는 키. 그 밖의 키(PATH 등)는 무시해 실수로 실행 환경을 망가뜨리지 않게 한다
ENV_KEYS=" AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION MY_IP INSTANCE_TYPE AZ PROJECT APP_SRC APP_ENV_FILE APP_REF "

log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------ .env

# 값 하나를 정리한다: 따옴표 벗기기, 공백 뒤 '# 주석' 제거, 양끝 공백 제거
env_value() {
  local v="$1"
  local dq='^"([^"]*)"[[:space:]]*(#.*)?$'
  local sq="^'([^']*)'[[:space:]]*(#.*)?\$"
  if [[ "$v" =~ $dq ]] || [[ "$v" =~ $sq ]]; then
    v="${BASH_REMATCH[1]}"
  elif [[ "$v" == \#* ]]; then
    v="" # 'MY_IP=   # 비우면 자동 감지'처럼 값 없이 주석만 있는 줄
  else
    v="${v%%[[:space:]]#*}"
    v="${v%"${v##*[![:space:]]}"}"
  fi
  printf '%s' "$v"
}

# ROOT_DIR/.env를 읽어 환경변수로 내보낸다. CRLF·따옴표·줄 끝 주석을 허용한다.
# 키가 비어 있으면 AWS를 부르기 전에 무엇을 채워야 하는지 알려 주고 종료한다.
load_env() {
  local env_file="$ROOT_DIR/.env" line key val n=0 shell_my_ip="${MY_IP:-}" env_my_ip=""
  if [ ! -f "$env_file" ]; then
    die ".env 파일이 없습니다. 먼저 'cp .env.example .env'를 실행하고 AWS_ACCESS_KEY_ID와 AWS_SECRET_ACCESS_KEY를 채우세요."
  fi
  # 자격 증명은 .env에서만 받는다. 셸에 남은 다른 계정(또는 루트) 키·임시 토큰이 조용히 쓰이거나 섞이지 않게 한다
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
      continue
    fi
    if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      warn ".env ${n}번째 줄은 KEY=VALUE 형식이 아니어서 건너뜁니다."
      continue
    fi
    key="${BASH_REMATCH[2]}"
    val="$(env_value "${BASH_REMATCH[3]}")"
    if [[ "$ENV_KEYS" != *" $key "* ]]; then
      warn ".env의 알 수 없는 키를 무시합니다: $key"
      continue
    fi
    if [ -n "$val" ]; then
      printf -v "$key" '%s' "$val"
      export "${key?}"
      if [ "$key" = "MY_IP" ]; then env_my_ip="$val"; fi
    fi
  done < "$env_file"

  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    die ".env에 AWS_ACCESS_KEY_ID와 AWS_SECRET_ACCESS_KEY를 채우세요. 실습용 IAM 사용자의 액세스 키여야 하며 루트 계정 키는 쓸 수 없습니다. 셸에 export한 키는 쓰지 않습니다. (발급 방법: README 'IAM 사용자 만들기')"
  fi
  if [ -n "$env_my_ip" ]; then
    MY_IP_SOURCE=".env의 MY_IP"
  elif [ -n "$shell_my_ip" ]; then
    MY_IP_SOURCE="셸 환경변수 MY_IP"
  fi

  AWS_REGION="${AWS_REGION:-$REQUIRED_REGION}"
  INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
  AZ="${AZ:-${REQUIRED_REGION}a}"
  PROJECT="${PROJECT:-b3-1}"
  if [ "$AWS_REGION" != "$REQUIRED_REGION" ]; then
    die "미션 제약: 모든 리소스는 서울 리전(ap-northeast-2)에 만듭니다. .env의 AWS_REGION=$AWS_REGION 을 ap-northeast-2로 바꾸세요."
  fi
  if ! [[ "$AZ" =~ ^ap-northeast-2[a-z]$ ]]; then
    die "AZ=$AZ 는 서울 리전의 가용 영역이 아닙니다. 예: ap-northeast-2a"
  fi
  case "$INSTANCE_TYPE" in
    t2.micro | t3.micro) ;;
    *) die "INSTANCE_TYPE=$INSTANCE_TYPE 은(는) 쓸 수 없습니다. 프리 티어 범위인 t3.micro 또는 t2.micro만 허용합니다." ;;
  esac
  if ! [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]]; then
    die "PROJECT=$PROJECT — 영문 소문자·숫자·하이픈만 쓸 수 있습니다(태그·이름에 그대로 들어감)."
  fi

  export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER="" INSTANCE_TYPE AZ PROJECT
  # .env의 키만 쓰도록 프로필 지정을 지운다(없는 프로필이 지정돼 있으면 CLI가 키를 두고도 실패한다)
  unset AWS_PROFILE AWS_DEFAULT_PROFILE
  if [ -z "${AWS_SESSION_TOKEN:-}" ]; then
    unset AWS_SESSION_TOKEN
  fi
  return 0
}

# ------------------------------------------------------------------ 상태 파일

# state/resources.env에서 KEY의 값을 출력한다(없으면 빈 문자열)
state_get() {
  if [ -f "$STATE_FILE" ]; then
    sed -n "s/^$1=//p" "$STATE_FILE" | tail -n 1
  fi
  return 0
}

# KEY=VALUE를 덮어써 저장한다. 임시 파일에 쓴 뒤 옮겨 중간에 끊겨도 파일이 깨지지 않게 한다
state_set() {
  local tmp
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.resources.XXXXXX")"
  if [ -f "$STATE_FILE" ]; then
    grep -v "^$1=" "$STATE_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

# ------------------------------------------------------------------ 마스킹·증거

# 123456789012 → 1234****9012
mask_account() { printf '%s****%s' "${1:0:4}" "${1: -4}"; }

# 203.0.113.77 → 203.0.*.*
mask_ip() { printf '%s.*.*' "${1%.*.*}"; }

# 확장 정규식(ERE)에서 글자 그대로 맞도록 특수문자를 이스케이프한다(s 명령 구분자로 쓰는 / | 포함)
sed_escape() { printf '%s' "$1" | sed 's#[][\.*^$|+?(){}/]#\\&#g'; }

# 오래 걸리는 명령(앱 설치 등)의 출력이 끝날 때까지 쌓이지 않고 줄마다 화면에 보이도록 sed를 줄 단위로 돌린다
# (GNU sed -u. 지원하지 않는 sed면 그대로 쓴다)
SED_LINEBUF=()
if sed -u -e '' < /dev/null > /dev/null 2>&1; then
  SED_LINEBUF=(-u)
fi

# 공개 저장소에 올릴 증거에서 계정 ID와 개인 IP를 가리고, 절대 경로를 프로젝트 기준 경로로 바꾼다.
# 앱 체크아웃(APP_SRC)과 앱 .env(APP_ENV_FILE)의 개인 경로는 <APP_SRC>·<APP_ENV_FILE>로 바꾼다.
# 계정 ID·IP는 숫자 경계를 지켜 다른 값(예: 11.2.3.45)의 일부를 깨뜨리지 않고,
# 경계 글자를 함께 소비하므로 붙어 있는 값(1.2.3.4,1.2.3.4)까지 바뀌도록 t 분기로 반복한다
mask_stream() {
  local args=(-E) ip="${MY_IP:-}"
  # 더 구체적인 경로부터 바꾼다(.env가 앱 폴더 안에 있으면 <APP_ENV_FILE>로 남도록)
  if [ -n "${APP_ENV_FILE:-}" ]; then args+=(-e "s|$(sed_escape "$APP_ENV_FILE")|<APP_ENV_FILE>|g"); fi
  if [ -n "${APP_SRC:-}" ]; then args+=(-e "s|$(sed_escape "$APP_SRC")|<APP_SRC>|g"); fi
  args+=(-e "s|$(sed_escape "$ROOT_DIR/")|./|g")
  # verify·cleanup은 detect_my_ip를 거치지 않으므로 .env 값(예: 1.2.3.4/32)을 여기서 정규화하고,
  # IPv4가 아니면 치환하지 않는다(치환 결과가 다시 일치하면 t 분기가 끝나지 않는다)
  ip="${ip%/32}"
  is_ipv4 "$ip" || ip=""
  # 계정 ID도 12자리 숫자일 때만 가린다(같은 이유)
  if [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    args+=(-e ":acct" -e "s/(^|[^0-9])${ACCOUNT_ID}([^0-9]|\$)/\1$(mask_account "$ACCOUNT_ID")\2/" -e "t acct")
  fi
  if [ -n "$ip" ]; then
    args+=(-e ":ip" -e "s/(^|[^0-9.])$(sed_escape "$ip")([^0-9]|\$)/\1$(mask_ip "$ip")\2/" -e "t ip")
  fi
  sed ${SED_LINEBUF[@]+"${SED_LINEBUF[@]}"} "${args[@]}"
}

mask_text() { printf '%s\n' "$*" | mask_stream; }

# 증거 파일을 새로 시작한다(같은 파일을 여러 번 실행해도 최신 결과만 남도록 덮어쓴다)
evidence_begin() {
  mkdir -p "$EVIDENCE_DIR"
  {
    printf '# %s\n' "$2"
    printf '# 수집 시각: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf '# 리전: %s / 태그: Project=%s\n' "${AWS_DEFAULT_REGION:-?}" "${PROJECT:-?}"
  } > "$EVIDENCE_DIR/$1"
}

evidence_note() {
  mkdir -p "$EVIDENCE_DIR"
  printf '%s\n' "$2" | mask_stream >> "$EVIDENCE_DIR/$1"
}

# 인자를 셸에 그대로 붙여 넣을 수 있는 한 줄로 만든다(특수문자가 있는 인자만 작은따옴표로 감싼다)
shell_join() {
  local a out=""
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
      out+="$a "
    else
      out+="'${a//\'/\'\\\'\'}' "
    fi
  done
  printf '%s' "${out% }"
}

# record FILE -- cmd...  : "$ cmd" 머리말과 출력(stdout+stderr)을 evidence/aws/FILE에 덧붙이고
# 화면에도 보여 준다. 명령의 종료 코드를 그대로 돌려준다
record() {
  local name="$1" rc=0
  shift
  if [ "${1:-}" = "--" ]; then shift; fi
  mkdir -p "$EVIDENCE_DIR"
  printf '\n$ %s\n' "$(shell_join "$@")" | mask_stream >> "$EVIDENCE_DIR/$name"
  "$@" 2>&1 | mask_stream | tee -a "$EVIDENCE_DIR/$name" || rc="${PIPESTATUS[0]}"
  return "$rc"
}

# ------------------------------------------------------------------ 태그·IP

# --tag-specifications 단축 문법 값. 모든 리소스에 Name과 Project 태그를 단다
tag_spec() {
  printf 'ResourceType=%s,Tags=[{Key=Name,Value=%s},{Key=Project,Value=%s}]' "$1" "$2" "$PROJECT"
}

is_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  [ "$ip" != "0.0.0.0" ] || return 1
  local IFS=.
  for o in $ip; do
    [ $((10#$o)) -le 255 ] || return 1
  done
  return 0
}

# SSH(22)를 열어 줄 내 공인 IPv4를 정한다. .env의 MY_IP가 우선이고, 없으면 checkip로 감지한다.
# 결과가 IPv4가 아니면 22번을 넓게 여는 대신 중단한다
detect_my_ip() {
  local ip="${MY_IP:-}" from="${MY_IP_SOURCE:-.env의 MY_IP}"
  if [ -z "$ip" ]; then
    from="자동 감지(checkip.amazonaws.com)"
    ip="$(curl -4 -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')" || ip=""
  fi
  ip="${ip%/32}"
  if ! is_ipv4 "$ip"; then
    die "SSH(22)를 허용할 내 공인 IPv4를 확인하지 못했습니다(값: '${ip:-없음}'). 22번을 0.0.0.0/0으로 넓히지 않고 중단합니다. .env에 MY_IP=<내 공인 IPv4>를 직접 넣으세요. (확인: 브라우저로 https://checkip.amazonaws.com)"
  fi
  MY_IP="$ip"
  export MY_IP
  log "SSH 허용 IP: ${MY_IP}/32 ($from)"
}

# ------------------------------------------------------------------ 배포할 앱(ai_chatbot)

APP_COMMIT_SHA=""

# 상대 경로를 이 프로젝트(ROOT_DIR) 기준 절대 경로로 바꾼다. ~ 는 홈으로 푼다. 폴더가 있으면 실제 경로로 정규화한다
abs_from_root() {
  local p="$1" d
  # shellcheck disable=SC2088 # .env 값은 셸이 ~를 펼치지 않으므로 글자 그대로의 ~를 찾아 직접 바꾼다
  case "$p" in
    "~" | "~/"*) p="$HOME${p#\~}" ;;
  esac
  case "$p" in
    /*) ;;
    *) p="$ROOT_DIR/$p" ;;
  esac
  if [ -d "$p" ]; then
    p="$(cd "$p" && pwd -P)"
  elif [ -d "$(dirname "$p")" ]; then
    d="$(cd "$(dirname "$p")" && pwd -P)"
    p="$d/$(basename "$p")"
  fi
  printf '%s' "$p"
}

# APP_SRC(앱 git 체크아웃, 비우면 이 프로젝트 기준 ../../../ai_chatbot), APP_ENV_FILE(기본 $APP_SRC/.env),
# APP_REF(기본 HEAD)를 정한다
resolve_app_source() {
  APP_SRC="$(abs_from_root "${APP_SRC:-../../../ai_chatbot}")"
  APP_ENV_FILE="$(abs_from_root "${APP_ENV_FILE:-$APP_SRC/.env}")"
  APP_REF="${APP_REF:-HEAD}"
  export APP_SRC APP_ENV_FILE APP_REF
}

# env 파일 FILE에서 KEY의 값을 변수 이름 VAR에 담는다(마지막 줄이 이긴다). 값은 화면에 내지 않는다
env_file_get() {
  local file="$1" key="$2" line found=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] &&
      [ "${BASH_REMATCH[2]}" = "$key" ]; then
      found="$(env_value "${BASH_REMATCH[3]}")"
    fi
  done < "$file"
  printf -v "$3" '%s' "$found"
}

# 앱 소스와 .env를 AWS를 부르기 전에 확인한다. 비밀값은 출력하지 않고 "있음/비어 있음"만 알린다
check_app_source() {
  local top secret="" llm="" naver_id="" naver_secret=""
  resolve_app_source
  command -v git > /dev/null 2>&1 || die "git이 필요합니다. 배포할 앱 소스를 git archive로 묶습니다. 예: sudo apt-get install -y git"
  # 리소스를 다 만든 뒤 앱 전송 단계에서야 없다는 것을 알면 서버만 켜 둔 채 멈추므로 미리 확인한다
  if ! command -v ssh > /dev/null 2>&1 || ! command -v scp > /dev/null 2>&1; then
    die "ssh·scp가 필요합니다. 앱 소스와 앱 .env를 SSH(22)로 서버에 보냅니다. 예: sudo apt-get install -y openssh-client"
  fi
  if [ ! -d "$APP_SRC" ]; then
    die "배포할 앱 폴더가 없습니다(APP_SRC=$APP_SRC). ai_chatbot을 clone한 경로를 .env의 APP_SRC에 넣으세요. 비워 두면 이 프로젝트 기준 ../../../ai_chatbot 을 씁니다."
  fi
  top="$(git -C "$APP_SRC" rev-parse --show-toplevel 2> /dev/null || true)"
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$APP_SRC" ]; then
    die "APP_SRC=$APP_SRC 는 git 저장소(최상위 폴더)가 아닙니다. git clone https://github.com/L-jy16/ai_chatbot.git 으로 받은 폴더를 APP_SRC에 넣으세요."
  fi
  APP_COMMIT_SHA="$(git -C "$APP_SRC" rev-parse --verify --quiet "${APP_REF}^{commit}" 2> /dev/null || true)"
  if [ -z "$APP_COMMIT_SHA" ]; then
    die "APP_REF=$APP_REF 에 해당하는 커밋을 APP_SRC에서 찾지 못했습니다. 브랜치·태그·커밋 이름을 확인하세요(예: APP_REF=develop, 원격 브랜치는 git fetch 후 origin/develop)."
  fi
  if ! git -C "$APP_SRC" cat-file -e "$APP_COMMIT_SHA:app/main.py" 2> /dev/null ||
    ! git -C "$APP_SRC" cat-file -e "$APP_COMMIT_SHA:requirements.txt" 2> /dev/null; then
    die "APP_REF에 앱 코드가 없습니다(APP_REF=$APP_REF 에 app/main.py·requirements.txt 없음). ai_chatbot은 develop 브랜치에 코드가 있습니다(APP_REF=develop). main은 초기 커밋뿐입니다."
  fi
  if [ ! -f "$APP_ENV_FILE" ] || [ ! -r "$APP_ENV_FILE" ]; then
    die "앱 .env가 없습니다(APP_ENV_FILE=$APP_ENV_FILE). ai_chatbot 폴더에서 'cp .env.example .env' 후 LLM_API_KEY·NAVER_CLIENT_ID·NAVER_CLIENT_SECRET를 채우세요(SECRET_KEY는 비워 두면 서버가 만듭니다). 다른 위치의 파일이면 .env의 APP_ENV_FILE에 경로를 넣으세요."
  fi
  if [ "$APP_REF" = "HEAD" ] && [ -n "$(git -C "$APP_SRC" status --porcelain --untracked-files=no 2> /dev/null)" ]; then
    warn "APP_SRC에 커밋하지 않은 변경이 있습니다. 배포는 커밋된 내용(git archive)만 올리므로 그 변경은 서버에 가지 않습니다."
  fi
  env_file_get "$APP_ENV_FILE" SECRET_KEY secret
  env_file_get "$APP_ENV_FILE" LLM_API_KEY llm
  env_file_get "$APP_ENV_FILE" NAVER_CLIENT_ID naver_id
  env_file_get "$APP_ENV_FILE" NAVER_CLIENT_SECRET naver_secret
  log "배포할 앱: APP_REF=$APP_REF → 커밋 ${APP_COMMIT_SHA:0:12} ($(git -C "$APP_SRC" log -1 --format=%s "$APP_COMMIT_SHA" 2> /dev/null | cut -c1-60))"
  log "앱 .env 항목(값은 표시하지 않음): SECRET_KEY $([ "${#secret}" -ge 16 ] && echo 있음 || echo '비어 있음·16자 미만 → 서버의 기존 값 유지, 없으면 생성') / LLM_API_KEY $([ -n "$llm" ] && echo 있음 || echo 비어 있음) / NAVER 키 $([ -n "$naver_id" ] && [ -n "$naver_secret" ] && echo 있음 || echo 비어 있음)"
  if [ -z "$llm" ]; then
    warn "앱 .env의 LLM_API_KEY가 비어 있습니다. 배포는 진행하지만 채팅(AI 답변)만 동작하지 않습니다(502 AI_ERROR). 키를 채운 뒤 ./deploy.sh를 다시 실행하면 .env가 바뀐 것을 알아채고 소스와 .env를 다시 올려 설치를 다시 합니다(venv·DB는 유지)."
  fi
  secret="" llm="" naver_id="" naver_secret=""
}

# 앱 .env가 바뀌었는지 알기 위한 표식(수정 시각:크기). 내용에서 만들지 않으므로 비밀값과 무관하다.
# 심볼릭 링크면 링크가 가리키는 파일을 본다(-L). GNU stat, 안 되면 BSD stat, 그것도 안 되면
# 매번 다른 값을 돌려 "모르면 다시 올린다"
app_env_stamp() {
  stat -L -c '%Y:%s' "$APP_ENV_FILE" 2> /dev/null ||
    stat -L -f '%m:%z' "$APP_ENV_FILE" 2> /dev/null ||
    echo "unknown-$(date +%s)"
}

# ------------------------------------------------------------------ SSH

# deploy·verify가 같이 쓰는 SSH·scp 옵션. 첫 접속의 호스트 키는 state/known_hosts에 저장하고(이후 바뀌면 거부),
# 비밀번호 프롬프트 없이(BatchMode) 이 키만 쓴다
ssh_setup() {
  local key_name
  key_name="$(state_get KEY_NAME)"
  SSH_PEM="$STATE_DIR/${key_name:-$PROJECT-key}.pem"
  # shellcheck disable=SC2034 # deploy.sh·verify.sh가 쓴다
  SSH_OPTS=(-i "$SSH_PEM" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE_DIR/known_hosts"
    -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes -o LogLevel=ERROR
    -o ServerAliveInterval=15 -o ServerAliveCountMax=8)
}

# ------------------------------------------------------------------ 사전 점검

# 키로 누가 호출하는지 확인한다. 루트 계정이면 미션 제약 위반이므로 중단한다
check_identity() {
  local arn errf
  errf="$(mktemp)"
  if ! arn="$(aws sts get-caller-identity --query Arn --output text 2>"$errf")"; then
    cat "$errf" >&2
    rm -f "$errf"
    die "AWS 자격 증명 확인(sts get-caller-identity)에 실패했습니다. .env의 AWS_ACCESS_KEY_ID·AWS_SECRET_ACCESS_KEY 값(앞뒤 공백·따옴표), 키가 비활성화되지 않았는지, 임시 키라면 AWS_SESSION_TOKEN을 확인하세요."
  fi
  rm -f "$errf"
  CALLER_ARN="$(printf '%s' "$arn" | tr -d '[:space:]')"
  ACCOUNT_ID="$(printf '%s' "$CALLER_ARN" | cut -d: -f5)"
  case "$CALLER_ARN" in
    *:root)
      die "루트 계정 키입니다 ($(mask_text "$CALLER_ARN")). 미션 제약상 루트 계정은 쓰지 않습니다. ${ROOT_HINT:-실습용 IAM 사용자를 만들어 그 키를 .env에 넣으세요. (README 'IAM 사용자 만들기')}"
      ;;
  esac
  log "실행 주체: $(mask_text "$CALLER_ARN")"
}

write_identity_evidence() {
  evidence_begin 00-identity.txt "사전 점검 — 실행 주체와 배포 설정 (deploy.sh)"
  {
    printf '\n$ aws sts get-caller-identity --query Arn --output text\n%s\n' "$CALLER_ARN"
    printf '\n$ aws --version\n%s\n' "$(aws --version 2>&1)"
    printf '\n리전: %s / 가용 영역: %s\n' "$AWS_DEFAULT_REGION" "$AZ"
    printf '인스턴스 유형: %s\n' "$INSTANCE_TYPE"
    printf 'SSH(22) 허용 소스: %s/32\n' "$MY_IP"
  } | mask_stream >> "$EVIDENCE_DIR/00-identity.txt"
}

# .env 로드 → (--app) 앱 소스·.env 확인 → aws CLI 확보 → 실행 주체 확인(루트 거부) → 내 IP 확인 → 00-identity 증거.
# --app: 배포할 앱을 AWS 호출 전에 확인한다(deploy.sh)
# --no-ip: 내 IP가 필요 없는 정리 작업용(감지 실패로 정리가 막히지 않게 한다)
preflight() {
  local want_ip=1 want_app=0 a
  for a in "$@"; do
    case "$a" in
      --no-ip) want_ip=0 ;;
      --app) want_app=1 ;;
    esac
  done
  load_env
  if [ "$want_app" = 1 ]; then
    check_app_source
  fi
  command -v curl > /dev/null 2>&1 || die "curl이 필요합니다. 예: sudo apt-get install -y curl"
  ensure_awscli
  check_identity
  if [ "$want_ip" = 1 ]; then
    detect_my_ip
    write_identity_evidence
  fi
}
