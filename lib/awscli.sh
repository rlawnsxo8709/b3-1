# shellcheck shell=bash
# aws CLI v2 확보 — 이미 있으면 그대로 쓰고, 없으면 프로젝트 안(./.tools)에 sudo 없이 설치한다.
# lib/common.sh 다음에 source 한다(ROOT_DIR·log·die 사용).

AWSCLI_TOOLS_DIR="$ROOT_DIR/.tools"

# CPU 아키텍처(uname -m)에 맞는 공식 설치 패키지 주소
awscli_installer_url() {
  case "$1" in
    x86_64) echo "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64) echo "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *) die "CPU 아키텍처 $1 용 aws CLI 자동 설치는 지원하지 않습니다. https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html 을 따라 직접 설치한 뒤 다시 실행하세요." ;;
  esac
}

ensure_awscli() {
  if command -v aws > /dev/null 2>&1; then
    case "$(aws --version 2>&1)" in
      aws-cli/1.*) warn "aws CLI v1이 감지됐습니다. 이 스크립트는 v2 기준으로 작성됐습니다(v1에서도 대부분 동작). 문제가 생기면 v2를 설치하세요." ;;
    esac
    return 0
  fi
  if [ -x "$AWSCLI_TOOLS_DIR/bin/aws" ]; then
    PATH="$AWSCLI_TOOLS_DIR/bin:$PATH"
    export PATH
    return 0
  fi

  if [ "$(uname -s)" != "Linux" ]; then
    die "aws CLI가 없습니다. 자동 설치는 Linux(WSL 포함)만 지원합니다. macOS는 'brew install awscli' 또는 https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html 로 설치하세요."
  fi
  command -v unzip > /dev/null 2>&1 ||
    die "aws CLI 자동 설치에 unzip이 필요합니다. 예: sudo apt-get install -y unzip (또는 aws CLI v2를 직접 설치)"

  local url tmp update=()
  url="$(awscli_installer_url "$(uname -m)")" || exit 1
  tmp="$(mktemp -d)"
  log "aws CLI가 없어 v2를 프로젝트 안(.tools/)에 설치합니다(sudo 불필요): $url"
  if ! curl -fsSL --retry 3 -o "$tmp/awscliv2.zip" "$url"; then
    rm -rf "$tmp"
    die "aws CLI 다운로드에 실패했습니다. 네트워크를 확인하거나 직접 설치하세요."
  fi
  if ! unzip -q "$tmp/awscliv2.zip" -d "$tmp"; then
    rm -rf "$tmp"
    die "aws CLI 압축 해제에 실패했습니다."
  fi
  # 이전에 설치하다 끊긴 흔적이 있으면 공식 설치기는 --update를 요구한다
  if [ -d "$AWSCLI_TOOLS_DIR/aws-cli" ]; then
    update=(--update)
  fi
  mkdir -p "$AWSCLI_TOOLS_DIR"
  if ! "$tmp/aws/install" -i "$AWSCLI_TOOLS_DIR/aws-cli" -b "$AWSCLI_TOOLS_DIR/bin" "${update[@]}" > /dev/null; then
    rm -rf "$tmp"
    die "aws CLI 설치에 실패했습니다. .tools/ 폴더를 지우고 다시 실행하거나 직접 설치하세요."
  fi
  rm -rf "$tmp"
  PATH="$AWSCLI_TOOLS_DIR/bin:$PATH"
  export PATH
  log "aws CLI 설치 완료: $(aws --version 2>&1)"
}
