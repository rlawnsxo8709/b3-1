#!/usr/bin/env bash
# B3-1 정리 — 만든 순서의 반대로 지우고, Project 태그로 다시 조회해 남은 리소스가 0건인지 확인한다.
#   EC2 종료 → 종료 대기 → 남은 EBS → EIP 해제 → SG → Route Table 연결 해제·삭제
#   → IGW 분리·삭제 → Subnet → VPC → 키페어(+ 로컬 pem·known_hosts)
# 리소스 ID는 state/resources.env 값과 Project 태그 조회 결과를 합쳐 쓴다(상태 파일을 잃어도 태그로 찾는다).
# 한 단계가 실패해도 경고만 남기고 다음 단계로 간다. 남은 리소스나 실패가 있으면 종료 코드 1.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 빈 배열은 ${arr[@]+"${arr[@]}"}로 펼친다. bash 4.0~4.3은 set -u에서 빈 "${arr[@]}"를 오류로 본다
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/awscli.sh
source "$SCRIPT_DIR/lib/awscli.sh"

EVIDENCE="05-cleanup.txt"
RETRIES="${CLEANUP_RETRIES:-12}"
RETRY_SLEEP="${CLEANUP_RETRY_SLEEP:-10}"
FAILED_STEPS=()
LEFTOVERS=()
LAST_OK=0
TAG_FILTER=""

usage() {
  cat << 'EOF'
사용법: ./cleanup.sh

  state/resources.env와 Project 태그(.env의 PROJECT, 기본 b3-1)로 찾은 리소스를 역순으로 삭제하고
  잔여 리소스를 다시 조회해 evidence/aws/05-cleanup.txt에 남긴다. 여러 번 실행해도 안전하다.
EOF
}

on_error() {
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    return 0
  fi
  printf '[ERROR] 예상하지 못한 오류(종료 코드 %s): %s\n' "$1" "${2:0:300}" >&2
  die "정리가 중간에 멈췄습니다. 원인을 확인한 뒤 ./cleanup.sh를 다시 실행하세요(여러 번 실행해도 안전합니다)."
}

# ids_of 상태키 -- aws ... --output text : 상태 파일 값과 조회 결과를 합쳐 중복 없이 한 줄에 하나씩 출력한다
ids_of() {
  local key="$1" found=""
  shift 2
  found="$("$@" 2> /dev/null)" || {
    warn "조회 실패(건너뜀): $*"
    found=""
  }
  printf '%s %s\n' "$(state_get "$key")" "$found" | tr -s '[:blank:]' '\n' | grep -v -e '^$' -e '^None$' | sort -u || true
}

# try 설명 -- 명령... : 실행하고 결과를 05-cleanup에 남긴다.
#  이미 없는 리소스(NotFound·NotAttached)는 성공으로 본다.
#  의존 리소스가 아직 정리 중(DependencyViolation)이면 잠시 뒤 다시 시도한다(인스턴스 종료 직후 ENI 해제 지연 등).
#  그래도 실패하면 경고만 남기고 LAST_OK=0으로 표시한 뒤 다음 단계로 간다
try() {
  local desc="$1" out rc attempt
  shift 2
  LAST_OK=0
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    rc=0
    out="$(record "$EVIDENCE" -- "$@")" || rc=$?
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    if [ "$rc" -eq 0 ]; then
      log "완료: $desc"
      evidence_note "$EVIDENCE" "→ 완료: $desc"
      LAST_OK=1
      return 0
    fi
    if [[ "$out" == *NotFound* || "$out" == *NotAttached* ]]; then
      log "이미 없음: $desc"
      evidence_note "$EVIDENCE" "→ 이미 없음: $desc"
      LAST_OK=1
      return 0
    fi
    if [[ "$out" == *DependencyViolation* ]] && [ "$attempt" -lt "$RETRIES" ]; then
      log "아직 연결된 리소스가 정리 중입니다. ${RETRY_SLEEP}초 뒤 다시 시도합니다(${attempt}/${RETRIES}): $desc"
      sleep "$RETRY_SLEEP"
      continue
    fi
    break
  done
  warn "실패: $desc — 다음 단계로 넘어갑니다"
  evidence_note "$EVIDENCE" "→ 실패: $desc"
  FAILED_STEPS+=("$desc")
  return 0
}

section() {
  log "── $1"
  evidence_note "$EVIDENCE" ""
  evidence_note "$EVIDENCE" "## $1"
}

clean_instances() {
  section "1. EC2 인스턴스 종료"
  local ids=() eips=()
  mapfile -t ids < <(ids_of INSTANCE_ID -- aws ec2 describe-instances \
    --filters "$TAG_FILTER" Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
    return 0
  fi
  # 인스턴스에 붙은 EIP는 종료되면 연결이 풀린 채 남아 과금되므로 미리 찾아 둔다
  mapfile -t eips < <(aws ec2 describe-addresses \
    --filters "Name=instance-id,Values=$(IFS=,; echo "${ids[*]}")" \
    --query 'Addresses[].AllocationId' --output text 2> /dev/null | tr '\t' '\n' | grep -v -e '^$' -e '^None$' || true)
  EXTRA_EIPS=(${eips[@]+"${eips[@]}"})
  # 인스턴스마다 따로 부른다. 여러 ID를 한 번에 넘기면 하나만 이미 없어도(NotFound) 호출 전체가 실패해
  # 나머지가 살아 있는데도 "이미 없음"으로 오판한다
  local id
  for id in ${ids[@]+"${ids[@]}"}; do
    try "EC2 종료 요청 $id" -- aws ec2 terminate-instances --instance-ids "$id"
  done
  # 종료 요청을 모두 보낸 뒤 하나씩 기다린다(종료는 동시에 진행된다)
  for id in ${ids[@]+"${ids[@]}"}; do
    try "EC2 terminated 대기 $id" -- aws ec2 wait instance-terminated --instance-ids "$id"
  done
}

clean_volumes() {
  section "2. 남은 EBS 볼륨 삭제 (루트 볼륨은 종료와 함께 삭제됨)"
  local ids=() v
  mapfile -t ids < <(ids_of - -- aws ec2 describe-volumes \
    --filters "$TAG_FILTER" Name=status,Values=available \
    --query 'Volumes[].VolumeId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for v in ${ids[@]+"${ids[@]}"}; do
    try "EBS 삭제 $v" -- aws ec2 delete-volume --volume-id "$v"
  done
}

clean_addresses() {
  section "3. Elastic IP 해제 (이 스크립트는 만들지 않지만 수동 생성분 대비)"
  local ids=() a assoc
  mapfile -t ids < <({
    ids_of - -- aws ec2 describe-addresses --filters "$TAG_FILTER" --query 'Addresses[].AllocationId' --output text
    printf '%s\n' ${EXTRA_EIPS[@]+"${EXTRA_EIPS[@]}"}
  } | grep -v '^$' | sort -u || true)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for a in ${ids[@]+"${ids[@]}"}; do
    assoc="$(aws ec2 describe-addresses --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2> /dev/null)" || assoc=""
    if [ -n "$assoc" ] && [ "$assoc" != "None" ]; then
      try "EIP 연결 해제 $a" -- aws ec2 disassociate-address --association-id "$assoc"
    fi
    try "EIP 해제 $a" -- aws ec2 release-address --allocation-id "$a"
  done
}

clean_security_groups() {
  section "4. Security Group 삭제"
  local ids=() g
  mapfile -t ids < <(ids_of SG_ID -- aws ec2 describe-security-groups \
    --filters "$TAG_FILTER" --query 'SecurityGroups[].GroupId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for g in ${ids[@]+"${ids[@]}"}; do
    try "SG 삭제 $g" -- aws ec2 delete-security-group --group-id "$g"
  done
}

clean_route_tables() {
  section "5. Route Table 연결 해제 → 삭제"
  local ids=() rt assocs=() a
  mapfile -t ids < <(ids_of RT_ID -- aws ec2 describe-route-tables \
    --filters "$TAG_FILTER" --query 'RouteTables[].RouteTableId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for rt in ${ids[@]+"${ids[@]}"}; do
    # 메인 라우트 테이블 연결(Main=true)은 해제할 수 없으므로 서브넷 연결만 고른다
    # shellcheck disable=SC2016 # 백틱은 셸 치환이 아니라 JMESPath 리터럴이다
    mapfile -t assocs < <({
      if [ "$rt" = "$(state_get RT_ID)" ]; then state_get RT_ASSOC_ID; fi
      aws ec2 describe-route-tables --route-table-ids "$rt" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' \
        --output text 2> /dev/null || true
    } | tr '\t' '\n' | grep -v -e '^$' -e '^None$' | sort -u || true)
    for a in ${assocs[@]+"${assocs[@]}"}; do
      try "Route Table 연결 해제 $a" -- aws ec2 disassociate-route-table --association-id "$a"
    done
    try "Route Table 삭제 $rt" -- aws ec2 delete-route-table --route-table-id "$rt"
  done
}

clean_internet_gateways() {
  section "6. Internet Gateway 분리 → 삭제"
  local ids=() igw vpcs=() v
  mapfile -t ids < <(ids_of IGW_ID -- aws ec2 describe-internet-gateways \
    --filters "$TAG_FILTER" --query 'InternetGateways[].InternetGatewayId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for igw in ${ids[@]+"${ids[@]}"}; do
    mapfile -t vpcs < <(aws ec2 describe-internet-gateways --internet-gateway-ids "$igw" \
      --query 'InternetGateways[0].Attachments[].VpcId' --output text 2> /dev/null |
      tr '\t' '\n' | grep -v -e '^$' -e '^None$' || true)
    for v in ${vpcs[@]+"${vpcs[@]}"}; do
      try "IGW 분리 $igw ← $v" -- aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$v"
    done
    try "IGW 삭제 $igw" -- aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done
}

clean_subnets_and_vpcs() {
  section "7. Subnet → VPC 삭제"
  local ids=() s v
  mapfile -t ids < <(ids_of SUBNET_ID -- aws ec2 describe-subnets \
    --filters "$TAG_FILTER" --query 'Subnets[].SubnetId' --output text)
  for s in ${ids[@]+"${ids[@]}"}; do
    try "Subnet 삭제 $s" -- aws ec2 delete-subnet --subnet-id "$s"
  done
  mapfile -t ids < <(ids_of VPC_ID -- aws ec2 describe-vpcs \
    --filters "$TAG_FILTER" --query 'Vpcs[].VpcId' --output text)
  if [ "${#ids[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ VPC 대상 없음"
  fi
  for v in ${ids[@]+"${ids[@]}"}; do
    try "VPC 삭제 $v" -- aws ec2 delete-vpc --vpc-id "$v"
  done
}

clean_key_pairs() {
  section "8. 키페어 삭제 (+ 로컬 개인키·known_hosts)"
  local names=() k
  mapfile -t names < <(ids_of KEY_NAME -- aws ec2 describe-key-pairs \
    --filters "$TAG_FILTER" --query 'KeyPairs[].KeyName' --output text)
  if [ "${#names[@]}" -eq 0 ]; then
    evidence_note "$EVIDENCE" "→ 대상 없음"
  fi
  for k in ${names[@]+"${names[@]}"}; do
    try "키페어 삭제 $k" -- aws ec2 delete-key-pair --key-name "$k"
    # AWS 쪽 키페어가 지워졌을 때만 개인키를 지운다(남아 있다면 개인키가 아직 쓸모 있다)
    if [ "$LAST_OK" = 1 ]; then
      rm -f "$STATE_DIR/$k.pem"
    fi
  done
  rm -f "$STATE_DIR/known_hosts"
}

# check_zero 항목 -- aws ... --output text : 결과가 0건이어야 한다. 아니면 LEFTOVERS에 추가
check_zero() {
  local label="$1" out rc=0 n
  shift 2
  out="$(record "$EVIDENCE" -- "$@")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    evidence_note "$EVIDENCE" "→ ${label}: 조회 실패"
    LEFTOVERS+=("${label}: 조회 실패(콘솔에서 확인 필요)")
    return 0
  fi
  out="$(printf '%s' "$out" | tr '\t\n' '  ' | sed 's/None//g')"
  n="$(printf '%s' "$out" | wc -w)"
  n=$((n))
  evidence_note "$EVIDENCE" "→ ${label}: ${n}건"
  printf '  %-28s %s건\n' "$label" "$n"
  if [ "$n" -gt 0 ]; then
    LEFTOVERS+=("${label}: ${out}")
  fi
}

verify_clean() {
  section "정리 후 잔여 리소스 조회 — Project=$PROJECT 태그, 모두 0건이어야 한다"
  check_zero "EC2 (terminated 제외)" -- aws ec2 describe-instances \
    --filters "$TAG_FILTER" Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text
  # shellcheck disable=SC2016 # 백틱은 셸 치환이 아니라 JMESPath 리터럴이다
  check_zero "EBS 볼륨" -- aws ec2 describe-volumes --filters "$TAG_FILTER" \
    --query 'Volumes[?State!=`deleting`].VolumeId' --output text
  check_zero "Elastic IP" -- aws ec2 describe-addresses --filters "$TAG_FILTER" \
    --query 'Addresses[].AllocationId' --output text
  check_zero "Internet Gateway" -- aws ec2 describe-internet-gateways --filters "$TAG_FILTER" \
    --query 'InternetGateways[].InternetGatewayId' --output text
  check_zero "VPC" -- aws ec2 describe-vpcs --filters "$TAG_FILTER" --query 'Vpcs[].VpcId' --output text
  check_zero "Subnet" -- aws ec2 describe-subnets --filters "$TAG_FILTER" --query 'Subnets[].SubnetId' --output text
  check_zero "Route Table" -- aws ec2 describe-route-tables --filters "$TAG_FILTER" \
    --query 'RouteTables[].RouteTableId' --output text
  check_zero "Security Group" -- aws ec2 describe-security-groups --filters "$TAG_FILTER" \
    --query 'SecurityGroups[].GroupId' --output text
  check_zero "Key Pair" -- aws ec2 describe-key-pairs --filters "$TAG_FILTER" --query 'KeyPairs[].KeyName' --output text

  # 태그가 없는 수동 생성분까지 보려고 리전 전체의 대표 과금 리소스를 한 번 더 본다(판정에는 쓰지 않는다)
  evidence_note "$EVIDENCE" ""
  evidence_note "$EVIDENCE" "## 참고: 리전 전체 조회 (태그 무관, 판정 제외 — 다른 실습 리소스가 보이면 직접 확인)"
  record "$EVIDENCE" -- aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text > /dev/null || true
  record "$EVIDENCE" -- aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text > /dev/null || true
  record "$EVIDENCE" -- aws ec2 describe-volumes --filters Name=status,Values=available \
    --query 'Volumes[].VolumeId' --output text > /dev/null || true
  # shellcheck disable=SC2016 # 백틱은 셸 치환이 아니라 JMESPath 리터럴이다
  record "$EVIDENCE" -- aws ec2 describe-nat-gateways \
    --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text > /dev/null || true
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      *) die "알 수 없는 옵션: $1 (./cleanup.sh --help)" ;;
    esac
  done
  trap 'on_error "$?" "$BASH_COMMAND"' ERR

  preflight --no-ip
  TAG_FILTER="Name=tag:Project,Values=$PROJECT"
  EXTRA_EIPS=()
  evidence_begin "$EVIDENCE" "리소스 정리 — 삭제 작업과 잔여 리소스 조회 (cleanup.sh)"

  clean_instances
  clean_volumes
  clean_addresses
  clean_security_groups
  clean_route_tables
  clean_internet_gateways
  clean_subnets_and_vpcs
  clean_key_pairs
  verify_clean

  evidence_note "$EVIDENCE" ""
  if [ "${#LEFTOVERS[@]}" -eq 0 ] && [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
    if [ -f "$STATE_FILE" ]; then
      mv "$STATE_FILE" "$STATE_DIR/resources.cleaned-$(date '+%Y%m%d-%H%M%S').env"
    fi
    evidence_note "$EVIDENCE" "종합: Project=$PROJECT 태그 잔여 리소스 0건 — 정리 완료"
    log "정리 완료: 잔여 리소스 0건. 기록: evidence/aws/$EVIDENCE"
    log "마지막으로 Billing 콘솔에서 과금 항목을 확인하세요(docs/cleanup-checklist.md)."
    return 0
  fi

  local item
  if [ "${#LEFTOVERS[@]}" -gt 0 ]; then
    warn "남은 리소스가 있습니다:"
    for item in ${LEFTOVERS[@]+"${LEFTOVERS[@]}"}; do warn "  - $item"; done
  fi
  if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
    warn "실패한 단계:"
    for item in ${FAILED_STEPS[@]+"${FAILED_STEPS[@]}"}; do warn "  - $item"; done
  fi
  evidence_note "$EVIDENCE" "종합: 남은 리소스 ${#LEFTOVERS[@]}종 / 실패 단계 ${#FAILED_STEPS[@]}개 — 정리 미완료"
  die "정리를 마치지 못했습니다(남은 리소스 ${#LEFTOVERS[@]}종, 실패 단계 ${#FAILED_STEPS[@]}개). 잠시 뒤 ./cleanup.sh를 다시 실행하고, 그래도 남으면 콘솔에서 확인하세요. 상태 파일은 그대로 둡니다."
}

main "$@"
