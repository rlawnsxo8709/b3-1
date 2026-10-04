# b3-1 수행 계획 — AWS VPC·EC2·Nginx 웹 서비스 배포 자동화

> 작성일: 2026-10-04 / 대상: B3-1 「클라우드 웹 서비스 인프라 구축」 미션

## 1. 목표와 판단 기준

콘솔에서 손으로 클릭하는 대신 **AWS CLI를 부르는 Bash 스크립트**로 인프라를 만든다.
사용자는 `.env`에 IAM 사용자 액세스 키 두 줄만 넣고 아래 세 명령을 실행한다.

```bash
./deploy.sh    # 사전 점검 → 네트워크 → SG → 키페어 → EC2 → 대기 → 외부 검증 → 증거 저장
./verify.sh    # (재)검증과 증거 재수집
./cleanup.sh   # 역순 삭제 → 잔여 리소스 0건 확인 → 증거 저장
```

스크립트로 만드는 이유는 세 가지다.

1. **재현성** — 같은 명령이 같은 구성을 만든다. 손으로 빠뜨리기 쉬운 "라우트 추가", "SSH 소스 제한"이 코드에 고정된다.
2. **증거** — 실행한 명령과 AWS 응답이 `evidence/aws/*.txt`에 그대로 남는다. 보고서의 근거가 된다.
3. **정리** — 만든 것을 기록해 두었다가 역순으로 지운다. 과금 사고를 막는 가장 확실한 방법이다.

## 2. 생성 리소스

모든 리소스는 서울 리전(`ap-northeast-2`)에 만들고, `Name`과 `Project=b3-1` 태그를 단다.

| 리소스 | Name 태그 | 설정 |
|---|---|---|
| VPC | `b3-1-vpc` | `10.0.0.0/16`, DNS 호스트 이름 사용 |
| Subnet | `b3-1-public-subnet` | `10.0.1.0/24`, `ap-northeast-2a`, 퍼블릭 IP 자동 할당 |
| Internet Gateway | `b3-1-igw` | VPC에 연결 |
| Route Table | `b3-1-public-rt` | `10.0.0.0/16 → local`(자동), `0.0.0.0/0 → IGW`, 서브넷에 명시적 연결 |
| Security Group | `b3-1-web-sg` | 인바운드 80/tcp `0.0.0.0/0`, 22/tcp `내 IP/32`만. 아웃바운드는 기본(전체 허용) |
| Key Pair | `b3-1-key` | ed25519, 개인키는 `state/b3-1-key.pem`(권한 400) |
| EC2 | `b3-1-web` | `t3.micro`, Ubuntu 24.04 LTS, IMDSv2 강제, user-data로 Nginx 설치 |
| EBS | `b3-1-root` | gp3 8GiB, 인스턴스 종료 시 함께 삭제 |

## 3. 스크립트 흐름

```
deploy.sh
 ├─ preflight ─ .env 로드 → 키 확인 → aws CLI 확인(없으면 ./.tools에 설치)
 │              → sts get-caller-identity → 루트면 중단 → 내 IP 확인(IPv4 아니면 중단)
 ├─ step_vpc ──────── create-vpc → modify-vpc-attribute(DNS)
 ├─ step_subnet ───── create-subnet → modify-subnet-attribute(--map-public-ip-on-launch)
 ├─ step_igw ──────── create-internet-gateway → attach-internet-gateway
 ├─ step_route ────── create-route-table → create-route 0.0.0.0/0→IGW → associate-route-table
 ├─ step_sg ───────── create-security-group → authorize-security-group-ingress(80 any, 22 my-ip/32)
 ├─ step_keypair ──── create-key-pair → state/b3-1-key.pem (400)
 ├─ step_ami ──────── describe-instance-types(아키텍처) → describe-images(Canonical 최신 24.04)
 ├─ step_instance ─── run-instances(user-data, gp3 8GiB, IMDSv2) → wait instance-running → 퍼블릭 IP
 ├─ step_evidence ─── evidence/aws/01-network, 02-security-group, 03-instance
 └─ verify.sh --wait ─ /health 200까지 대기 → 외부 /health·/ → SSH(nginx·localhost·아웃바운드) → 04-verify

cleanup.sh
 인스턴스 종료·대기 → 남은 EBS → EIP → SG → RT 연결 해제·삭제 → IGW 분리·삭제 → Subnet → VPC → 키페어
 → 태그로 잔여 리소스 조회(0건이어야 함) → 05-cleanup
```

각 단계는 만든 리소스 ID를 즉시 `state/resources.env`에 적는다. 다시 실행하면 이미 있는 단계는 건너뛴다.

## 4. 핵심 설계 결정

| 결정 | 선택 | 이유 |
|---|---|---|
| 리소스 추적 | **상태 파일 + 태그** 둘 다 | 상태 파일은 빠르고 정확하다. 하지만 지워지거나 다른 PC에서 정리할 때는 쓸 수 없다. 그때는 `Project=b3-1` 태그로 찾는다. 하나만 쓰면 둘 중 한 상황에서 리소스가 남는다 |
| 외부 접속 검증 | **방식 B (`GET /health`)** | 응답 코드(200)와 본문(`OK`)이 고정이라 스크립트가 PASS/FAIL을 판정할 수 있다. 사람이 화면을 보고 판단하는 A보다 증거가 명확하다. 같은 서버가 `/`도 제공하므로 A도 함께 확인된다 |
| Elastic IP | **쓰지 않는다** | 서브넷의 퍼블릭 IP 자동 할당으로 충분하다. EIP는 연결이 끊긴 채 남으면 과금되고, 정리 단계도 하나 늘어난다. 정리 스크립트는 혹시 수동으로 만든 EIP까지 대비해 해제한다 |
| 인스턴스 메타데이터 | **IMDSv2 강제** (`HttpTokens=required`) | 토큰 없는 IMDSv1 요청을 막아 SSRF로 자격 증명이 새는 경로를 닫는다. 이 실습은 메타데이터를 쓰지 않으므로 잃는 것이 없다 |
| AMI 선택 | Canonical 소유자 ID `099720109477`로 최신 Ubuntu 24.04 조회 | AMI ID는 리전·시점마다 다르다. 하드코딩하면 오래된 이미지를 쓰게 된다. 소유자 ID로 거르면 이름만 흉내 낸 타인의 AMI를 피할 수 있다 |
| SSH 소스 | `MY_IP/32`, 자동 감지 실패 시 **중단** | 감지에 실패했다고 `0.0.0.0/0`으로 넓히면 미션 제약 위반이자 실제 사고 원인이다. 사용자가 `.env`에 직접 넣게 안내한다 |
| 루트 계정 | 키가 루트이면 **즉시 중단** | 미션 제약. `sts get-caller-identity`의 ARN이 `:root`로 끝나는지 본다 |
| aws CLI | 없으면 `./.tools`에 v2를 sudo 없이 설치 | "키만 넣으면 되도록". 시스템을 건드리지 않고 프로젝트 안에만 설치한다 |
| 테스트 | `PATH`에 가짜 `aws`·`curl`·`ssh`를 넣은 Bash 테스트 | 실제 AWS 없이 호출 순서·인자·상태 파일·역순 삭제를 검증한다 |
| 서버 설정 검증 | Docker `ubuntu:24.04`에서 **같은 user-data.sh** 실행 (로컬 리허설) | EC2에서 돌 스크립트를 미리 실제로 돌려 본다. 단, 이것은 AWS가 아니므로 라벨을 붙여 구분한다 |

## 5. 검증 방법

1. **가짜 명령 테스트** (`bash tests/run.sh`) — 테스트를 먼저 작성하고 실패를 확인한 뒤 구현한다.
2. **로컬 리허설** (`bash local/rehearsal.sh`) — 컨테이너 안팎에서 `/`, `/health`가 200인지 확인한다.
3. **트러블슈팅 재현** (`bash local/repro-port-blocked.sh`) — 포트를 열지 않은 상태를 일부러 만들어 가설 → 검증 → 조치를 기록한다.
4. **정적 검사** — `bash -n`, shellcheck(Docker 이미지), IAM 정책 JSON 검사.
5. **AWS 실행** — 사용자가 키를 넣고 직접 실행한다. 결과는 `evidence/aws/`에 자동 저장된다.

## 6. 하지 않는 것

- 보너스 과제(HTTPS, Docker로 배포)는 하지 않는다.
- 실제 AWS 호출은 이 저장소 작성 과정에서 하지 않는다. 퍼블릭 IP·스크린샷·Billing 결과는 사용자가 실행 후 채운다.

## 7. 진행 결과 (2026-10-04)

| 단계 | 결과 |
|---|---|
| 가짜 명령 테스트 | `bash tests/run.sh` → `PASS 42 / FAIL 0`. 묶음마다 테스트를 먼저 쓰고 실패(RED)를 확인한 뒤 구현했다 |
| 로컬 리허설 | `ubuntu:24.04` 컨테이너에서 같은 `user-data.sh` 실행 → 컨테이너 안 `/`·`/health` 200, 호스트 `/health`·`/` 200 (`evidence/local/rehearsal.txt`) |
| 트러블슈팅 재현 | 포트 게시 없는 컨테이너: 호스트 `000` → 가설 3개 검증 → 포트 게시 후 `200` (`evidence/local/troubleshooting-port.txt`) |
| 정적 검사 | `bash -n` 전체 통과, shellcheck(진입 스크립트·lib·local·user-data·IAM 도우미) 경고 0, IAM JSON 유효 |
| AWS 실행 | ⏳ 사용자 몫 — README "AWS에서 직접 할 일 3단계" |

### 계획을 구현하며 바꾼 점

| 항목 | 처음 계획 | 바꾼 내용 | 이유 |
|---|---|---|---|
| AMI 아키텍처 판별 | `SupportedArchitectures[0]` | 목록에 `x86_64`/`arm64`가 **포함**됐는지로 판단 | `t2.micro`는 `["i386","x86_64"]`를 돌려줘 첫 값만 보면 i386으로 오판한다 |
| 정리 대상 ID | 상태 파일, 없으면 태그 | 상태 파일 **과** 태그 조회의 합집합 | 상태 파일이 일부만 남은 경우(중간 실패)나 이전 실행의 잔여분도 함께 지운다 |
| 정리 재시도 | 실패하면 경고 | `DependencyViolation`일 때만 10초 간격 최대 12회 재시도, `NotFound`는 성공으로 처리 | 인스턴스 종료 직후 ENI 해제 지연으로 SG·서브넷 삭제가 일시적으로 실패한다 |
| 내 IP 감지 실패 시 정리 | (명시 없음) | `cleanup.sh`는 IP를 확인하지 않는다(`preflight --no-ip`) | IP 감지 실패 때문에 정리가 막히면 과금 위험이 커진다 |
| 증거 마스킹 | 00-identity의 계정 ID | 모든 증거 파일에서 계정 ID 가운데 4자리, 개인 IP 뒤 두 자리, 절대 경로를 가림 | 사용자가 `evidence/aws/`를 공개 저장소에 커밋하기 때문 |
| 리전·유형·태그 값 검증 | (명시 없음) | `.env`의 리전이 서울이 아니거나 유형이 t2/t3.micro가 아니면 AWS 호출 전에 중단 | 미션 제약을 스크립트에서도 강제(IAM 정책과 이중 방어) |
| IAM 도우미 `--console` | 비밀번호 생성 + 변경 강제 | AWS 관리형 `IAMUserChangePassword`도 연결 | 첫 로그인 비밀번호 변경에는 본인 비밀번호 변경 권한이 필요하다 |
| 테스트 추가 | 계획의 16개 | 42개 — 중간 실패 후 이어하기, 스크립트의 모든 ec2 호출이 정책에 있는지, `.tools` 설치, IAM 도우미 등 | 실제 AWS에서 처음 돌 때 실패할 지점을 미리 막기 위해 |
