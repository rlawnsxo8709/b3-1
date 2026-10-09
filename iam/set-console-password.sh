#!/usr/bin/env bash
# (선택 도우미) 이미 있는 실습용 IAM 사용자에게 콘솔 로그인 비밀번호를 만든다 — 관리자 자격 증명으로 한 번 실행한다.
#   본인 비밀번호 변경 권한(IAMUserChangePassword) + CLI 브라우저 로그인 권한(SignInLocalDevelopmentAccess) 연결
#   → 무작위 비밀번호로 로그인 프로필 생성(첫 로그인 때 변경 강제) → 비밀번호를 화면에 한 번만 표시
#   이후 'aws login --profile <이름>'에서 브라우저로 이 사용자로 로그인할 수 있다.
# 사용자·정책·액세스 키·.env는 건드리지 않는다(그건 create-iam-user.sh).
# 관리자 PC(macOS 기본 bash 3.2)에서 바로 돌도록 bash 4가 필요한 lib/common.sh는 쓰지 않는다.
set -Eeuo pipefail

USER_NAME="b3-1-operator"
REGION="ap-northeast-2"
CHANGE_PASSWORD_POLICY="arn:aws:iam::aws:policy/IAMUserChangePassword"
CLI_LOGIN_POLICY="arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"

log() { printf '[INFO] %s\n' "$*" >&2; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}
mask_account() { printf '%s****%s' "${1:0:4}" "${1: -4}"; }

usage() {
  cat << 'EOF'
사용법: ./iam/set-console-password.sh [--profile 관리자프로필] [--user 이름] [--reset] [--allow-root]

  관리자 권한이 있는 자격 증명으로 실행한다.
    --profile NAME   ~/.aws의 관리자 프로필을 쓴다(aws login으로 만든 프로필 포함)
    (또는)           ADMIN_AWS_ACCESS_KEY_ID / ADMIN_AWS_SECRET_ACCESS_KEY 환경변수
    --user NAME      비밀번호를 만들 사용자(기본 b3-1-operator). 사용자가 없으면 create-iam-user.sh부터
    --reset          이미 비밀번호가 있으면 새 무작위 비밀번호로 바꾼다(없으면 거부)
    --allow-root     루트 자격 증명을 허용한다. 관리자 IAM 사용자가 아직 없을 때 이 한 번만 쓴다

  결과: 콘솔/CLI 로그인용 초기 비밀번호(지금 한 번만 표시, 첫 로그인 때 변경 강제)
  다음 단계: aws login --profile b3-1 --region ap-northeast-2 → 브라우저에서 계정 ID·사용자 이름·비밀번호로 로그인
EOF
}

# 영문 대·소문자·숫자·기호가 모두 들어간 20자. 계정 비밀번호 정책 기본값(8자 이상, 문자 종류 3가지)을 넘는다
make_password() {
  local body
  body="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  [ "${#body}" -eq 16 ] || die "무작위 비밀번호를 만들지 못했습니다."
  printf '%sAa1!' "$body"
}

main() {
  local profile="" reset=0 allow_root=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        profile="${2:-}"
        shift
        ;;
      --user)
        USER_NAME="${2:-}"
        shift
        ;;
      --reset) reset=1 ;;
      --allow-root) allow_root=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "알 수 없는 옵션: $1 (./iam/set-console-password.sh --help)" ;;
    esac
    shift
  done
  [[ "$USER_NAME" =~ ^[A-Za-z0-9+=,.@_-]{1,64}$ ]] || die "IAM 사용자 이름 형식이 올바르지 않습니다: $USER_NAME"

  # 실습용 .env 키가 아니라 관리자 자격 증명으로만 호출한다
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
  if [ -n "$profile" ]; then
    export AWS_PROFILE="$profile"
  elif [ -n "${ADMIN_AWS_ACCESS_KEY_ID:-}" ] && [ -n "${ADMIN_AWS_SECRET_ACCESS_KEY:-}" ]; then
    export AWS_ACCESS_KEY_ID="$ADMIN_AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$ADMIN_AWS_SECRET_ACCESS_KEY"
    if [ -n "${ADMIN_AWS_SESSION_TOKEN:-}" ]; then
      export AWS_SESSION_TOKEN="$ADMIN_AWS_SESSION_TOKEN"
    fi
  else
    die "관리자 자격 증명이 필요합니다. --profile <관리자 프로필> 을 주거나 ADMIN_AWS_ACCESS_KEY_ID / ADMIN_AWS_SECRET_ACCESS_KEY 환경변수를 설정하세요."
  fi
  export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" AWS_PAGER=""

  command -v aws > /dev/null 2>&1 || die "aws CLI가 없습니다. https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html 로 설치하세요."

  local arn account
  arn="$(aws sts get-caller-identity --query Arn --output text)" ||
    die "관리자 자격 증명 확인(sts get-caller-identity)에 실패했습니다. 프로필이라면 'aws login --profile <이름>'으로 다시 로그인하세요."
  arn="$(printf '%s' "$arn" | tr -d '[:space:]')"
  account="$(printf '%s' "$arn" | cut -d: -f5)"
  case "$arn" in
    *:root)
      [ "$allow_root" = 1 ] ||
        die "루트 자격 증명입니다(계정 $(mask_account "$account")). 미션 제약상 루트는 쓰지 않습니다. 관리자 IAM 사용자가 아직 없어 이번 한 번만 루트로 해야 한다면 --allow-root 를 붙이세요."
      warn "루트 자격 증명으로 실행합니다(--allow-root). 끝나면 루트 대신 IAM 사용자로 로그인하세요."
      ;;
    *) log "실행 주체: ${arn/$account/$(mask_account "$account")}" ;;
  esac

  aws iam get-user --user-name "$USER_NAME" > /dev/null 2>&1 ||
    die "IAM 사용자 $USER_NAME 이 없습니다. 먼저 ./iam/create-iam-user.sh 로 만드세요."

  local has_profile=0
  if aws iam get-login-profile --user-name "$USER_NAME" > /dev/null 2>&1; then
    has_profile=1
    [ "$reset" = 1 ] ||
      die "$USER_NAME 에게 이미 콘솔 비밀번호가 있습니다. 잊어버렸다면 --reset 을 붙여 새 비밀번호로 바꾸세요."
  fi

  # 첫 로그인 때 비밀번호를 바꾸려면 본인 비밀번호 변경 권한이, aws login(브라우저 로그인)에는 Sign-in OAuth2 권한이 필요하다
  aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$CHANGE_PASSWORD_POLICY"
  aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$CLI_LOGIN_POLICY"
  log "정책 연결: $USER_NAME ← IAMUserChangePassword, SignInLocalDevelopmentAccess"

  local password
  password="$(make_password)"
  if [ "$has_profile" = 1 ]; then
    aws iam update-login-profile --user-name "$USER_NAME" --password "$password" --password-reset-required ||
      die "콘솔 비밀번호를 바꾸지 못했습니다. 계정의 비밀번호 정책을 확인하세요."
    log "콘솔 비밀번호 재설정: $USER_NAME"
  else
    aws iam create-login-profile --user-name "$USER_NAME" --password "$password" --password-reset-required > /dev/null ||
      die "콘솔 비밀번호를 만들지 못했습니다. 계정의 비밀번호 정책을 확인하세요."
    log "콘솔 비밀번호 생성: $USER_NAME"
  fi

  cat << EOF

==================== 콘솔 비밀번호 준비 완료 ====================
 계정 ID         $account
 사용자          $USER_NAME
 초기 비밀번호   $password
                 ↑ 지금 한 번만 표시합니다. 첫 로그인 때 새 비밀번호로 바꿔야 합니다.
 콘솔 로그인     https://${account}.signin.aws.amazon.com/console
 CLI 로그인      aws login --profile b3-1 --region $REGION
                 → 브라우저에서 루트 이메일이 아니라 'IAM 사용자'로 로그인
=================================================================
EOF
}

main "$@"
