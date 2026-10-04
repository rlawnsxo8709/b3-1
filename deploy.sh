#!/usr/bin/env bash
# B3-1 배포 — .env의 IAM 사용자 키로 서울 리전(ap-northeast-2)에 아래를 만들고 외부 접속까지 검증한다.
#   VPC 10.0.0.0/16 → Public Subnet 10.0.1.0/24 → IGW 연결 → Route Table(0.0.0.0/0 → IGW)
#   → SG(80: 0.0.0.0/0, 22: 내 IP/32) → 키페어 → Ubuntu 24.04 EC2(user-data로 Nginx) → verify.sh --wait
# 만든 리소스 ID는 즉시 state/resources.env에 적는다. 중간에 실패하면 원인을 고친 뒤 다시 실행한다.
# 이미 끝난 단계는 건너뛰고 이어서 진행한다.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/awscli.sh
source "$SCRIPT_DIR/lib/awscli.sh"

VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
UBUNTU_OWNER="099720109477" # Canonical 공식 계정. 이름만 흉내 낸 타인 AMI를 거른다
EXISTS_TRIES=20
EXISTS_SLEEP="${DEPLOY_EXISTS_SLEEP:-3}"
CURRENT_STEP="시작"
VPC_ID="" SUBNET_ID="" IGW_ID="" RT_ID="" SG_ID="" KEY_NAME="" AMI_ID="" INSTANCE_ID="" PUBLIC_IP=""

usage() {
  cat << 'EOF'
사용법: ./deploy.sh [--preflight-only]

  (옵션 없음)        사전 점검 → VPC·Subnet·IGW·Route Table·SG·키페어·EC2 생성
                     → /health 응답 대기 → 외부 접속 검증 → evidence/aws/에 증거 저장
  --preflight-only   .env·aws CLI·자격 증명(루트 거부)·내 IP·프리 티어 대상 유형(아니면 경고) 확인까지만 한다.
                     리소스를 만들지 않는다
  -h, --help         이 도움말

다시 실행하면 state/resources.env에 기록된 단계는 건너뛴다. 실습이 끝나면 ./cleanup.sh
EOF
}

# 실패한 지점과 이어서 하는 방법을 알려 준다(명령 치환 안의 오류는 바깥 셸에서 한 번만 알린다)
on_error() {
  local rc="$1" cmd="$2"
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    return 0
  fi
  printf '[ERROR] 실패한 명령(종료 코드 %s): %s\n' "$rc" "${cmd:0:300}" >&2
  die "단계 실패: ${CURRENT_STEP}. 원인을 고친 뒤 ./deploy.sh를 다시 실행하면 이어서 진행합니다. 정리는 ./cleanup.sh"
}

# AWS가 돌려준 값이 기대한 ID 형식인지 확인한다(빈 값·None으로 다음 단계가 엉뚱하게 진행되는 것 방지)
expect_id() {
  if [[ "$2" != "$1"-* ]]; then
    printf '[ERROR] %s ID를 받지 못했습니다(받은 값: %s)\n' "$3" "${2:-없음}" >&2
    return 1
  fi
}

# 방금 만든 리소스가 조회될 때까지 기다린다(AWS API의 최종 일관성). NotFound만 다시 시도한다.
# 생성 직후 연결·경로·규칙 추가가 "없는 ID"로 실패하지 않게 Subnet·IGW·Route Table·SG 생성 뒤에 부른다
wait_exists() {
  local desc="$1" i err
  shift 2
  for ((i = 1; i <= EXISTS_TRIES; i++)); do
    if err="$("$@" 2>&1 > /dev/null)"; then
      return 0
    fi
    if [[ "$err" != *NotFound* ]]; then
      printf '%s\n' "$err" >&2
      return 1
    fi
    log "$desc 이(가) 아직 조회되지 않습니다. ${EXISTS_SLEEP}초 뒤 다시 확인합니다(${i}/${EXISTS_TRIES})."
    sleep "$EXISTS_SLEEP"
  done
  printf '[ERROR] %s 이(가) %s번 확인하는 동안 조회되지 않았습니다.\n' "$desc" "$EXISTS_TRIES" >&2
  return 1
}

# 프리 티어 대상 유형은 계정마다 다르다(2025-07-15 이전 가입 계정은 서울에서 t2.micro, 이후는 t3.micro 등).
# 선택한 유형이 대상이 아니면 경고만 하고 막지는 않는다
check_free_tier() {
  local eligible alt="" t
  if ! eligible="$(aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true \
    --query 'InstanceTypes[].InstanceType' --output text 2> /dev/null)"; then
    warn "프리 티어 대상 인스턴스 유형을 조회하지 못해 확인을 건너뜁니다."
    return 0
  fi
  eligible=" $(printf '%s' "$eligible" | tr -s '[:space:]' ' ') "
  if [[ "$eligible" == *" $INSTANCE_TYPE "* ]]; then
    log "인스턴스 유형 $INSTANCE_TYPE: 이 계정의 프리 티어 대상"
    return 0
  fi
  for t in t3.micro t2.micro; do
    if [[ "$eligible" == *" $t "* ]]; then
      alt="$t"
      break
    fi
  done
  if [ -n "$alt" ]; then
    warn "$INSTANCE_TYPE 은(는) 이 계정의 프리 티어 대상이 아니라 과금될 수 있습니다. 이 계정의 대상은 $alt 입니다 → .env에 INSTANCE_TYPE=$alt 를 넣고 다시 실행하세요. (막지는 않고 그대로 진행합니다)"
  else
    warn "$INSTANCE_TYPE 은(는) 이 계정의 프리 티어 대상이 아니고, 허용 유형(t2.micro·t3.micro) 중에도 대상이 없습니다(대상:${eligible}). 과금될 수 있으니 확인하세요. (그대로 진행합니다)"
  fi
}

step_vpc() {
  CURRENT_STEP="VPC"
  VPC_ID="$(state_get VPC_ID)"
  if [ -z "$VPC_ID" ]; then
    VPC_ID="$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
      --tag-specifications "$(tag_spec vpc "$PROJECT-vpc")" \
      --query Vpc.VpcId --output text)"
    expect_id vpc "$VPC_ID" VPC
    state_set VPC_ID "$VPC_ID"
    log "VPC 생성: $VPC_ID ($VPC_CIDR)"
    aws ec2 wait vpc-exists --vpc-ids "$VPC_ID"
    aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
  else
    log "VPC 재사용: $VPC_ID"
  fi
  if [ "$(state_get VPC_DNS_HOSTNAMES)" != "yes" ]; then
    aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
    state_set VPC_DNS_HOSTNAMES yes
  fi
}

step_subnet() {
  CURRENT_STEP="Public Subnet"
  SUBNET_ID="$(state_get SUBNET_ID)"
  if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID="$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
      --availability-zone "$AZ" \
      --tag-specifications "$(tag_spec subnet "$PROJECT-public-subnet")" \
      --query Subnet.SubnetId --output text)"
    expect_id subnet "$SUBNET_ID" Subnet
    state_set SUBNET_ID "$SUBNET_ID"
    log "Subnet 생성: $SUBNET_ID ($SUBNET_CIDR, $AZ)"
    # subnet-available 대기는 NotFound를 만나면 바로 실패하므로, 먼저 조회될 때까지 기다린다
    wait_exists "Subnet $SUBNET_ID" -- aws ec2 describe-subnets --subnet-ids "$SUBNET_ID"
    aws ec2 wait subnet-available --subnet-ids "$SUBNET_ID"
  else
    log "Subnet 재사용: $SUBNET_ID"
  fi
  # 이 서브넷에 뜨는 인스턴스가 퍼블릭 IP를 자동으로 받게 한다(EIP 없이 외부 접속)
  if [ "$(state_get SUBNET_PUBLIC_IP)" != "yes" ]; then
    aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
    state_set SUBNET_PUBLIC_IP yes
  fi
}

step_igw() {
  CURRENT_STEP="Internet Gateway"
  IGW_ID="$(state_get IGW_ID)"
  if [ -z "$IGW_ID" ]; then
    IGW_ID="$(aws ec2 create-internet-gateway \
      --tag-specifications "$(tag_spec internet-gateway "$PROJECT-igw")" \
      --query InternetGateway.InternetGatewayId --output text)"
    expect_id igw "$IGW_ID" "Internet Gateway"
    state_set IGW_ID "$IGW_ID"
    log "IGW 생성: $IGW_ID"
    wait_exists "Internet Gateway $IGW_ID" -- aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID"
  else
    log "IGW 재사용: $IGW_ID"
  fi
  if [ "$(state_get IGW_ATTACHED)" != "yes" ]; then
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    state_set IGW_ATTACHED yes
    log "IGW 연결: $IGW_ID → $VPC_ID"
  fi
}

step_route() {
  CURRENT_STEP="Route Table"
  RT_ID="$(state_get RT_ID)"
  if [ -z "$RT_ID" ]; then
    RT_ID="$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec route-table "$PROJECT-public-rt")" \
      --query RouteTable.RouteTableId --output text)"
    expect_id rtb "$RT_ID" "Route Table"
    state_set RT_ID "$RT_ID"
    log "Route Table 생성: $RT_ID"
    wait_exists "Route Table $RT_ID" -- aws ec2 describe-route-tables --route-table-ids "$RT_ID"
  else
    log "Route Table 재사용: $RT_ID"
  fi
  # 이 경로가 있어야 서브넷이 "퍼블릭"이 된다. VPC 밖으로 가는 모든 트래픽을 IGW로 보낸다
  if [ "$(state_get ROUTE_DEFAULT)" != "yes" ]; then
    aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
    state_set ROUTE_DEFAULT yes
    log "경로 추가: 0.0.0.0/0 → $IGW_ID"
  fi
  if [ -z "$(state_get RT_ASSOC_ID)" ]; then
    local assoc
    assoc="$(aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" \
      --query AssociationId --output text)"
    expect_id rtbassoc "$assoc" "Route Table 연결"
    state_set RT_ASSOC_ID "$assoc"
    log "Route Table 연결: $RT_ID ↔ $SUBNET_ID"
  fi
}

step_sg() {
  CURRENT_STEP="Security Group"
  SG_ID="$(state_get SG_ID)"
  if [ -z "$SG_ID" ]; then
    SG_ID="$(aws ec2 create-security-group --group-name "$PROJECT-web-sg" \
      --description "B3-1 web: HTTP any, SSH my IP" --vpc-id "$VPC_ID" \
      --tag-specifications "$(tag_spec security-group "$PROJECT-web-sg")" \
      --query GroupId --output text)"
    expect_id sg "$SG_ID" "Security Group"
    state_set SG_ID "$SG_ID"
    log "Security Group 생성: $SG_ID"
    wait_exists "Security Group $SG_ID" -- aws ec2 describe-security-groups --group-ids "$SG_ID"
  else
    log "Security Group 재사용: $SG_ID"
  fi
  if [ "$(state_get SG_INGRESS)" != "yes" ]; then
    # 필요한 두 포트만 연다. 80은 누구나(웹), 22는 내 IP 한 개(/32)만
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
      'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]' \
      "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=SSH-my-ip}]" > /dev/null
    state_set SG_INGRESS yes
    state_set SSH_CIDR "${MY_IP}/32"
    log "인바운드 허용: 80/tcp ← 0.0.0.0/0, 22/tcp ← ${MY_IP}/32"
  elif [ "$(state_get SSH_CIDR)" != "${MY_IP}/32" ]; then
    warn "SSH 허용 IP($(state_get SSH_CIDR))가 현재 IP(${MY_IP}/32)와 다릅니다. SSH가 막히면 docs/troubleshooting.md의 'SSH 허용 IP 갱신'을 따르세요."
  fi
}

step_keypair() {
  CURRENT_STEP="키페어"
  KEY_NAME="$PROJECT-key"
  local pem="$STATE_DIR/$KEY_NAME.pem" tmp
  if [ -n "$(state_get KEY_NAME)" ]; then
    if [ ! -f "$pem" ]; then
      printf '[ERROR] 키페어 %s의 개인키 파일(state/%s.pem)이 없습니다. 개인키는 다시 받을 수 없으므로 ./cleanup.sh로 정리한 뒤 다시 배포하세요.\n' "$KEY_NAME" "$KEY_NAME" >&2
      return 1
    fi
    log "키페어 재사용: $KEY_NAME"
    return 0
  fi
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # mktemp는 0600으로 만든다. 개인키가 잠시라도 다른 사용자에게 읽히지 않게 한다
  tmp="$(mktemp "$STATE_DIR/.key.XXXXXX")"
  if ! aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
    --tag-specifications "$(tag_spec key-pair "$KEY_NAME")" \
    --query KeyMaterial --output text > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$pem"
  chmod 400 "$pem"
  state_set KEY_NAME "$KEY_NAME"
  log "키페어 생성: $KEY_NAME → state/$KEY_NAME.pem (권한 400, 재발급 불가 — 보관 주의)"
}

step_ami() {
  CURRENT_STEP="AMI 조회"
  AMI_ID="$(state_get AMI_ID)"
  if [ -n "$AMI_ID" ]; then
    log "AMI 재사용: $AMI_ID"
    return 0
  fi
  local archs deb_arch
  # t2.micro는 i386과 x86_64를 함께 돌려주므로 첫 값이 아니라 포함 여부로 판단한다
  archs="$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output text)"
  archs=" $(printf '%s' "$archs" | tr '\t\n' '  ') "
  case "$archs" in
    *" x86_64 "*) deb_arch="amd64" ;;
    *" arm64 "*) deb_arch="arm64" ;;
    *)
      printf '[ERROR] %s의 CPU 아키텍처를 알 수 없습니다: %s\n' "$INSTANCE_TYPE" "$archs" >&2
      return 1
      ;;
  esac
  AMI_ID="$(aws ec2 describe-images --owners "$UBUNTU_OWNER" \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${deb_arch}-server-*" Name=state,Values=available \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)"
  expect_id ami "$AMI_ID" "Ubuntu 24.04 AMI"
  state_set AMI_ID "$AMI_ID"
  log "AMI: $AMI_ID (Ubuntu 24.04 LTS $deb_arch, Canonical 최신)"
}

step_instance() {
  CURRENT_STEP="EC2 인스턴스"
  INSTANCE_ID="$(state_get INSTANCE_ID)"
  if [ -z "$INSTANCE_ID" ]; then
    step_ami
    CURRENT_STEP="EC2 인스턴스"
    INSTANCE_ID="$(aws ec2 run-instances \
      --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
      --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
      --user-data "file://$ROOT_DIR/server/user-data.sh" \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=8,VolumeType=gp3,DeleteOnTermination=true}' \
      --metadata-options HttpTokens=required,HttpEndpoint=enabled \
      --tag-specifications "$(tag_spec instance "$PROJECT-web")" "$(tag_spec volume "$PROJECT-root")" \
      --count 1 --query 'Instances[0].InstanceId' --output text)"
    expect_id i "$INSTANCE_ID" "EC2 인스턴스"
    state_set INSTANCE_ID "$INSTANCE_ID"
    log "EC2 생성: $INSTANCE_ID ($INSTANCE_TYPE, gp3 8GiB, IMDSv2)"
  else
    log "EC2 재사용: $INSTANCE_ID"
  fi
  log "인스턴스가 running이 될 때까지 기다립니다..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  if ! is_ipv4 "$PUBLIC_IP"; then
    printf '[ERROR] 인스턴스에 퍼블릭 IP가 없습니다(값: %s). 서브넷의 퍼블릭 IP 자동 할당을 확인하세요.\n' "$PUBLIC_IP" >&2
    return 1
  fi
  state_set PUBLIC_IP "$PUBLIC_IP"
  log "퍼블릭 IP: $PUBLIC_IP"
}

step_evidence() {
  CURRENT_STEP="증거 수집"
  local f
  AMI_ID="${AMI_ID:-$(state_get AMI_ID)}"
  f=01-network.txt
  evidence_begin "$f" "네트워크 구성 — VPC / Public Subnet / Route Table / Internet Gateway"
  record "$f" -- aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --output table > /dev/null || warn "$f 일부 수집 실패"
  record "$f" -- aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --output table > /dev/null || warn "$f 일부 수집 실패"
  record "$f" -- aws ec2 describe-route-tables --route-table-ids "$RT_ID" --output table > /dev/null || warn "$f 일부 수집 실패"
  record "$f" -- aws ec2 describe-internet-gateways --internet-gateway-ids "$IGW_ID" --output table > /dev/null || warn "$f 일부 수집 실패"

  f=02-security-group.txt
  evidence_begin "$f" "보안 그룹 — 인바운드 80(0.0.0.0/0)·22(내 IP/32)만 허용"
  record "$f" -- aws ec2 describe-security-groups --group-ids "$SG_ID" --output table > /dev/null || warn "$f 수집 실패"

  f=03-instance.txt
  evidence_begin "$f" "EC2 인스턴스 — 유형·상태·퍼블릭 IP·서브넷·IMDSv2, AMI, 루트 볼륨"
  record "$f" -- aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{Id:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,Subnet:SubnetId,Az:Placement.AvailabilityZone,Ami:ImageId,Imds:MetadataOptions.HttpTokens}' \
    --output table > /dev/null || warn "$f 일부 수집 실패"
  record "$f" -- aws ec2 describe-images --image-ids "$AMI_ID" \
    --query 'Images[0].{Id:ImageId,Name:Name,Owner:OwnerId}' --output table > /dev/null || warn "$f 일부 수집 실패"
  record "$f" -- aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" \
    --query 'Volumes[].{Id:VolumeId,SizeGiB:Size,Type:VolumeType,DeleteOnTermination:Attachments[0].DeleteOnTermination}' \
    --output table > /dev/null || warn "$f 일부 수집 실패"
  log "증거 저장: evidence/aws/01-network.txt, 02-security-group.txt, 03-instance.txt"
}

print_summary() {
  cat << EOF

==================== 배포 완료 ====================
 헬스체크 (방식 B)   http://$PUBLIC_IP/health   ← README '접속 정보'에 적을 주소
 웹 페이지 (방식 A)  http://$PUBLIC_IP/
 SSH                 ssh -i state/$KEY_NAME.pem ubuntu@$PUBLIC_IP
 증거 파일           evidence/aws/00-identity.txt ~ 04-verify.txt
 할 일               브라우저로 /health 화면 캡처 → docs/screenshots/
 정리 (실습 후 필수)  ./cleanup.sh
====================================================
EOF
}

main() {
  local preflight_only=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --preflight-only) preflight_only=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "알 수 없는 옵션: $1 (./deploy.sh --help)" ;;
    esac
    shift
  done
  trap 'on_error "$?" "$BASH_COMMAND"' ERR

  CURRENT_STEP="사전 점검"
  preflight
  check_free_tier
  if [ "$preflight_only" = 1 ]; then
    log "사전 점검 완료 (--preflight-only). 리소스는 만들지 않았습니다."
    exit 0
  fi

  step_vpc
  step_subnet
  step_igw
  step_route
  step_sg
  step_keypair
  step_instance
  step_evidence

  CURRENT_STEP="외부 접속 검증"
  if ! "$SCRIPT_DIR/verify.sh" --wait; then
    die "외부 접속 검증에 실패했습니다. 리소스는 남아 있습니다. 잠시 뒤 ./verify.sh --wait로 다시 확인하고, 계속 실패하면 docs/troubleshooting.md의 점검 순서(라우팅 → SG → 퍼블릭 IP → 프로세스·로그)를 따르세요. 정리는 ./cleanup.sh"
  fi
  print_summary
}

main "$@"
