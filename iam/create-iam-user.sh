#!/usr/bin/env bash
# (선택 도우미) 실습용 IAM 사용자 만들기 — 관리자 권한이 있는 IAM 사용자(루트 아님)의 자격 증명으로 한 번 실행한다.
#   iam create-user b3-1-operator → 최소권한 정책 만들기(있으면 재사용) → 연결 → 액세스 키 발급 → .env 작성
#   --console 을 주면 콘솔 로그인 비밀번호(무작위, 첫 로그인 때 변경 강제)도 만든다.
# 관리자 자격 증명: --profile <이름>  또는  ADMIN_AWS_ACCESS_KEY_ID / ADMIN_AWS_SECRET_ACCESS_KEY (/ ADMIN_AWS_SESSION_TOKEN)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/awscli.sh
source "$SCRIPT_DIR/../lib/awscli.sh"

USER_NAME="b3-1-operator"
POLICY_NAME="b3-1-least-privilege"
POLICY_FILE="$ROOT_DIR/iam/least-privilege-policy.json"
CHANGE_PASSWORD_POLICY="arn:aws:iam::aws:policy/IAMUserChangePassword"
PROJECT="${PROJECT:-b3-1}"

usage() {
  cat << 'EOF'
사용법: ./iam/create-iam-user.sh [--profile 관리자프로필] [--console] [--user 이름]

  관리자 권한이 있는 IAM 사용자(루트 아님)의 자격 증명으로 실행한다.
    --profile NAME   ~/.aws/credentials의 관리자 프로필을 쓴다
    (또는)           ADMIN_AWS_ACCESS_KEY_ID / ADMIN_AWS_SECRET_ACCESS_KEY 환경변수
    --console        콘솔 로그인 비밀번호도 만든다(첫 로그인 때 변경 강제, 지금 한 번만 표시)
    --user NAME      만들 사용자 이름(기본 b3-1-operator)

  결과: 실습용 사용자 + 최소권한 정책 연결 + 새 액세스 키가 들어간 .env (기존 .env는 .env.bak)
  루트 계정만 있다면 이 도우미 대신 README 'IAM 사용자 만들기 — 방법 1(콘솔)'을 따르세요.
EOF
}

# .env를 만든다: 기존 .env(없으면 .env.example)를 바탕으로 키 두 줄만 새 값으로 바꾼다
write_env_file() {
  local key_id="$1" secret="$2" env_file="$ROOT_DIR/.env" template tmp
  template="$ROOT_DIR/.env.example"
  if [ -f "$env_file" ]; then
    cp -p "$env_file" "$ROOT_DIR/.env.bak"
    chmod 600 "$ROOT_DIR/.env.bak"
    template="$ROOT_DIR/.env.bak"
    log "기존 .env를 .env.bak으로 백업했습니다."
  fi
  tmp="$(mktemp "$ROOT_DIR/.env.XXXXXX")"
  {
    grep -q '^AWS_ACCESS_KEY_ID=' "$template" || echo "AWS_ACCESS_KEY_ID="
    grep -q '^AWS_SECRET_ACCESS_KEY=' "$template" || echo "AWS_SECRET_ACCESS_KEY="
    cat "$template"
  } | sed -e "s|^AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=${key_id}|" \
    -e "s|^AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=${secret}|" \
    -e "s|^AWS_SESSION_TOKEN=.*|AWS_SESSION_TOKEN=|" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$env_file"
}

main() {
  local profile="" console=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        profile="${2:-}"
        shift
        ;;
      --console) console=1 ;;
      --user)
        USER_NAME="${2:-}"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "알 수 없는 옵션: $1 (./iam/create-iam-user.sh --help)" ;;
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
    die "관리자 자격 증명이 필요합니다. --profile <관리자 프로필> 을 주거나 ADMIN_AWS_ACCESS_KEY_ID / ADMIN_AWS_SECRET_ACCESS_KEY 환경변수를 설정하세요. (루트 계정만 있다면 README의 콘솔 방법을 따르세요)"
  fi
  export AWS_REGION="$REQUIRED_REGION" AWS_DEFAULT_REGION="$REQUIRED_REGION" AWS_PAGER=""

  ensure_awscli
  ROOT_HINT="루트 키는 만들지도 쓰지도 않는 것이 원칙입니다. 루트로 콘솔에 로그인해 README 'IAM 사용자 만들기 — 방법 1(콘솔)'을 따르세요."
  check_identity

  if aws iam get-user --user-name "$USER_NAME" > /dev/null 2>&1; then
    log "IAM 사용자 재사용: $USER_NAME"
  else
    aws iam create-user --user-name "$USER_NAME" --tags "Key=Project,Value=$PROJECT" > /dev/null
    log "IAM 사용자 생성: $USER_NAME"
  fi

  local policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
  if aws iam get-policy --policy-arn "$policy_arn" > /dev/null 2>&1; then
    log "정책 재사용: $POLICY_NAME (JSON을 고쳤다면 콘솔이나 'aws iam create-policy-version'으로 새 버전을 올리세요)"
  else
    policy_arn="$(aws iam create-policy --policy-name "$POLICY_NAME" \
      --policy-document "file://$POLICY_FILE" \
      --description "B3-1 lab: EC2/VPC/SG/KeyPair actions only, ap-northeast-2 only" \
      --query Policy.Arn --output text)"
    log "정책 생성: $policy_arn"
  fi
  aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$policy_arn"
  log "정책 연결: $USER_NAME ← $POLICY_NAME"

  local keys key_id secret
  keys="$(aws iam create-access-key --user-name "$USER_NAME" \
    --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)" ||
    die "액세스 키 발급에 실패했습니다. IAM 사용자당 키는 최대 2개입니다. 콘솔에서 쓰지 않는 키를 삭제한 뒤 다시 실행하세요."
  read -r key_id secret <<< "$keys"
  if [ -z "$key_id" ] || [ -z "$secret" ]; then
    die "발급된 액세스 키를 읽지 못했습니다. 콘솔에서 키를 확인하세요."
  fi
  write_env_file "$key_id" "$secret"
  log ".env 작성 완료 (AWS_ACCESS_KEY_ID=${key_id:0:4}…${key_id: -4}, 권한 600)"

  local password=""
  if [ "$console" = 1 ]; then
    # 첫 로그인 때 비밀번호를 바꾸려면 본인 비밀번호 변경 권한(AWS 관리형 IAMUserChangePassword)이 필요하다
    aws iam attach-user-policy --user-name "$USER_NAME" --policy-arn "$CHANGE_PASSWORD_POLICY"
    password="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)Aa1!"
    aws iam create-login-profile --user-name "$USER_NAME" --password "$password" --password-reset-required > /dev/null ||
      die "콘솔 비밀번호를 만들지 못했습니다(이미 있으면 콘솔에서 '콘솔 비밀번호 관리'로 재설정하세요)."
  fi

  cat << EOF

==================== IAM 사용자 준비 완료 ====================
 사용자          $USER_NAME
 연결한 정책     $POLICY_NAME (EC2·VPC·SG·키페어 작업만, 서울 리전만, t2/t3.micro만)
 .env            새 액세스 키 기록 완료 → 다음 단계: ./deploy.sh
 콘솔 로그인     https://${ACCOUNT_ID}.signin.aws.amazon.com/console
EOF
  if [ -n "$password" ]; then
    cat << EOF
 초기 비밀번호   $password
                 ↑ 지금 한 번만 표시합니다. 첫 로그인 때 새 비밀번호로 바꿔야 합니다.
EOF
  fi
  echo "=============================================================="
}

main "$@"
