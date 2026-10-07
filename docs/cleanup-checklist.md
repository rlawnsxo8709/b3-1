# 리소스 정리 체크리스트 — B3-1

> 실습이 끝나면 `./cleanup.sh`를 실행하고, 아래 항목을 하나씩 확인해 체크한다.
> 근거는 `cleanup.sh`가 남기는 [`evidence/aws/05-cleanup.txt`](../evidence/aws/05-cleanup.txt)다. 이 파일은 AWS에서 실행하면 자동으로 생긴다.
> **체크박스는 아직 비어 있다 — ⏳ AWS 실행 후 체크.**
> 서버의 SQLite(`/home/ubuntu/ai_chatbot/app.db`, 앱의 가입·대화 기록)는 루트 EBS와 함께 삭제된다(별도 DB 리소스 없음). 남길 데이터가 있으면 정리 전에 `scp`로 받아 둔다.

## 정리 추적 기준

| 기준 | 내용 |
|---|---|
| 태그 | 만드는 모든 리소스에 `Project=b3-1`과 `Name=b3-1-…`을 단다(`lib/common.sh` `tag_spec`). 정리와 잔여 조회는 이 태그로 한다 |
| 이름 규칙 | `b3-1-vpc`, `b3-1-public-subnet`, `b3-1-igw`, `b3-1-public-rt`, `b3-1-web-sg`, `b3-1-key`, `b3-1-web`(EC2), `b3-1-root`(EBS) |
| 상태 파일 | `state/resources.env`에 만든 리소스 ID를 즉시 기록한다. 정리가 끝나 잔여 0건이면 `state/resources.cleaned-<시각>.env`로 옮긴다 |
| 순서 | 만든 순서의 **반대**로 지운다. 의존하는 쪽(인스턴스)을 먼저 지워야 의존받는 쪽(SG·서브넷·VPC)을 지울 수 있다 |

## 체크리스트

| # | 항목 | 확인 명령 (`--region ap-northeast-2`) | 기대 결과 | `05-cleanup.txt` 근거 위치 | 확인 |
|---|---|---|---|---|---|
| 1 | **EC2** 인스턴스 Terminated | `aws ec2 describe-instances --filters Name=tag:Project,Values=b3-1 --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text` | 모두 `terminated` (종료 후 약 1시간 목록에 보이다 사라진다) | `## 1. EC2 인스턴스 종료`의 `terminate-instances`·`wait instance-terminated` → 완료, 잔여 조회 `EC2 (terminated 제외): 0건` | ☐ ⏳ |
| 2 | **EBS** 볼륨(미사용 포함) 삭제 | `aws ec2 describe-volumes --filters Name=tag:Project,Values=b3-1 --query 'Volumes[].[VolumeId,State]' --output text`<br>`aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text` (리전 전체의 미사용 볼륨) | 빈 출력. 루트 볼륨은 `DeleteOnTermination=true`라 종료와 함께 삭제된다 | `## 2. 남은 EBS 볼륨 삭제`, 잔여 조회 `EBS 볼륨: 0건`, 참고 절의 `describe-volumes --filters Name=status,Values=available` | ☐ ⏳ |
| 3 | **Elastic IP** Release | `aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AllocationId,AssociationId]' --output text` | 빈 출력. 이 실습은 EIP를 만들지 않는다. 수동으로 만들었다면 `cleanup.sh`가 태그·인스턴스 연결로 찾아 해제한다 | `## 3. Elastic IP 해제`, 잔여 조회 `Elastic IP: 0건`, 참고 절의 `describe-addresses` | ☐ ⏳ |
| 4 | **Internet Gateway** Detach 및 삭제 | `aws ec2 describe-internet-gateways --filters Name=tag:Project,Values=b3-1 --query 'InternetGateways[].InternetGatewayId' --output text` | 빈 출력 | `## 6. Internet Gateway 분리 → 삭제`의 `detach-internet-gateway`·`delete-internet-gateway` → 완료, `Internet Gateway: 0건` | ☐ ⏳ |
| 5 | **VPC** 및 Subnet·Route Table 삭제 | `aws ec2 describe-vpcs --filters Name=tag:Project,Values=b3-1 --query 'Vpcs[].VpcId' --output text`<br>(Subnet·Route Table도 같은 필터로 `describe-subnets`·`describe-route-tables`) | 모두 빈 출력 | `## 5. Route Table 연결 해제 → 삭제`, `## 7. Subnet → VPC 삭제`, `VPC: 0건`·`Subnet: 0건`·`Route Table: 0건` | ☐ ⏳ |
| 6 | Security Group 삭제 | `aws ec2 describe-security-groups --filters Name=tag:Project,Values=b3-1 --query 'SecurityGroups[].GroupId' --output text` | 빈 출력 (VPC 기본 SG는 VPC와 함께 삭제) | `## 4. Security Group 삭제`, `Security Group: 0건` | ☐ ⏳ |
| 7 | 키페어 삭제 + 로컬 개인키 삭제 | `aws ec2 describe-key-pairs --filters Name=tag:Project,Values=b3-1 --query 'KeyPairs[].KeyName' --output text`<br>`ls state/` | 빈 출력, `state/b3-1-key.pem` 없음 | `## 8. 키페어 삭제`, `Key Pair: 0건` | ☐ ⏳ |
| 8 | (해당 없음) NAT Gateway | `` aws ec2 describe-nat-gateways --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text `` | 빈 출력 — 이 실습은 만들지 않는다(퍼블릭 서브넷만 사용) | 참고 절의 `describe-nat-gateways` | ☐ ⏳ |
| 9 | (해당 없음) ELB/ALB | EC2 콘솔 → 로드 밸런서 목록(관리자 계정으로 확인) | 없음 — 만들지 않았고, 실습 사용자에게는 ELB 권한 자체가 없다 | 해당 없음 (IAM 정책에 `elasticloadbalancing:*` 없음) | ☐ ⏳ |
| 10 | (해당 없음) RDS | RDS 콘솔 → 데이터베이스 목록(관리자 계정으로 확인) | 없음 — 만들지 않았고, 실습 사용자에게는 RDS 권한 자체가 없다 | 해당 없음 (IAM 정책에 `rds:*` 없음) | ☐ ⏳ |
| 11 | `cleanup.sh` 종합 결과 | `tail -1 evidence/aws/05-cleanup.txt` | `종합: Project=b3-1 태그 잔여 리소스 0건 — 정리 완료` | 파일 마지막 줄 | ☐ ⏳ |

### 체크 (⏳ AWS 실행 후 체크)

- [ ] 1. EC2 인스턴스 Terminated 확인
- [ ] 2. EBS 볼륨(미사용 포함) 삭제 확인
- [ ] 3. Elastic IP Release 확인 (할당하지 않았으면 0건 확인)
- [ ] 4. Internet Gateway Detach 및 삭제 확인
- [ ] 5. VPC 및 Subnet·Route Table 삭제 확인
- [ ] 6. Security Group 삭제 확인
- [ ] 7. 키페어 삭제 + `state/b3-1-key.pem` 삭제 확인
- [ ] 8. (해당 없음) NAT Gateway 0건 확인
- [ ] 9. (해당 없음) ELB/ALB 없음 확인
- [ ] 10. (해당 없음) RDS 없음 확인
- [ ] 11. `05-cleanup.txt` 마지막 줄 "잔여 리소스 0건 — 정리 완료" 확인
- [ ] 12. Billing(또는 리소스 목록) 화면 확인 → `docs/screenshots/billing.png`

`cleanup.sh`가 `남은 리소스`를 보고하고 종료 코드 1로 끝났다면, 잠시 기다린 뒤 다시 실행한다. 인스턴스가 종료된 직후에는 ENI 해제가 늦어 SG·서브넷 삭제가 실패할 수 있다. 그래도 남으면 콘솔에서 해당 ID를 직접 지운다.

## Billing 확인 절차

과금은 몇 시간 늦게 집계되므로 정리 **직후**와 **다음 날** 두 번 본다.

1. **누구로 보나** — 실습 사용자(`b3-1-operator`)에게는 결제 권한이 없다(최소권한). 결제 정보 접근이 허용된 **관리자 IAM 사용자**로 로그인한다. IAM 사용자의 결제 정보 접근은 계정 설정에서 한 번 켜 둬야 한다(루트로 1회 설정, 이후 루트는 쓰지 않음).
2. **Billing and Cost Management → 홈/청구서(Bills)** — 이번 달 `Elastic Compute Cloud` 항목을 펼쳐 `ap-northeast-2`의 인스턴스 시간, EBS, 퍼블릭 IPv4 주소 요금을 확인한다. 2024년 2월부터 퍼블릭 IPv4 주소는 시간당 과금되므로, 인스턴스를 켜 둔 시간만큼 소액이 잡힐 수 있다(프리 티어 750시간 포함 여부 확인).
3. **프리 티어(Free Tier) 페이지** — EC2 시간·EBS 사용량이 한도 안인지 본다.
4. **Cost Explorer**(선택) — 서비스별·리전별로 묶어 예상치 못한 리전·서비스 비용이 없는지 본다.
5. **예방**(권장) — Budgets에서 "제로 지출 예산(Zero spend budget)" 또는 월 1 USD 예산을 만들어 이메일 알림을 받는다.
6. **증빙** — Billing 화면 또는 리소스 목록(EC2 인스턴스 terminated 화면) 스크린샷을 `docs/screenshots/billing.png`로 저장한다. ⏳ AWS 실행 후 추가

| 확인 | 결과 |
|---|---|
| 정리 직후 Billing/리소스 목록 | ⏳ AWS 실행 후 기입 |
| 다음 날 Billing | ⏳ AWS 실행 후 기입 |
