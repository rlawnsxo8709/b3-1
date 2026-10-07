# B3-1 — AWS VPC·EC2에 ai_chatbot(FastAPI) 웹 서비스 배포 자동화

> `.env`에 IAM 사용자 키 두 줄을 넣고 배포할 앱(ai_chatbot)의 `.env`를 준비한 뒤 `./deploy.sh`를 실행하면 서울 리전에 VPC → Public Subnet → IGW → Route Table → Security Group → EC2가 만들어진다.
> EC2에는 Nginx(80)가 뜨고, 그 뒤 `127.0.0.1:8000`에서 **PULSE 경제 숏폼 트렌드 챗봇**(FastAPI + uvicorn + SQLite)이 돈다. 외부 접속 검증과 증거 저장도 함께 끝난다.
> 실습이 끝나면 `./cleanup.sh` 한 번으로 역순 삭제하고, 잔여 리소스 0건을 확인한다.

| | |
|---|---|
| 실행 | `./deploy.sh` → `./verify.sh` → `./cleanup.sh` |
| 배포하는 앱 | **PULSE · 경제 숏폼 트렌드 챗봇** — 출처 [L-jy16/ai_chatbot](https://github.com/L-jy16/ai_chatbot). FastAPI + uvicorn + SQLite, AI 답변은 Codyssey LLM API(`copa.codyssey.kr`), 트렌드는 네이버 뉴스·데이터랩 API. **앱 코드는 `develop` 브랜치에 있다(`main`은 초기 커밋뿐)** |
| 리전 | 서울 `ap-northeast-2` (다른 값이면 중단) |
| 인스턴스 | `t3.micro`(기본) 또는 `t2.micro` — 계정의 프리 티어 대상 유형을 고른다([확인 방법](#프리-티어-대상-인스턴스-유형-확인)), Ubuntu 24.04 LTS, EBS gp3 8GiB |
| 서버 구성 | Nginx `0.0.0.0:80` → `proxy_pass http://127.0.0.1:8000` → uvicorn(systemd `ai-chatbot`) → SQLite `/home/ubuntu/ai_chatbot/app.db` |
| 필요한 것 | Linux 또는 WSL의 **Bash 4 이상**(macOS 기본 bash 3.2는 안 됨 → `brew install bash` 후 `bash ./deploy.sh`), `curl`, `ssh`·`scp`, `git`, ai_chatbot을 clone한 폴더. aws CLI v2는 없으면 `./.tools`에 자동 설치(sudo 불필요, `unzip` 필요) |
| 외부 접속 검증 | **방식 B — `GET http://<퍼블릭IP>/health` → 200 + `{"status":"ok"}`** (앱이 답한다). 같은 주소를 브라우저로 열면 로그인 화면(방식 A) |

설계 결정은 [PLAN.md](PLAN.md)에 있다.

---

## AWS에서 직접 할 일

> 이 저장소의 스크립트·테스트·로컬 리허설은 끝나 있다. **AWS 계정에서 실행하는 일만 남았다.** (작성 과정에서 실제 AWS는 호출하지 않았다)

**0단계 — 배포할 앱 준비 (ai_chatbot)**

이 저장소 기준 `../../../ai_chatbot`에 ai_chatbot 체크아웃이 있으면 그것을 쓴다. 다른 곳에 있으면 `.env`의 `APP_SRC`에 경로를 넣는다.

```bash
git clone https://github.com/L-jy16/ai_chatbot.git     # 이미 있으면 생략
cd ai_chatbot
git switch develop                                      # 앱 코드는 develop에 있다(main은 초기 커밋뿐)
cp -n .env.example .env && chmod 600 .env               # .env가 없을 때만
# .env에 채운다: LLM_API_KEY(Codyssey AI 키), NAVER_CLIENT_ID·NAVER_CLIENT_SECRET(네이버 개발자센터)
#   SECRET_KEY는 비워 두면 첫 배포 때 서버가 secrets.token_hex(32)로 만들고, 이후 재배포에서는 그 값을 유지한다.
#   DATABASE_URL은 서버 경로로 자동 교체된다
```

- 배포되는 것은 **커밋된 코드**다(`git archive`). 커밋하지 않은 변경은 서버에 가지 않는다(사전 점검이 경고한다).
- 체크아웃을 `develop`으로 바꾸지 않을 때는 이 저장소의 `.env`에 `APP_REF=develop`(원격 브랜치를 그대로 쓰려면 `git fetch` 후 `APP_REF=origin/develop`)을 넣는다. `APP_REF`가 `main`처럼 앱 코드가 없는 커밋이면 사전 점검이 `APP_REF에 앱 코드가 없습니다. ai_chatbot은 develop 브랜치에 코드가 있습니다(APP_REF=develop)`라고 안내하고 AWS를 부르기 전에 멈춘다.
- `LLM_API_KEY`가 비어 있어도 배포는 된다. 채팅(AI 답변)만 `502 AI_ERROR`가 난다(사전 점검이 경고). 나중에 키를 채우고 `./deploy.sh`를 다시 실행하면 `.env`가 바뀐 것을 알아채고 소스와 `.env`를 다시 올려 설치를 다시 한다(venv·SQLite DB는 유지).

**1단계 — 키 넣기**

```bash
cp .env.example .env
# .env를 열어 두 줄만 채운다 (실습용 IAM 사용자의 액세스 키, 루트 키 금지)
#   AWS_ACCESS_KEY_ID=AKIA...
#   AWS_SECRET_ACCESS_KEY=...
# ai_chatbot이 ../../../ai_chatbot 이 아니면  APP_SRC=<ai_chatbot 경로>
```

IAM 사용자가 아직 없다면 → [IAM 사용자 만들기](#iam-사용자-만들기)

기본 유형은 `t3.micro`다. 2025-07-15 이전에 가입한 계정(레거시 프리 티어)은 서울에서 `t2.micro`가 대상일 수 있다 → [프리 티어 대상 인스턴스 유형 확인](#프리-티어-대상-인스턴스-유형-확인)

**2단계 — 배포하고 확인·캡처**

```bash
./deploy.sh --preflight-only   # (선택) 리소스를 만들지 않고 키·앱 소스·앱 .env만 확인
./deploy.sh
```

- 5~10분(추정: 첫 부팅 설치와 앱 설치 포함, AWS 실측 전) 뒤 `배포 완료` 상자에 나온 `http://<퍼블릭IP>/health`를 브라우저로 열어 `{"status":"ok"}` 화면을 캡처한다 → `docs/screenshots/health.png`
- `http://<퍼블릭IP>/`를 열면 로그인 화면으로 이동한다. **테스트 계정**으로 `/signup` 가입 → 로그인 → 질문 하나 → `/history`까지 확인한다(HTTP라 실제 비밀번호는 쓰지 않는다). 로그인 화면을 캡처한다 → `docs/screenshots/app.png`(선택)
- 아래 [외부 접속 검증](#외부-접속-검증--방식-b-선택) 표의 ⏳ 칸에 퍼블릭 IP를 적는다

**3단계 — 정리하고 스크린샷 1장**

```bash
./cleanup.sh
```

- `정리 완료: 잔여 리소스 0건`을 확인한다. 서버의 SQLite(가입·대화 기록)도 인스턴스와 함께 삭제된다
- Billing 화면 또는 리소스 목록(EC2 terminated) 화면을 캡처한다 → `docs/screenshots/billing.png`
- [docs/cleanup-checklist.md](docs/cleanup-checklist.md)의 체크박스를 채운다

마지막으로 자동 생성된 `evidence/aws/*.txt`와 스크린샷을 커밋한다. 계정 ID와 내 IP는 증거 파일에서 자동으로 가려지고, 앱 `.env`의 값은 증거에 들어가지 않는다.

---

## 외부 접속 검증 — 방식 B 선택

| 항목 | 내용 |
|---|---|
| 선택한 방식 | **(B) `GET http://<퍼블릭IP>/health` 호출 → HTTP 200 + 고정 응답 `{"status":"ok"}`** |
| 고른 이유 | 응답 코드와 본문이 고정이라 스크립트(`verify.sh`)가 PASS/FAIL을 기계적으로 판정하고 증거를 남길 수 있다. 이 응답은 Nginx가 아니라 **앱(FastAPI)이** 돌려주므로, 200 + JSON이면 "Nginx → 앱"까지 살아 있다는 뜻이다. 같은 주소를 브라우저로 열면 로그인 화면이 나오므로 방식 A도 함께 확인된다 |
| 구성한 것 | ① Nginx `location / { proxy_pass http://127.0.0.1:8000; }` (`server/user-data.sh:44`) ② 앱 `GET /health` → `{"status":"ok"}` (ai_chatbot `app/main.py`) ③ SG 인바운드 80 ← 0.0.0.0/0 ④ 서브넷 퍼블릭 IP 자동 할당 ⑤ 라우트 0.0.0.0/0 → IGW |
| 접속 정보 (URL) | ⏳ AWS 실행 후 기입 — `http://<퍼블릭IP>/health` |
| 퍼블릭 IP | ⏳ AWS 실행 후 기입 |
| 검증 결과 | ⏳ AWS 실행 후 기입 — `evidence/aws/04-verify.txt`의 결과 표 |
| 스크린샷 | ⏳ AWS 실행 후 추가 — `docs/screenshots/health.png` |

**`/`가 200이 아니라 303인 이유** — 앱은 로그인하지 않은 사용자가 `/`(채팅 화면)에 오면 `/login`으로 **303 리다이렉트**한다(ai_chatbot `app/routers/pages.py`). 앱 코드는 고치지 않았다. 그래서 검증은 원래 응답을 그대로 기록하고 둘로 나눠 본다.

| 확인 | 결과 | 의미 |
|---|---|---|
| `curl http://<IP>/` (원 응답) | `303`, `location: /login` | 앱이 정상적으로 비로그인 사용자를 로그인 화면으로 보냄 |
| `curl -L http://<IP>/` (리다이렉트 따라감) | `200` (로그인 화면) | 브라우저로 열었을 때 페이지가 정상 표시됨(방식 A) |
| `curl http://<IP>/health` | `200` + `{"status":"ok"}` | 방식 B 판정 대상 |

미션의 "인스턴스 안 `curl http://localhost` → 200"도 같은 방식으로 보인다. `verify.sh`가 SSH로 원 응답(303), `curl -L`(200), `/health`(200)를 모두 기록한다.

> 퍼블릭 IP는 실습이 끝나 정리하면 사라진다. 그래서 README의 IP는 "그때 이 주소로 접속했다"는 기록이고, 정리 후에는 접속되지 않는 것이 정상이다.

---

## 아키텍처

![B3-1 아키텍처](docs/architecture.png)

외부 요청이 앱에 닿는 경로는 아래와 같다.

```
사용자 ──HTTP 80──▶ Internet Gateway ──▶ (VPC 10.0.0.0/16) Public Subnet 10.0.1.0/24 ──▶ Security Group(80 허용)
      ──▶ EC2 Nginx 0.0.0.0:80 ──proxy_pass──▶ uvicorn/FastAPI 127.0.0.1:8000 ──▶ SQLite app.db
EC2 ──(Route Table 0.0.0.0/0 → IGW)──▶ Internet Gateway ──▶ 인터넷
      (apt·pip 설치, Codyssey LLM API, 네이버 API, curl https://example.com)
운영자 PC ──SSH 22(내 IP/32만)──▶ EC2   (앱 소스·앱 .env 전송, 점검)
```

다이어그램은 [`docs/make_architecture.py`](docs/make_architecture.py)가 Pillow로 그린다(`python3 docs/make_architecture.py`).

## 배포 흐름

```
deploy.sh
 ├─ 사전 점검 (AWS 호출 전) ─ .env 키, APP_SRC가 git 저장소인지, APP_REF 커밋에 app/main.py·requirements.txt가 있는지,
 │                            APP_ENV_FILE이 있는지, LLM_API_KEY가 비었는지(경고만, 값은 출력하지 않음)
 ├─ 사전 점검 (AWS) ───────── 자격 증명(루트 거부), 내 IP, 프리 티어 대상 유형
 ├─ VPC → Subnet → IGW → Route Table → SG(80·22) → 키페어 → EC2(user-data: Nginx 프록시·python3-venv·앱 폴더)
 ├─ 증거 01~03
 ├─ step_app ─ SSH 접속 + user-data 완료 표식(/var/lib/b3-1/user-data.done) 대기
 │             → git archive로 만든 소스, server/provision-app.sh, 앱 .env를 scp(.env는 파일 경로로)
 │             → 서버에서 sudo bash provision-app.sh: 소스 교체, venv·pip, .env 보정(600), systemd ai-chatbot, 서버 안 /health 대기
 │             → 배포한 커밋 SHA를 state/resources.env에 기록 → 증거 03b
 └─ verify.sh --wait ─ /health 200 대기(최대 10분) → 외부·SSH 점검 → 증거 04
```

## 생성 리소스

모든 리소스에 `Name=b3-1-…`, `Project=b3-1` 태그를 단다. 정리와 잔여 조회가 이 태그를 기준으로 한다.

| 리소스 | Name | 설정 | 만드는 곳 |
|---|---|---|---|
| VPC | `b3-1-vpc` | `10.0.0.0/16`, DNS 호스트 이름 사용 | `deploy.sh` `step_vpc` |
| Public Subnet | `b3-1-public-subnet` | `10.0.1.0/24`, `ap-northeast-2a`, 퍼블릭 IP 자동 할당 | `step_subnet` |
| Internet Gateway | `b3-1-igw` | VPC에 연결 | `step_igw` |
| Route Table | `b3-1-public-rt` | `0.0.0.0/0 → IGW`, 서브넷에 연결 | `step_route` |
| Security Group | `b3-1-web-sg` | 아래 규칙 표 | `step_sg` |
| Key Pair | `b3-1-key` | ed25519, `state/b3-1-key.pem`(400) | `step_keypair` |
| EC2 | `b3-1-web` | Canonical 최신 Ubuntu 24.04, IMDSv2 필수, user-data로 Nginx 프록시, SSH로 ai_chatbot 설치(systemd `ai-chatbot`) | `step_ami`, `step_instance`, `step_app` |
| EBS | `b3-1-root` | gp3 8GiB, 종료 시 삭제(SQLite 데이터 포함) | `step_instance` |

Elastic IP·NAT Gateway·ELB·RDS는 만들지 않는다.

## 보안 그룹 규칙

| 방향 | 포트 | 소스 | 허용 | 이유 |
|---|---|---|---|---|
| 인바운드 | TCP 80 | `0.0.0.0/0` | ✅ | 웹 서비스는 누구나 접속해야 한다(미션 요구). Nginx가 받아 앱으로 넘긴다 |
| 인바운드 | TCP 22 | `내 IP/32` | ✅ | 관리용 SSH와 앱 배포(scp)는 나만. `.env`의 `MY_IP` 또는 자동 감지. 감지 실패 시 넓히지 않고 중단 |
| 인바운드 | TCP 8000 | — | ❌ | 앱(uvicorn) 포트. **127.0.0.1에만 바인딩**하고 Nginx(80)가 서버 안에서 넘겨주므로 밖에서 열 이유가 없다. ai_chatbot의 `docs/DEPLOY.md`는 8000을 열라고 하지만, 미션의 "필요한 포트만" 원칙에 따라 열지 않는다(SG와 바인딩 주소로 이중 차단) |
| 인바운드 | TCP 22 | `0.0.0.0/0` | ❌ | 전 세계에서 무차별 대입 공격이 들어온다. 키가 새면 바로 침입 경로가 된다 |
| 인바운드 | TCP 443 | — | ❌ | HTTPS를 쓰지 않는다(보너스 범위). 쓰지 않는 포트는 열지 않는다 |
| 인바운드 | 0–65535 / 전체 프로토콜 | `0.0.0.0/0` | ❌ | 미션 금지 사항. 테스트가 `FromPort=0,ToPort=65535`·`IpProtocol=-1`이 없음을 확인한다 |
| 인바운드 | DB 포트(3306 등) | — | ❌ | DB는 서버 안의 SQLite 파일이라 네트워크 포트가 없다 |
| 아웃바운드 | 전체 | `0.0.0.0/0` | ✅ (기본값) | user-data의 `apt-get`, `pip install`, 앱의 LLM·네이버 API 호출, 미션의 `curl https://example.com` 확인에 필요 |

## 비밀값 전달 방식

앱에 필요한 `SECRET_KEY`·`LLM_API_KEY`·`NAVER_CLIENT_ID`·`NAVER_CLIENT_SECRET`은 아래 경로로만 움직인다.

| 단계 | 어디에 | 보호 |
|---|---|---|
| 내 PC | ai_chatbot의 `.env`(`APP_ENV_FILE`) | 그 저장소의 `.gitignore`. 이 저장소에는 들어오지 않는다 |
| 전송 | `scp <APP_ENV_FILE> ubuntu@<IP>:.b3-1-upload/app.env` | SSH(22, 내 IP/32만)로 **파일째** 보낸다. 값이 명령줄·로그·증거에 실리지 않는다. 업로드 폴더는 700 |
| 서버 | `/home/ubuntu/ai_chatbot/.env` | `provision-app.sh`가 소유자 `ubuntu`, 권한 **600**으로 두고 업로드본은 지운다. `DATABASE_URL`은 `sqlite:////home/ubuntu/ai_chatbot/app.db`로 맞춘다. 올린 `.env`의 `SECRET_KEY`가 비었거나 16자 미만이면 서버의 기존 값(16자 이상)을 그대로 쓰고(재배포해도 로그인 세션 유지), 기존 값도 없을 때(첫 배포)만 `secrets.token_hex(32)`로 만든다 |
| 넣지 않는 곳 | user-data | user-data는 인스턴스 메타데이터와 콘솔에서 보이므로 비밀값을 넣지 않는다 |
| 기록 | 화면·`evidence/aws/03b-app.txt` | 항목별 "있음/비어 있음"과 `.env` 권한(`600 ubuntu:ubuntu`)만 남긴다. 앱 경로는 `<APP_SRC>`·`<APP_ENV_FILE>`로 가린다 |

테스트(`test_deploy_uploads_app_env_by_path_and_never_leaks_secret_values`)가 가짜 `.env`에 넣은 표식 문자열이 호출 기록·증거·화면·상태 파일 어디에도 나오지 않는 것을 확인한다.

## IAM 최소권한

실습 사용자 `b3-1-operator`에는 [`iam/least-privilege-policy.json`](iam/least-privilege-policy.json) 하나만 연결한다. `AdministratorAccess`는 쓰지 않는다.

| Statement | 효과 | 내용 |
|---|---|---|
| `ReadOnlyDescribe` | Allow | `ec2:Describe*` — 조회와 waiter(`wait instance-running` 등) |
| `LabLifecycle` | Allow | VPC·Subnet·IGW·Route Table·SG·키페어·인스턴스의 생성/연결/삭제와 `CreateTags`(직접 부르지 않지만 `--tag-specifications`로 생성 시 태그를 달 때 필요), 정리용 `DeleteVolume`·`DisassociateAddress`·`ReleaseAddress` |
| 두 Allow 공통 | 조건 | `aws:RequestedRegion = ap-northeast-2` — 다른 리전에서는 아무것도 못 한다 |
| `DenyNonFreeTierTypes` | Deny | `t2.micro`·`t3.micro`가 아닌 유형으로 `RunInstances` 금지 |

**들어 있지 않은 것**: S3·RDS·IAM·ELB 등 EC2 밖의 모든 서비스, `ec2:*`, EIP 할당(`AllocateAddress`), NAT Gateway 생성. `sts:GetCallerIdentity`는 권한 없이 항상 호출할 수 있어 넣지 않았다.
테스트 `test_iam_policy_covers_every_ec2_call_in_scripts`가 세 스크립트에 나오는 모든 `aws ec2 <작업>`이 이 정책으로 허용되는지 대조한다(빠진 권한을 잡는 검사다). 앱 배포는 SSH·scp로 서버에 직접 접속하는 일이라 AWS API가 아니다. 그래서 앱을 올리게 바뀌었어도 정책은 바꾸지 않았다. 스크립트가 쓰지 않는 권한은 정책에 넣지 않았다. 직접 호출하지 않는데 들어 있는 것은 두 개뿐이다. `ec2:CreateTags`는 생성 호출의 `--tag-specifications`(생성 시 태그)에 필요하다. `ec2:RevokeSecurityGroupIngress`는 내 IP가 바뀌었을 때 이전 SSH 규칙을 손으로 지우는 데 쓴다([troubleshooting.md의 SSH 허용 IP 갱신](docs/troubleshooting.md#ssh-허용-ip-갱신)).

### IAM 사용자 만들기

**방법 1 — 콘솔에서 직접 (루트 계정만 있을 때 권장)**

1. 루트로 콘솔에 로그인 → IAM → 정책 → 정책 생성 → JSON 탭에 `iam/least-privilege-policy.json` 내용 붙여 넣기 → 이름 `b3-1-least-privilege`
2. IAM → 사용자 → 사용자 생성 → 이름 `b3-1-operator` → (콘솔 접근이 필요하면) "AWS Management Console에 대한 사용자 액세스 권한 제공" 선택, 다음 로그인 시 비밀번호 재설정 체크
3. 권한 옵션: "직접 정책 연결" → `b3-1-least-privilege` 선택 (비밀번호 재설정을 켰다면 `IAMUserChangePassword`도 함께)
4. 만든 사용자 → 보안 자격 증명 → 액세스 키 만들기 → "CLI" → 키 두 개를 `.env`에 넣는다
5. 이후로는 루트를 쓰지 않는다. 콘솔은 `https://<계정ID>.signin.aws.amazon.com/console`로 `b3-1-operator`(또는 관리자 IAM 사용자)로 로그인한다

**방법 2 — 도우미 스크립트 (관리자 IAM 사용자가 이미 있을 때)**

```bash
./iam/create-iam-user.sh --profile my-admin            # ~/.aws의 관리자 프로필 사용
# 또는
ADMIN_AWS_ACCESS_KEY_ID=... ADMIN_AWS_SECRET_ACCESS_KEY=... ./iam/create-iam-user.sh --console
```

`b3-1-operator` 생성(있으면 재사용) → 정책 생성(있으면 재사용)·연결 → 액세스 키 발급 → `.env` 작성까지 한다. 기존 `.env`는 `.env.bak`으로 백업한다.
`--console`을 주면 무작위 초기 비밀번호를 한 번만 보여 주고, 첫 로그인 때 변경을 강제한다. 루트 키로 실행하면 거부한다.

---

## 스크립트 사용법

| 명령 | 하는 일 |
|---|---|
| `./deploy.sh` | 사전 점검 → 리소스 생성 → 앱 전송·설치(SSH) → `/health` 200 대기(5초 간격 최대 10분) → 외부 검증 → 증거 저장 → 접속 정보 출력 |
| `./deploy.sh --preflight-only` | `.env`·앱 소스(`APP_SRC`·`APP_REF`·`APP_ENV_FILE`)·aws CLI·자격 증명(루트 거부)·내 IP·프리 티어 대상 유형 확인까지만. 리소스를 만들지 않는다 |
| `./verify.sh` | 외부 `/health`·`/`(원 응답과 `-L`), SSH로 `nginx`·`ai-chatbot` 서비스, `curl localhost`(원 응답·`-L`·`/health`), `curl https://example.com`, LLM API 도달성 확인. FAIL이 하나라도 있으면 종료 코드 1(WARN은 아님) |
| `./verify.sh --wait` | `/health`가 200이 될 때까지 기다린 뒤 검증 (`deploy.sh`가 부른다) |
| `./cleanup.sh` | 역순 삭제 → 태그로 잔여 조회 → 0건이면 상태 파일을 `state/resources.cleaned-<시각>.env`로 보관 |
| `./iam/create-iam-user.sh` | (선택) 실습용 IAM 사용자와 `.env` 만들기 |

`.env` 선택 항목: `MY_IP`(비우면 자동 감지), `INSTANCE_TYPE`(`t3.micro`/`t2.micro`), `AZ`(기본 `ap-northeast-2a`), `PROJECT`(태그·이름 접두사, 기본 `b3-1`), `AWS_SESSION_TOKEN`(임시 키일 때),
`APP_SRC`(ai_chatbot git 체크아웃, 비우면 이 폴더 기준 `../../../ai_chatbot`, 상대 경로는 이 폴더 기준), `APP_ENV_FILE`(서버로 보낼 앱 `.env`, 기본 `APP_SRC/.env`), `APP_REF`(배포할 브랜치·커밋, 기본 `HEAD`. 앱 코드는 `develop`에 있다).

### 사전 점검이 막는 것 (AWS 호출 전)

| 상황 | 결과 |
|---|---|
| bash 4 미만(macOS 기본 bash 3.2 등) | 아무것도 하기 전에 안내하고 종료 코드 1(배포만 되고 정리가 안 되는 상황 방지) |
| `.env`가 없거나 키가 비어 있음 | 무엇을 채울지 안내하고 종료 코드 1. AWS를 한 번도 부르지 않는다. **셸에 export한 `AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY`·`AWS_SESSION_TOKEN`은 쓰지 않는다**(다른 계정·루트 키가 조용히 쓰이거나 임시 토큰이 섞이는 사고 방지) |
| `APP_SRC`가 없거나 git 저장소(최상위 폴더)가 아님 | clone 방법을 안내하고 종료 코드 1. AWS를 부르지 않는다 |
| `APP_REF`가 없는 브랜치·커밋 | 종료 코드 1 |
| `APP_REF` 커밋에 `app/main.py`·`requirements.txt`가 없음(예: ai_chatbot의 `main`) | `APP_REF에 앱 코드가 없습니다. ai_chatbot은 develop 브랜치에 코드가 있습니다(APP_REF=develop)` 안내 후 종료 코드 1 |
| `APP_ENV_FILE`(기본 `APP_SRC/.env`)이 없음 | `cp .env.example .env`와 채울 항목을 안내하고 종료 코드 1 |
| `ssh`·`scp`가 없음 | `sudo apt-get install -y openssh-client`를 안내하고 종료 코드 1(리소스를 다 만든 뒤 앱 전송 단계에서 멈추는 일 방지) |
| 앱 `.env`의 `LLM_API_KEY`가 비어 있음 / `APP_SRC`에 커밋하지 않은 변경 | **경고만** 하고 진행한다(채팅만 안 됨 / 커밋된 내용만 배포됨). 값은 출력하지 않고 항목별 있음·비어 있음만 알린다 |
| 루트 계정 키 (`arn:aws:iam::<id>:root`) | 즉시 거부 — 미션 제약 "루트 금지" |
| 리전이 서울이 아님 / 프리 티어 외 인스턴스 유형 | 거부 |
| 내 IP 자동 감지 실패 또는 IPv4가 아님 | 22번을 넓게 열지 않고 중단, `MY_IP`를 직접 넣으라고 안내. `MY_IP`는 `.env` → 셸 환경변수 → 자동 감지 순으로 정하고 출처를 로그에 적는다 |
| 고른 유형이 이 계정의 프리 티어 대상이 아님 | **경고만** 하고 진행한다(차단하지 않음). 대상 유형과 `.env`에 넣을 값을 알려 준다 |

### 프리 티어 대상 인스턴스 유형 확인

프리 티어 대상 유형은 계정마다 다르다. 2025-07-15 이후 가입 계정은 `t3.micro` 등, 그 이전에 가입한 계정(레거시 프리 티어)은 서울에서 `t2.micro`가 대상이다. 대상이 아닌 유형은 프리 티어 기간에도 과금된다.

```bash
aws ec2 describe-instance-types --region ap-northeast-2 \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' --output text
```

결과에 `t3.micro`가 있으면 기본값 그대로 쓴다. `t2.micro`만 있으면 `.env`에 `INSTANCE_TYPE=t2.micro`를 넣는다. `deploy.sh`도 사전 점검에서 같은 조회를 하고, 대상이 아니면 경고와 함께 넣을 값을 알려 준다(차단은 하지 않음).
스크립트와 IAM 정책의 Deny는 `t2.micro`·`t3.micro` 두 가지만 허용한다. 그 밖의 유형(예: `t4g.micro`)이 대상이더라도 이 실습에서는 쓰지 않는다.

### 재실행과 실패 시 동작

- 각 단계는 만든 리소스 ID를 **즉시** `state/resources.env`에 적는다. 다시 실행하면 이미 끝난 단계(생성·연결·규칙 추가)는 건너뛰고 이어서 진행한다.
- 방금 만든 VPC·서브넷·IGW·Route Table·SG는 조회될 때까지 기다린 뒤 다음 단계(연결·경로·규칙 추가)로 간다(`wait vpc-exists`, 나머지는 NotFound만 재시도하는 조회). AWS API의 최종 일관성 때문에 생성 직후 잠깐 "없음"이 나올 수 있기 때문이다.
- 앱은 설치에 성공했을 때만 배포한 커밋 SHA를 `APP_COMMIT`으로 적는다. 다시 실행했을 때 **같은 커밋·같은 앱 `.env`(수정 시각·크기, 심볼릭 링크면 대상 파일)·같은 인스턴스**면 앱 재배포를 건너뛰고 검증만 한다. 커밋이 바뀌었거나 `.env`를 고쳤으면 다시 올린다. 서버의 `provision-app.sh`는 여러 번 실행해도 안전하다(venv·`.env`의 `SECRET_KEY`·SQLite DB 유지, 소스만 교체).
- **같은 커밋·같은 `.env`로 강제 재설치**하려면 `touch <APP_ENV_FILE>`(기본 `../../../ai_chatbot/.env`) 후 `./deploy.sh`를 실행한다. 수정 시각이 바뀌어 소스와 `.env`를 다시 올리고 설치를 다시 한다.
- SSH가 아직 안 되면(부팅 중) 10초 간격으로 최대 60번 다시 확인한다. 연결 시간 초과가 6번 연속이면 SG 22번의 SSH 허용 IP가 지금 내 IP와 같은지 확인하라고 경고한다(계속 기다린다). 서버의 호스트 키가 `state/known_hosts`와 다르면 기다리지 않고 멈추고 `ssh-keygen -f state/known_hosts -R <IP>` 방법을 알려 준다.
- user-data가 `cloud-init status: error`로 끝났으면 기다리지 않고 바로 멈춘다. **user-data는 첫 부팅에 한 번만 돌기 때문에 `./deploy.sh`만 다시 실행해서는 풀리지 않는다**(인스턴스는 켜진 채 과금). 안내대로 `/var/log/cloud-init-output.log`를 본 뒤, 일시 오류(apt 미러 등)면 `ssh -i state/b3-1-key.pem ubuntu@<IP> 'sudo bash /var/lib/cloud/instance/user-data.txt'`로 user-data를 다시 돌리고 `./deploy.sh`, 아니면 `./cleanup.sh` → `./deploy.sh`로 새로 만든다.
- 그 밖의 실패는 `[ERROR] 단계 실패: <단계>. 원인을 고친 뒤 ./deploy.sh를 다시 실행하면 이어서 진행합니다. 정리는 ./cleanup.sh`가 나온다.
- `cleanup.sh`는 상태 파일 값과 `Project=b3-1` 태그 조회 결과를 **합쳐** 지운다. 상태 파일을 잃어버려도 정리된다. 한 단계가 실패해도 경고만 남기고 다음 단계로 간다. 남은 리소스가 있으면 목록을 보여 주고 종료 코드 1로 끝난다(여러 번 실행해도 안전).

### 증거 파일 (AWS 실행 시 자동 생성)

| 파일 | 내용 |
|---|---|
| `evidence/aws/00-identity.txt` | 실행 주체 ARN(계정 ID 가운데 4자리 마스킹), 리전, SSH 허용 소스(내 IP 뒤 두 자리 마스킹) |
| `evidence/aws/01-network.txt` | `describe-vpcs`·`describe-subnets`·`describe-route-tables`·`describe-internet-gateways` 표 |
| `evidence/aws/02-security-group.txt` | `describe-security-groups` 표 — 80·22 규칙(8000 없음) |
| `evidence/aws/03-instance.txt` | 인스턴스 유형·상태·퍼블릭 IP·IMDSv2, AMI 이름·소유자, 루트 볼륨 |
| `evidence/aws/03b-app.txt` | 앱 배포 — 배포 커밋, 서버 준비 확인, `git archive`·`scp`·`provision-app.sh` 명령과 출력(.env 항목은 있음/비어 있음, 권한 600, 리슨 소켓 `127.0.0.1:8000`, Nginx 경유 응답 코드) |
| `evidence/aws/04-verify.txt` | `curl -i /health`·`/` 원문, `curl -L /`, SSH 점검 출력, 결과 표(PASS/FAIL/WARN) |
| `evidence/aws/05-cleanup.txt` | 실행한 삭제 명령과 결과, 잔여 리소스 조회(모두 0건이어야 함), 리전 전체 참고 조회 |

로컬 리허설 증거는 `evidence/local/`에 있다(아래).

---

## 로컬 리허설 결과 (AWS 아님)

> EC2에서 돌 [`server/user-data.sh`](server/user-data.sh)와 [`server/provision-app.sh`](server/provision-app.sh)를 **그대로** `ubuntu:24.04` 컨테이너에서 실행했다. 앱 소스는 로컬 ai_chatbot의 `git archive`이고, `.env`는 **리허설 전용 가짜**(SECRET_KEY만 생성, LLM·NAVER 키는 비움)다. 실제 ai_chatbot `.env`는 쓰지 않았다.
> 컨테이너에는 systemd가 없어 `provision-app.sh`가 같은 uvicorn 명령을 백그라운드로 띄운다. VPC·SG·IAM·SSH는 리허설 대상이 아니다. 실행: `bash local/rehearsal.sh` · 전체 출력: [`evidence/local/rehearsal.txt`](evidence/local/rehearsal.txt)

실제 출력 발췌 (로컬 리허설, 2026-10-08):

```text
$ docker exec b3-1-rehearsal curl -s -i http://localhost/health
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Date: Wed, 07 Oct 2026 17:40:13 GMT
Content-Type: application/json
Content-Length: 15
Connection: keep-alive

{"status":"ok"}
...
[PASS] 컨테이너 안 GET / 원 응답(비로그인 → /login) — 기대: 303 / 실제: 303
[PASS] 컨테이너 안 GET -L / (로그인 화면) — 기대: 200 http://localhost/login / 실제: 200 http://localhost/login
[PASS] 컨테이너 안 GET /signup — 기대: 200 / 실제: 200

$ docker exec b3-1-rehearsal ss -ltnp
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
LISTEN 0      2048       127.0.0.1:8000      0.0.0.0:*
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=2894,fd=5))
LISTEN 0      511             [::]:80           [::]:*    users:(("nginx",pid=2894,fd=6))
[PASS] uvicorn은 127.0.0.1:8000에만 리슨
[PASS] 8000을 모든 인터페이스(0.0.0.0:8000)에 열지 않음
[PASS] Nginx는 0.0.0.0:80에 리슨
[PASS] 서버 .env 권한 — 기대: 600 ubuntu:ubuntu / 실제: 600 ubuntu:ubuntu
...
[PASS] 호스트 GET /health 본문 — 기대: {"status":"ok"} / 실제: {"status":"ok"}
[PASS] 호스트 GET / 원 응답(비로그인 → /login) — 기대: 303 http://127.0.0.1:18080/login / 실제: 303 http://127.0.0.1:18080/login
[PASS] 호스트 GET -L / (로그인 화면, 방식 A) — 기대: 200 / 실제: 200
...
[PASS] 회원가입 POST /api/auth/signup — 기대: 201 / 실제: 201
[PASS] 로그인 POST /api/auth/login — 기대: 200 / 실제: 200
[PASS] 질문 POST /api/chat — LLM_API_KEY 비움 → AI_ERROR — 기대: 502 / 실제: 502
...
[PASS] 재설치 뒤 SECRET_KEY가 바뀌지 않음(값 대신 해시 앞 12자를 비교, 값은 표시 안 함) — 기대: 같음 / 실제: 같음
[PASS] 재설치 전에 받은 로그인 쿠키로 GET / (세션 유지 → 채팅 화면) — 기대: 200 / 실제: 200
[PASS] 재설치 후 같은 계정 로그인(SQLite 데이터 유지) — 기대: 200 / 실제: 200
...
[PASS] 서버가 새로 만든 SECRET_KEY 길이(secrets.token_hex(32), 값은 표시 안 함) — 기대: 64 / 실제: 64

리허설 결과: 전체 통과 — Nginx 경유 /health 200 {"status":"ok"}, / 303 → -L 200(로그인 화면), /signup 200, 가입·로그인 동작, uvicorn 127.0.0.1:8000만 리슨, 재설치 시 SECRET_KEY·세션·데이터 유지
```

리허설에는 앱 설치 전 Nginx만 떠 있을 때 `/health`가 `502`인 것(`[PASS] 앱 설치 전 Nginx 경유 /health … 502`)도 들어 있다. 같은 `provision-app.sh`를 다시 실행하면(올린 `.env`의 `SECRET_KEY`는 비움) 서버의 기존 키를 유지해 이전 로그인 쿠키가 그대로 통하고 데이터도 남는다. 서버 `.env`가 없는 새 서버를 가정하면 서버가 키를 새로 만들고, 이때는 이전 쿠키가 무효(303)가 된다. 판정 줄은 모두 35개이고 FAIL은 없다.
LLM·네이버 API 실제 호출은 리허설 대상이 아니다(가짜 `.env`라 키가 없다). 실제 키로의 채팅과 LLM API 도달성은 AWS 실행 때 확인한다.

트러블슈팅 재현(포트를 열지 않은 상태 → 가설 검증 → 조치)은 [docs/troubleshooting.md](docs/troubleshooting.md)에 있다.

## 테스트

```bash
bash tests/run.sh      # 실제 출력 마지막 줄: PASS 83 / FAIL 0 (bash 5.2, bash 4.3 컨테이너 모두)
```

`PATH` 맨 앞에 가짜 `aws`·`curl`·`ssh`·`scp`([`tests/fake-bin/`](tests/fake-bin))를 넣고 스크립트를 실제로 실행한다. 가짜 명령은 호출을 한 줄씩 기록하고 정해진 ID·응답을 돌려준다. 가짜 `scp`는 인자만 기록하고 파일 내용은 남기지 않는다. 실제 AWS·네트워크는 부르지 않는다.
테스트마다 프로젝트 사본(임시 폴더)과 **테스트용 작은 앱 저장소**에서 돈다. 그래서 내 `.env`·`state/`·`evidence/aws/`와 실제 ai_chatbot(그 `.env` 포함)을 건드리지 않는다.
최소 요구 버전 확인을 위해 `bash:4.3` Docker 이미지에서도 전체 스위트를 돌려 같은 결과를 얻었다(bash 4.0~4.3은 `set -u`에서 빈 배열 확장을 오류로 보므로 `${arr[@]+"${arr[@]}"}`로 펼친다).

| 묶음 | 확인하는 것 |
|---|---|
| 사전 점검·마스킹 (17) | 키·`.env` 누락, **셸에 남은 키·토큰 무시**, 루트 거부, IP 감지 실패, MY_IP 출처 로그, 서울 외 리전·허용 외 유형 거부, 프리 티어 대상 아님 경고(차단 안 함), CRLF·따옴표·주석이 있는 `.env`, bash 4 미만 거부, 계정 ID·IP 마스킹(숫자 경계, `MY_IP=x.x.x.x/32` 정규화, IP가 아닌 값에서도 무한 반복 없음) |
| user-data (1) | 문법, 80 → `127.0.0.1:8000` 프록시·`proxy_read_timeout 90s`·Host/X-Forwarded-For, `/health` 고정 응답 없음(앱이 답함), python3-venv·앱 폴더·완료 표식, systemd 분기, `0.0.0.0/0`·8000 바깥 노출·비밀값 항목 없음 |
| deploy (10) | 생성 순서, VPC·서브넷·IGW·Route Table·SG 생성 직후 조회 대기, `--help` 내용, `0.0.0.0/0 → igw` 경로, SSH `/32`, 전체 포트 규칙 없음, 퍼블릭 IP 자동 할당, IMDSv2, Canonical AMI·gp3 8GiB, 모든 생성 호출에 태그, 서울 리전, 재실행 무변경, 중간 실패 후 이어하기, 접속 정보 출력 |
| verify (5) | `/health` 200 + JSON·SSH 점검 기록, 503이면 실패, 상태 없으면 안내, SSH 불가면 실패 |
| cleanup (15) | `MY_IP=/32`에서도 deploy→verify→cleanup 끝까지 진행, 역순 삭제, RT 연결 해제·IGW 분리, 태그 탐색(상태 파일 없음), 인스턴스별 종료·대기, EIP·EBS 해제, 잔여 리소스 보고, 실패해도 계속, DependencyViolation 재시도·재시도 상한, NotFound는 이미 없음, 일반 오류는 재시도 안 함, 두 번 실행, IP 감지 불필요, 키페어·pem·known_hosts 삭제 |
| aws CLI·IAM (10) | 아키텍처별 설치 URL, `./.tools` 설치, 정책 최소권한·Deny, **스크립트의 모든 ec2 호출이 정책에 있는지**, IAM 도우미(`.env` 작성·재사용·콘솔·루트 거부) |
| 앱 배포 (25) | **AWS 호출 전 중단**: `APP_SRC`가 git 저장소가 아님·없음, `APP_ENV_FILE` 없음, `APP_REF` 없음, `APP_REF`에 앱 코드 없음(develop 안내) / 경고만: `LLM_API_KEY` 비움, 커밋 안 한 변경 / 기본 경로 `../../../ai_chatbot`·상대 경로 / **`.env`를 파일 경로로 scp하고 비밀 표식이 호출 기록·증거·화면·상태에 없음**, 소스 묶음에 `.env` 없음 / 서버 준비 → 업로드 → 설치 → 검증 순서 / 커밋 SHA 기록, 같은 커밋 재배포 생략, 커밋·`.env`가 바뀌면 재배포 / SSH 대기, user-data 오류면 즉시 중단 / 설치 실패 후 재실행 / **SG 80·22만(8000 없음)**, uvicorn `127.0.0.1` 바인딩 / `provision-app.sh` 정적 검사 / verify: `/health`는 `{"status":"ok"}`만 PASS(`OK`는 FAIL), `/` 303·`-L` 200·`ai-chatbot` 서비스, LLM API `000`은 WARN(종료 코드 0) / **리뷰 후속(9)**: user-data 실패 시 수동 재실행·정리 후 재배포 안내(“다시 실행하면 이어서” 아님), 심볼릭 링크 `.env` 대상이 바뀌면 재배포, `touch`로 강제 재설치, 서버의 기존 `SECRET_KEY` 유지·없을 때만 생성(`.env` 보정 코드를 직접 실행), `ssh`·`scp` 없으면 AWS 호출 전 중단, 준비 확인 1은 대기·예상 밖 코드는 오류, 호스트 키 변경 즉시 중단(`ssh-keygen -R` 안내), 시간 초과 6회 연속 경고, 증거 마스킹이 줄 단위로 바로 출력 |

정적 검사:

```bash
bash -n *.sh lib/*.sh local/*.sh server/*.sh iam/*.sh tests/*.sh tests/fake-bin/*     # 통과
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x \
  deploy.sh verify.sh cleanup.sh lib/*.sh local/*.sh server/*.sh iam/create-iam-user.sh tests/run.sh tests/fake-bin/*   # 경고 0
python3 -m json.tool iam/least-privilege-policy.json > /dev/null                      # 유효한 JSON
```

---

## 요구사항 체크리스트

`✅ 스크립트 구현·로컬 검증` = 코드와 테스트(가짜 aws)·로컬 리허설로 확인함 / `⏳ AWS 실행 필요` = 사용자가 AWS에서 실행해야 완료

**최종 결과물**

| 요구 | 상태 | 근거 |
|---|---|---|
| 아키텍처 다이어그램 `docs/architecture.png` | ✅ | [docs/architecture.png](docs/architecture.png) (Nginx :80 → 앱 127.0.0.1:8000 → SQLite, 아웃바운드 LLM·네이버 API) |
| 외부 접속 증빙: 방식(B)과 접속 정보를 README에 기재 + 스크린샷 | ✅ 방식 기재 / ⏳ IP·스크린샷 | [외부 접속 검증](#외부-접속-검증--방식-b-선택) |
| 트러블슈팅 보고서 `docs/troubleshooting.md` (증상→가설→검증→조치→결과→재발방지) | ✅ 로컬 리허설 사례 1건 / ⏳ AWS 사례 기입란 | [docs/troubleshooting.md](docs/troubleshooting.md) |
| 리소스 정리 체크리스트 `docs/cleanup-checklist.md` (+ Billing 스크린샷 선택) | ✅ 작성 / ⏳ 체크·스크린샷 | [docs/cleanup-checklist.md](docs/cleanup-checklist.md) |

**기능 요구 사항**

| 요구 | 상태 | 근거 |
|---|---|---|
| VPC 1개 | ✅ / ⏳ | `deploy.sh` `step_vpc`, 테스트 `test_deploy_happy_path…` |
| Public Subnet 1개 | ✅ / ⏳ | `step_subnet` (`--map-public-ip-on-launch`) |
| IGW를 VPC에 연결 | ✅ / ⏳ | `step_igw` (`attach-internet-gateway`) |
| Route Table에 `0.0.0.0/0 → IGW` | ✅ / ⏳ | `step_route`, 테스트가 `--destination-cidr-block 0.0.0.0/0 --gateway-id igw-…` 확인 |
| 인스턴스 아웃바운드(`curl https://example.com`) | ✅ / ⏳ | `verify.sh`가 SSH로 확인 → `04-verify.txt`. 첫 부팅의 apt·pip 설치도 같은 경로를 쓴다 |
| Public Subnet에 EC2 1대 | ✅ / ⏳ | `step_instance` (`--count 1`) |
| SSH 접속 가능 | ✅ / ⏳ | `deploy.sh` 앱 배포(SSH·scp), `verify.sh` SSH 점검 |
| 웹 서버(Nginx 등) 설치·실행 | ✅ 로컬 리허설 / ⏳ | Nginx(`server/user-data.sh`) + ai_chatbot(`server/provision-app.sh`, systemd `ai-chatbot`). `verify.sh`가 `systemctl is-active nginx`·`ai-chatbot` 확인 |
| 인스턴스 안 `curl http://localhost` → 200 | ✅ 로컬 리허설 / ⏳ | 원 응답은 앱의 로그인 리다이렉트 `303`(그대로 기록), `curl -L http://localhost` → `200`(로그인 화면), `curl http://localhost/health` → `200`. 리허설 `[PASS] 컨테이너 안 GET -L /`, `verify.sh` |
| SG: 필요한 포트만, 80 ← 0.0.0.0/0, 22 ← 내 IP | ✅ / ⏳ | `step_sg`(8000은 열지 않음), `02-security-group.txt`, 테스트 `test_security_group_has_no_8000_rule` |
| SG: 0.0.0.0/0 전체 포트 규칙 없음 | ✅ | 테스트가 `FromPort=0,ToPort=65535`·`IpProtocol=-1` 부재 확인 |
| IAM 사용자 1개, EC2/VPC/SG 범위로 제한, S3·RDS 없음, Admin 없음 | ✅ 정책·도우미 / ⏳ 생성 | `iam/least-privilege-policy.json`(앱 배포로 바뀌지 않음), 정책 테스트 3개 |
| 외부 접속 검증(택1) — B 선택, README 명시 | ✅ / ⏳ 실행 | `verify.sh`(`/health` → 200 + `{"status":"ok"}`), 이 README |
| 실습 후 정리 + 근거 (EC2·EBS·EIP·IGW·VPC) | ✅ 스크립트 / ⏳ 실행 | `cleanup.sh`, `05-cleanup.txt`, 체크리스트 |

**제약 사항**

| 제약 | 상태 | 근거 |
|---|---|---|
| 프리 티어 범위 (micro 1대, EBS 8GiB) | ✅ / ⏳ 계정 확인 | `t3.micro`/`t2.micro`만 허용(스크립트 + IAM Deny), gp3 8GiB. 계정의 대상 유형은 사전 점검이 조회해 아니면 경고([확인 방법](#프리-티어-대상-인스턴스-유형-확인)) |
| 루트 계정 사용 안 함 | ✅ | 루트 키면 `deploy.sh`·`cleanup.sh`·IAM 도우미 모두 거부 |
| 모든 리소스 서울 리전 | ✅ | 리전 고정 + IAM 리전 조건 + 테스트가 모든 ec2 호출의 리전 확인 |
| Ubuntu LTS, EBS 8~10GiB, 키페어 1개 안전 보관 | ✅ | Ubuntu 24.04, 8GiB, `state/b3-1-key.pem` 400·`.gitignore` |
| 정리 대상 추적 (EC2·EIP·NAT·ELB·RDS·EBS) | ✅ / ⏳ | 태그 + 상태 파일, 체크리스트 |
| Billing Dashboard 확인 | ⏳ | [체크리스트의 Billing 절차](docs/cleanup-checklist.md#billing-확인-절차) |

---

## 폴더 구조

```
.
├── deploy.sh  verify.sh  cleanup.sh   진입 스크립트 3개
├── .env.example                      키 2개 + 선택값 + 배포할 앱(APP_SRC·APP_ENV_FILE·APP_REF) (복사해 .env로)
├── lib/
│   ├── common.sh                     .env 로드, 로그, 상태 파일, 증거 기록·마스킹, 태그, 사전 점검, 앱 소스 확인, SSH 옵션
│   └── awscli.sh                     aws CLI v2 확보 (없으면 ./.tools에 설치)
├── server/
│   ├── user-data.sh                  EC2 첫 부팅 스크립트 (Nginx 80 → 127.0.0.1:8000 프록시, python3-venv, 완료 표식)
│   └── provision-app.sh              앱 설치 (소스 교체, venv·pip, .env 600 보정, systemd ai-chatbot, /health 대기)
├── iam/
│   ├── least-privilege-policy.json   실습 사용자 정책
│   └── create-iam-user.sh            (선택) IAM 사용자 + .env 만들기
├── local/
│   ├── rehearsal.sh                  로컬 리허설 (같은 user-data·provision-app을 컨테이너에서)
│   ├── stack.sh                      리허설 공용 (앱 git archive, 리허설 전용 가짜 .env)
│   └── repro-port-blocked.sh         트러블슈팅 재현
├── tests/
│   ├── run.sh                        테스트 러너 (83개)
│   └── fake-bin/{aws,curl,ssh,scp}   가짜 명령
├── docs/
│   ├── architecture.png  make_architecture.py
│   ├── troubleshooting.md  cleanup-checklist.md
│   └── screenshots/                  ⏳ AWS 실행 후 health.png, billing.png (+ 선택 app.png)
├── evidence/
│   ├── local/                        로컬 리허설·재현 실제 출력
│   └── aws/                          ⏳ AWS 실행 시 자동 생성
├── state/                            (git 제외) 리소스 ID, 개인키, known_hosts, 배포한 앱 커밋
└── README.md  PLAN.md
```

## 주의사항

- `.env`(키), `state/`(개인키 `b3-1-key.pem`), `.env.bak`은 `.gitignore`로 막혀 있다. 절대 커밋하지 않는다. 개인키는 다시 받을 수 없다.
- 앱 `.env`(ai_chatbot 쪽)도 커밋하지 않는다. 서버로는 SSH로만 보내고, 화면·증거에는 값이 남지 않는다. 키가 노출되면 재발급한 뒤 앱 `.env`만 고쳐 `./deploy.sh`를 다시 실행한다(`.env`가 바뀌면 다시 올린다).
- **HTTP 배포다.** 로그인 비밀번호와 세션 쿠키가 암호화되지 않고 오간다. 확인은 **테스트 계정**으로만 하고 실제로 쓰는 비밀번호는 넣지 않는다(HTTPS는 보너스 범위).
- 실습이 끝나면 **반드시** `./cleanup.sh`. 인스턴스를 켜 둔 시간만큼 EC2·EBS·퍼블릭 IPv4 요금이 잡힐 수 있다(프리 티어 한도 확인). 정리하면 서버의 SQLite(가입·대화 기록)도 함께 삭제된다. 남길 데이터가 있으면 정리 전에 `scp`로 `app.db`를 받아 둔다.
- LLM API(`copa.codyssey.kr`)·네이버 API 연결은 로컬 리허설에서 확인하지 않았다. AWS 실행 때 `verify.sh`가 인스턴스에서 LLM API 도달성을 확인한다(키 없이 호출해 HTTP 응답이 오면 도달 가능, `000`이면 WARN — 미션 필수 항목이 아니라 FAIL로 보지 않는다). 실제 답변은 브라우저에서 질문해 확인한다.
- 퍼블릭 IP는 인스턴스를 중지했다 켜면 바뀐다. `verify.sh`는 매번 새로 조회한다.
- aws CLI 자동 설치는 공식 주소(`awscli.amazonaws.com`)에서 HTTPS로 받는다. 서명 검증까지 원하면 [공식 설치 문서](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)대로 직접 설치하면 그 CLI를 그대로 쓴다.
