# b3-1 수행 계획 — AWS VPC·EC2에 ai_chatbot(FastAPI) 웹 서비스 배포 자동화

> 작성일: 2026-10-04 / 개정: 2026-10-08(정적 Nginx 페이지 → ai_chatbot 배포, [8절](#8-ai_chatbot-배포로-변경-2026-10-08)) / 대상: B3-1 「클라우드 웹 서비스 인프라 구축」 미션

## 1. 목표와 판단 기준

콘솔에서 손으로 클릭하는 대신 **AWS CLI를 부르는 Bash 스크립트**로 인프라를 만든다.
사용자는 `.env`에 IAM 사용자 액세스 키 두 줄을 넣고, 배포할 앱 [ai_chatbot](https://github.com/L-jy16/ai_chatbot)(PULSE 경제 숏폼 트렌드 챗봇)의 `.env`를 준비한 뒤 아래 세 명령을 실행한다.

```bash
./deploy.sh    # 사전 점검 → 네트워크 → SG → 키페어 → EC2 → 앱 전송·설치(SSH) → 외부 검증 → 증거 저장
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
| Security Group | `b3-1-web-sg` | 인바운드 80/tcp `0.0.0.0/0`, 22/tcp `내 IP/32`만(앱 포트 8000은 열지 않음). 아웃바운드는 기본(전체 허용) |
| Key Pair | `b3-1-key` | ed25519, 개인키는 `state/b3-1-key.pem`(권한 400) |
| EC2 | `b3-1-web` | `t3.micro`, Ubuntu 24.04 LTS, IMDSv2 강제, user-data로 Nginx(80 → 127.0.0.1:8000 프록시)·python3-venv, SSH로 ai_chatbot 설치(systemd `ai-chatbot`) |
| EBS | `b3-1-root` | gp3 8GiB, 인스턴스 종료 시 함께 삭제 |

## 3. 스크립트 흐름

```
deploy.sh
 ├─ preflight ─ .env 로드 → 키 확인 → 앱 소스 확인(APP_SRC git 저장소, APP_REF에 앱 코드, APP_ENV_FILE 존재)
 │              → aws CLI 확인(없으면 ./.tools에 설치)
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
 ├─ step_app ──────── SSH·user-data 완료 대기 → git archive 소스·provision-app.sh·앱 .env scp
 │                    → sudo bash provision-app.sh(venv·.env 600·systemd) → 커밋 기록 → 03b-app
 └─ verify.sh --wait ─ /health 200까지 대기 → 외부 /health·/(303)·-L / → SSH(nginx·ai-chatbot·localhost·아웃바운드·LLM) → 04-verify

cleanup.sh
 인스턴스 종료·대기 → 남은 EBS → EIP → SG → RT 연결 해제·삭제 → IGW 분리·삭제 → Subnet → VPC → 키페어
 → 태그로 잔여 리소스 조회(0건이어야 함) → 05-cleanup
```

각 단계는 만든 리소스 ID를 즉시 `state/resources.env`에 적는다. 다시 실행하면 이미 있는 단계는 건너뛴다.

## 4. 핵심 설계 결정

| 결정 | 선택 | 이유 |
|---|---|---|
| 리소스 추적 | **상태 파일 + 태그** 둘 다 | 상태 파일은 빠르고 정확하다. 하지만 지워지거나 다른 PC에서 정리할 때는 쓸 수 없다. 그때는 `Project=b3-1` 태그로 찾는다. 하나만 쓰면 둘 중 한 상황에서 리소스가 남는다 |
| 외부 접속 검증 | **방식 B (`GET /health`)** | 응답 코드(200)와 본문(`{"status":"ok"}`)이 고정이라 스크립트가 PASS/FAIL을 판정할 수 있다. 사람이 화면을 보고 판단하는 A보다 증거가 명확하다. 이 응답은 Nginx가 아니라 앱이 돌려주므로 "Nginx → 앱"까지 살아 있음을 증명한다. 같은 주소를 브라우저로 열면 로그인 화면이라 A도 함께 확인된다 |
| 서버 구성 | **Nginx 80 → `proxy_pass http://127.0.0.1:8000`(uvicorn)** | 앱 포트 8000은 SG에도 열지 않고 127.0.0.1에만 바인딩한다(이중 차단). ai_chatbot의 `docs/DEPLOY.md`는 8000을 열라고 하지만 미션의 "필요한 포트만"에 어긋난다. `proxy_read_timeout 90s`는 LLM 응답 최대 50초를 고려한 값 |
| 앱 비밀값 전달 | **SSH(22, 내 IP)로 앱 `.env`를 파일째 scp → 서버 600** | user-data는 인스턴스 메타데이터·콘솔에 보이므로 넣지 않는다. 값은 명령줄·로그·증거에 싣지 않고 항목별 있음/비어 있음만 남긴다. `SECRET_KEY`가 비었거나 16자 미만이면 서버가 `secrets.token_hex(32)`로 만든다 |
| 앱 소스 전달 | **로컬 체크아웃의 `git archive`(커밋된 파일만)** | 추적하지 않는 `.env`·`.venv`·`app.db`가 섞이지 않고, 서버에 git·GitHub 자격 증명이 필요 없다. 배포 커밋 SHA를 기록해 같은 커밋·같은 `.env`면 재배포를 건너뛴다. 앱 코드는 `develop` 브랜치에 있어(`main`은 초기 커밋뿐) 사전 점검이 `APP_REF` 트리의 `app/main.py`를 확인한다 |
| 앱 실행 | **systemd `ai-chatbot`(User=ubuntu, Restart=always, workers 1)** | 재부팅·비정상 종료 뒤에도 다시 뜬다. SQLite라 워커는 1개 |
| `/`의 303 | **앱 코드를 고치지 않고 원 응답을 기록** | 비로그인 `/`는 `/login`으로 303이다. 검증은 원 응답(303)을 그대로 남기고 `curl -L`(200, 로그인 화면)과 `/health`(200)로 요구를 보인다 |
| Elastic IP | **쓰지 않는다** | 서브넷의 퍼블릭 IP 자동 할당으로 충분하다. EIP는 연결이 끊긴 채 남으면 과금되고, 정리 단계도 하나 늘어난다. 정리 스크립트는 혹시 수동으로 만든 EIP까지 대비해 해제한다 |
| 인스턴스 메타데이터 | **IMDSv2 강제** (`HttpTokens=required`) | 토큰 없는 IMDSv1 요청을 막아 SSRF로 자격 증명이 새는 경로를 닫는다. 이 실습은 메타데이터를 쓰지 않으므로 잃는 것이 없다 |
| AMI 선택 | Canonical 소유자 ID `099720109477`로 최신 Ubuntu 24.04 조회 | AMI ID는 리전·시점마다 다르다. 하드코딩하면 오래된 이미지를 쓰게 된다. 소유자 ID로 거르면 이름만 흉내 낸 타인의 AMI를 피할 수 있다 |
| SSH 소스 | `MY_IP/32`, 자동 감지 실패 시 **중단** | 감지에 실패했다고 `0.0.0.0/0`으로 넓히면 미션 제약 위반이자 실제 사고 원인이다. 사용자가 `.env`에 직접 넣게 안내한다 |
| 루트 계정 | 키가 루트이면 **즉시 중단** | 미션 제약. `sts get-caller-identity`의 ARN이 `:root`로 끝나는지 본다 |
| aws CLI | 없으면 `./.tools`에 v2를 sudo 없이 설치 | "키만 넣으면 되도록". 시스템을 건드리지 않고 프로젝트 안에만 설치한다 |
| 테스트 | `PATH`에 가짜 `aws`·`curl`·`ssh`·`scp`를 넣은 Bash 테스트 | 실제 AWS 없이 호출 순서·인자·상태 파일·역순 삭제를 검증한다. 테스트용 작은 앱 저장소의 `.env`에 표식을 넣어 비밀값이 새지 않는지 본다 |
| 서버 설정 검증 | Docker `ubuntu:24.04`에서 **같은 user-data.sh·provision-app.sh** 실행 (로컬 리허설) | EC2에서 돌 스크립트를 미리 실제로 돌려 본다. 앱은 로컬 ai_chatbot의 `git archive`, `.env`는 리허설 전용 가짜. 이것은 AWS가 아니므로 라벨을 붙여 구분한다 |

## 5. 검증 방법

1. **가짜 명령 테스트** (`bash tests/run.sh`) — 테스트를 먼저 작성하고 실패를 확인한 뒤 구현한다.
2. **로컬 리허설** (`bash local/rehearsal.sh`) — 컨테이너 안팎에서 `/health`(200 + JSON), `/`(303 → `-L` 200), `/signup`, 가입·로그인을 확인한다.
3. **트러블슈팅 재현** (`bash local/repro-port-blocked.sh`) — 포트를 열지 않은 상태를 일부러 만들어 가설 → 검증 → 조치를 기록한다.
4. **정적 검사** — `bash -n`, shellcheck(Docker 이미지), IAM 정책 JSON 검사.
5. **AWS 실행** — 사용자가 키를 넣고 직접 실행한다. 결과는 `evidence/aws/`에 자동 저장된다.

## 6. 하지 않는 것

- 보너스 과제(HTTPS, Docker로 배포)는 하지 않는다.
- 실제 AWS 호출은 이 저장소 작성 과정에서 하지 않는다. 퍼블릭 IP·스크린샷·Billing 결과는 사용자가 실행 후 채운다.

## 7. 진행 결과 (2026-10-04)

| 단계 | 결과 |
|---|---|
| 가짜 명령 테스트 | `bash tests/run.sh` → `PASS 42 / FAIL 0`(최초), 리뷰 후속 수정 후 `PASS 54 / FAIL 0`, 2차 수정 후 `PASS 58 / FAIL 0`(bash 4.3 컨테이너에서도 동일). 묶음마다 테스트를 먼저 쓰고 실패(RED)를 확인한 뒤 구현했다 |
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

### 리뷰 후속 수정 (fix/review-feedback)

| 항목 | 바꾼 내용 |
|---|---|
| 자격 증명 출처 | `.env` 파싱 전에 셸의 `AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY`·`AWS_SESSION_TOKEN`을 지운다. 키는 `.env`에서만 받는다. `MY_IP` 출처(.env/셸/자동 감지)를 로그에 정확히 적는다 |
| bash 버전 | bash 4 미만이면 `lib/common.sh`를 읽는 순간 안내하고 종료한다(배포만 되고 정리가 안 되는 상황 방지) |
| 인스턴스 정리 | 인스턴스별로 종료 요청·대기한다(여러 ID 중 하나가 NotFound여도 나머지를 놓치지 않음) |
| 증거 마스킹 | 계정 ID·내 IP를 ERE 숫자 경계로 바꾼다(다른 IP의 일부를 깨뜨리지 않음) |
| 프리 티어 유형 | 사전 점검에서 `free-tier-eligible` 조회로 선택 유형이 대상인지 확인하고, 아니면 경고만 한다(차단 안 함) |
| 최종 일관성 | `wait vpc-exists` 후 `vpc-available`, 서브넷은 NotFound만 재시도하는 조회 루프(`wait_exists`) 후 `subnet-available`(`subnet-available` 대기는 NotFound를 만나면 바로 실패하므로) |
| 테스트 | 회귀 테스트 12개 추가(42 → 54). 가짜 aws에 실패 주입(`FAKE_FAIL_ONCE_ON/WITH`, `FAKE_NOTFOUND_FOR`, `FAKE_FAIL_CODE`)을 넣어 cleanup의 재시도·NotFound 분기를 스위트로 검증한다 |

### 재리뷰 후속 수정 (fix/review-feedback-2)

| 항목 | 바꾼 내용 |
|---|---|
| 마스킹 회귀(Important) | `.env`의 `MY_IP=x.x.x.x/32`를 verify·cleanup이 정규화 없이 마스킹 sed에 넣어 sed가 깨졌다. 그 결과 cleanup이 **삭제 전에** 멈췄다. `mask_stream`이 `/32`를 떼고 IPv4일 때만 치환하게 고쳤다. 계정 ID도 12자리일 때만 치환해, 치환 결과가 다시 일치하는 무한 반복을 막았다. `sed_escape`에 `/`를 추가했다 |
| 생성 직후 일관성 | IGW·Route Table·SG도 만든 직후 조회될 때까지 기다린다(NotFound만 재시도). 그다음 연결·경로·규칙을 추가한다 |
| bash 4.0~4.3 | 빈 배열 확장을 `${arr[@]+"${arr[@]}"}`로 바꿨다(테스트 하네스, cleanup 루프, aws CLI 설치기). 수정 전 bash 4.3에서는 cleanup이 인스턴스 종료 전에 `eips[@]: unbound variable`로 멈췄다 |
| 문서 | `--help`에 프리 티어 확인 설명, `ec2:CreateTags`가 `--tag-specifications`에 필요하다는 점 명시, 테스트 수 58, 코드 줄 번호 갱신 |

## 8. ai_chatbot 배포로 변경 (2026-10-08)

정적 Nginx 페이지 대신 [L-jy16/ai_chatbot](https://github.com/L-jy16/ai_chatbot)(FastAPI + uvicorn + SQLite)을 배포하도록 바꿨다. 사용자가 승인한 설계를 그대로 따랐다.

| 항목 | 바꾼 내용 |
|---|---|
| user-data | Nginx 사이트를 `proxy_pass http://127.0.0.1:8000`(Host·X-Forwarded-For, `proxy_read_timeout 90s`)으로 바꾸고 `/health` 고정 응답을 없앴다. python3-venv 설치, `/home/ubuntu/ai_chatbot` 준비, 완료 표식 `/var/lib/b3-1/user-data.done` |
| 앱 설치 | `server/provision-app.sh` 신설: 소스 교체(.venv·.env·app.db 유지), venv·pip, `.env` 보정(600, `DATABASE_URL` 절대 경로, `SECRET_KEY` 생성), systemd `ai-chatbot`, 서버 안 `/health` 대기. 여러 번 실행해도 안전 |
| deploy.sh | 사전 점검에 `APP_SRC`·`APP_REF`(앱 코드 유무)·`APP_ENV_FILE`·`LLM_API_KEY`(경고) 확인. `step_app`: SSH·user-data 대기 → scp → 설치 → `APP_COMMIT` 기록 → `03b-app.txt` |
| verify.sh | `/health` JSON 판정, `/` 원 응답(303)·`-L`(200), `ai-chatbot` 서비스, 서버 안 `curl -L`·`/health`, LLM API 도달성(WARN 전용). 결과 PASS/FAIL/WARN, `/health` 대기 최대 10분 |
| 보안 그룹·IAM | 바꾸지 않았다(80·22만, 정책 그대로). scp·ssh는 AWS API가 아니다 |
| 테스트 | 58 → 74. 가짜 `scp` 추가, 가짜 `ssh`·`curl`이 앱 응답을 흉내 낸다. user-data 정적 검사는 프록시 기준으로 바꿨다. 테스트를 먼저 쓰고 실패(RED, `PASS 45 / FAIL 29`)를 확인한 뒤 구현했다(GREEN, `PASS 74 / FAIL 0`, bash 4.3 컨테이너에서도 동일) |
| 로컬 리허설 | user-data → 앱 `git archive`·가짜 `.env` → provision-app.sh → 컨테이너 안팎 확인, 가입·로그인·채팅(키 없음 → 502 AI_ERROR), 재실행 안전성. 판정 30개 전체 통과(`evidence/local/rehearsal.txt`) |
| 트러블슈팅 재현 | `local/repro-port-blocked.sh`가 같은 순서로 앱까지 올려 재현하도록 고쳤다(공용 준비물 `local/stack.sh`). 증거 파일은 2026-10-04 기록을 유지 |
| 문서 | README(배포 대상·비밀값 전달·303 설명·8000을 열지 않는 이유), 아키텍처 다이어그램, 트러블슈팅(502 → ai-chatbot 점검), 정리 체크리스트(SQLite 삭제) |
| AWS 실행 | ⏳ 사용자 몫 — README "AWS에서 직접 할 일" |

