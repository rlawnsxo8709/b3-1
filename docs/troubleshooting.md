# 트러블슈팅 보고서 — B3-1

> 원칙: **증상을 기록하고, 가설을 세우고, 한 번에 하나씩 검증한 뒤에 조치한다.**
> 검증 없이 "일단 포트 다 열어 보기"로 해결하면 왜 고쳐졌는지 모르고, 열어 둔 포트가 다음 사고가 된다.

| 사례 | 환경 | 상태 |
|---|---|---|
| [사례 1 — 서버는 떠 있는데 밖에서 접속이 안 된다](#사례-1--서버는-떠-있는데-밖에서-접속이-안-된다) | **로컬 리허설** (Docker, AWS 아님) | ✅ 실제 재현·해결, 증거 있음 |
| [AWS 실행 시 사례 기입란](#aws-실행-시-사례-기입란) | AWS | ⏳ AWS 실행 후 기입 |

참고 절: [외부 접속 불가 점검 순서](#외부-접속-불가-점검-순서) · [SSH 허용 IP 갱신](#ssh-허용-ip-갱신) · [IAM 권한 부족](#iam-권한-부족-unauthorizedoperation) · [설계 단계에서 미리 막은 문제](#설계-단계에서-미리-막은-문제)

---

## 사례 1 — 서버는 떠 있는데 밖에서 접속이 안 된다

> **로컬 리허설 (AWS 아님).** 미션 소개의 상황("서버에 올렸는데 외부에서 안 들어와요")을 Docker로 일부러 만들었다.
> 포트를 게시하지 않은 컨테이너는 **보안 그룹 인바운드 80이 없는 EC2**와 같은 증상을 보인다.
> 재현 스크립트: [`local/repro-port-blocked.sh`](../local/repro-port-blocked.sh) · 전체 출력: [`evidence/local/troubleshooting-port.txt`](../evidence/local/troubleshooting-port.txt)

| 로컬 리허설 | AWS에서 대응하는 것 |
|---|---|
| 컨테이너 안 `curl localhost` | EC2에 SSH로 들어가 `curl localhost` |
| 호스트에서 `curl 127.0.0.1:18080` | 인터넷에서 `curl http://<퍼블릭IP>` |
| `docker run -p 127.0.0.1:18080:80` (포트 게시) | 보안 그룹 인바운드 규칙 `TCP 80 ← 0.0.0.0/0` |
| `docker port`, `docker inspect …PortBindings` | `aws ec2 describe-security-groups … IpPermissions` |

| 단계 | 내용 |
|---|---|
| **증상** | 같은 `server/user-data.sh`로 Nginx를 설치했다. 서버 안에서는 `/health`가 `200`인데, 바깥(호스트)에서는 `curl: (7) Failed to connect … Couldn't connect to server`, HTTP 코드 `000` |
| **가설** | ① Nginx 프로세스가 떠 있지 않다 ② `127.0.0.1`에만 리슨해 외부 인터페이스로 오는 요청을 받지 않는다 ③ 바깥에서 서버까지 오는 경로(포트 게시 = 인바운드 허용)가 없다 |
| **검증** | 안쪽부터 하나씩 배제했다. `ss -tlnp` → nginx가 `0.0.0.0:80`, `[::]:80`에서 LISTEN이므로 ①② 기각. `docker port` 빈 출력, `PortBindings={}` → 게시된 포트 없음. 컨테이너 IP로 직접 부르면 `200` → 서버는 정상이고 바깥 경로만 없다. ③ 채택 |
| **조치** | 포트를 게시해(`-p 127.0.0.1:18080:80`) 다시 띄웠다. AWS라면 SG에 80 인바운드를 추가하는 것에 해당한다. 실행 중인 컨테이너에는 포트 게시를 추가할 수 없어 새로 만들었다. SG는 규칙만 추가하면 즉시 반영된다 |
| **결과** | `docker port` → `80/tcp -> 127.0.0.1:18080`. 호스트 `curl -i` → `HTTP/1.1 200 OK`, 본문 `OK`. 조치 전 `000` → 조치 후 `200` |
| **재발 방지** | ① 인바운드 규칙을 손이 아니라 코드로 만든다: `deploy.sh`의 `step_sg`가 80·22만 연다. ② 배포 직후 **바깥에서** `/health`를 자동 확인한다: `verify.sh`가 외부 `curl`로 판정하고 결과를 `evidence/aws/04-verify.txt`에 남긴다. ③ 점검은 [아래 순서표](#외부-접속-불가-점검-순서)대로, 안쪽(프로세스)과 바깥쪽(경로)을 분리해 본다 |

**실제 출력 발췌** (`evidence/local/troubleshooting-port.txt`, 로컬 리허설)

```text
## 1. 증상 — 서버 안에서는 200, 바깥에서는 접속 실패

$ docker exec b3-1-repro curl -s -o /dev/null -w %{http_code}\n http://localhost/health
200
(종료 코드 0)

$ curl -sS --max-time 5 http://127.0.0.1:18080/health
curl: (7) Failed to connect to 127.0.0.1 port 18080 after 0 ms: Couldn't connect to server
(종료 코드 7)
판정: 컨테이너 안 200 / 호스트 000 → 서버는 응답하지만 외부 경로가 막혀 있다

$ docker exec b3-1-repro ss -tlnp
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=2658,fd=5))
LISTEN 0      511             [::]:80           [::]:*    users:(("nginx",pid=2658,fd=6))
(종료 코드 0)
…(중략: docker port 빈 출력)
$ docker inspect -f PortBindings={{json .HostConfig.PortBindings}} b3-1-repro
PortBindings={}
(종료 코드 0)

$ curl -sS --max-time 5 -o /dev/null -w container-ip %{http_code}\n http://172.17.0.3/health
container-ip 200
…(중략: 3. 조치 — 포트를 게시해 다시 기동)
## 4. 결과

$ docker port b3-1-repro
80/tcp -> 127.0.0.1:18080
(종료 코드 0)

$ curl -sS -i --max-time 5 http://127.0.0.1:18080/health
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
Date: Sat, 03 Oct 2026 19:48:48 GMT
Content-Type: text/plain
Content-Length: 3
Connection: keep-alive

OK
(종료 코드 0)
판정: 조치 전 호스트 000 → 조치 후 호스트 200. 해결
```

**가설 → 검증 순서를 지킨 이유**: "접속이 안 된다"의 원인 후보는 프로세스, 리슨 주소, 네트워크 경로 세 층에 걸쳐 있다.
안쪽에서 `200`이 나온다는 사실 하나로 프로세스 층을 먼저 배제했고, `ss` 한 줄로 리슨 주소를 배제했다. 그래서 남은 경로 층만 집중해 볼 수 있었다.
컨테이너 IP로 직접 부르면 `200`이라는 결과는 "서버 문제가 아니다"를 확정하는 근거였다. 덕분에 서버 설정을 건드리지 않고 경로만 고쳤다.

---

## AWS 실행 시 사례 기입란

> ⏳ AWS 실행 후 기입. `./deploy.sh`·`./verify.sh`·`./cleanup.sh` 실행 중 문제가 생기면 아래 표를 채운다.
> 근거는 `evidence/aws/*.txt`, 스크립트의 `[ERROR]` 출력, EC2 안의 `/var/log/cloud-init-output.log`·`/var/log/nginx/error.log`에서 가져온다.

| 단계 | 내용 |
|---|---|
| 증상 | ⏳ AWS 실행 후 기입 |
| 가설 | ⏳ AWS 실행 후 기입 |
| 검증 (명령과 출력) | ⏳ AWS 실행 후 기입 |
| 조치 | ⏳ AWS 실행 후 기입 |
| 결과 | ⏳ AWS 실행 후 기입 |
| 재발 방지 | ⏳ AWS 실행 후 기입 |

문제가 없었다면 "AWS 실행에서는 문제 없이 6/6 통과(`evidence/aws/04-verify.txt`)"라고 적는다.

---

## 외부 접속 불가 점검 순서

`http://<퍼블릭IP>/health`가 응답하지 않을 때 **패킷이 지나가는 순서대로, 바깥에서 안으로** 확인한다.
앞 단계가 막혀 있으면 뒤 단계는 볼 필요가 없고, 앞 단계일수록 확인 명령이 싸다(조회 한 번).
`<…>` 값은 `state/resources.env`에 있다. 명령은 `.env`의 키를 환경변수로 불러온 뒤 실행한다(예: `set -a; . ./.env; set +a`).

| 순서 | 무엇을 보나 | 확인 명령 | 정상이면 |
|---|---|---|---|
| 1. 라우팅 | 서브넷 라우트 테이블에 `0.0.0.0/0 → igw-…`가 있고 active인가, 그 테이블이 우리 서브넷에 연결돼 있나, IGW가 VPC에 붙어 있나 | `aws ec2 describe-route-tables --route-table-ids <RT_ID> --query 'RouteTables[0].[Routes,Associations]'`<br>`aws ec2 describe-internet-gateways --internet-gateway-ids <IGW_ID> --query 'InternetGateways[0].Attachments'` | `DestinationCidrBlock 0.0.0.0/0`, `GatewayId igw-…`, `State active` / 연결에 `SubnetId <SUBNET_ID>` / `State available` |
| 2. Security Group | 인바운드에 80(0.0.0.0/0)이 있나, 22의 소스가 **지금의** 내 IP인가 | `aws ec2 describe-security-groups --group-ids <SG_ID> --query 'SecurityGroups[0].IpPermissions'`<br>`curl https://checkip.amazonaws.com` | 80 ← `0.0.0.0/0`, 22 ← `<내 IP>/32` (IP가 바뀌었으면 [SSH 허용 IP 갱신](#ssh-허용-ip-갱신)) |
| 3. 퍼블릭 IP·DNS | 인스턴스에 퍼블릭 IP가 있나, 내가 부르는 주소가 그 IP인가(중지·시작하면 바뀐다) | `aws ec2 describe-instances --instance-ids <INSTANCE_ID> --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]'` | `running`, IP가 URL과 같다. `None`이면 서브넷 자동 할당(`MapPublicIpOnLaunch`) 확인 |
| 4. 서버 프로세스·로그 | Nginx가 떠서 80에 리슨하나, user-data가 끝까지 돌았나 | SSH 접속 후 `systemctl status nginx`, `sudo ss -tlnp \| grep ':80'`, `curl -i http://localhost/health`, `sudo tail -50 /var/log/cloud-init-output.log`, `sudo tail /var/log/nginx/error.log` | `active (running)`, `0.0.0.0:80 LISTEN`, `200 OK` |

- 네트워크 ACL은 이 구성에서 기본값(전체 허용)을 바꾸지 않았다. 1~3이 정상인데도 막히면 `aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=<SUBNET_ID>`로 확인한다.
- SSH가 안 돼서 4단계를 못 볼 때는 EC2 콘솔의 **인스턴스 → 작업 → 모니터링 및 문제 해결 → 시스템 로그 가져오기**로 부팅 로그를 본다. CLI(`aws ec2 get-console-output`)는 `ec2:GetConsoleOutput` 권한이 필요하다. 이 권한은 최소권한 정책에 넣지 않았으므로, 필요할 때 관리자가 그 액션만 추가한다.
- `verify.sh`의 결과 표는 이 순서를 반영한다. 외부 `/health`가 실패하고 SSH는 성공하면 4단계(프로세스)가 원인이다. 둘 다 실패하면 1~3단계(경로)가 원인이다.

---

## SSH 허용 IP 갱신

집·카페처럼 네트워크가 바뀌면 공인 IP도 바뀐다. 그러면 SG의 `22 ← 이전IP/32` 규칙 때문에 SSH가 막힌다. `deploy.sh`는 이 상황을 감지하면 경고만 하고 규칙을 넓히지 않는다.
**0.0.0.0/0으로 넓히지 말고** 이전 규칙을 지운 뒤 새 IP 하나만 추가한다.

```bash
set -a; . ./.env; set +a
SG_ID=$(sed -n 's/^SG_ID=//p' state/resources.env)
OLD=$(sed -n 's/^SSH_CIDR=//p' state/resources.env)
NEW="$(curl -s https://checkip.amazonaws.com)/32"
aws ec2 revoke-security-group-ingress    --region ap-northeast-2 --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$OLD"
aws ec2 authorize-security-group-ingress --region ap-northeast-2 --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$NEW"
sed -i "s|^SSH_CIDR=.*|SSH_CIDR=$NEW|" state/resources.env
```

---

## IAM 권한 부족 (UnauthorizedOperation)

증상 예: `An error occurred (UnauthorizedOperation) when calling the RunInstances operation: You are not authorized to perform this operation. Encoded authorization failure message: …`

1. **어떤 API가 막혔는지 읽는다.** 오류 문구의 `when calling the <작업> operation`이 곧 IAM 액션 이름이다(`RunInstances` → `ec2:RunInstances`).
2. **정책과 대조한다.** [`iam/least-privilege-policy.json`](../iam/least-privilege-policy.json)에 그 액션이 있는지, 리전 조건(`ap-northeast-2`)이나 인스턴스 유형 Deny(`t2/t3.micro` 외 금지)에 걸린 것은 아닌지 본다.
3. **원인을 해독한다(관리자).** `aws sts decode-authorization-message --encoded-message <메시지>`는 어떤 액션·리소스·조건 때문에 거부됐는지 JSON으로 보여 준다. 실습 사용자에게는 이 권한이 없으므로 관리자 IAM 사용자가 실행한다. CloudTrail 이벤트 기록에서 `errorCode: Client.UnauthorizedOperation`을 찾아도 된다.
4. **그 액션 하나만 추가한다.** 같은 리전 조건을 붙여 정책의 새 버전을 올린다(`aws iam create-policy-version --set-as-default`). 반영 전에 `aws iam simulate-principal-policy`로 허용 여부를 미리 확인할 수 있다.
5. **넓히지 않는다.** `ec2:*`, `*`, `AdministratorAccess`로 "일단 되게" 만들지 않는다. 그렇게 하면 실습과 무관한 권한까지 한꺼번에 열린다. 키가 새면 피해 범위도 계정 전체가 된다.

`tests/run.sh`의 `test_iam_policy_covers_every_ec2_call_in_scripts`가 스크립트에 나오는 모든 `aws ec2 <작업>`을 정책과 대조한다. 그래서 스크립트를 고치고 정책을 깜빡하면 AWS에 가기 전에 테스트가 먼저 실패한다.

---

## 설계 단계에서 미리 막은 문제

아래는 **실제로 겪은 장애가 아니라**, 코드를 쓰면서 공식 동작을 근거로 미리 막은 항목이다(재현 증거 없음).

| 위험 | 어떻게 막았나 |
|---|---|
| `describe-instance-types`는 `t2.micro`에 대해 `["i386","x86_64"]`를 돌려준다. 첫 값만 보면 i386으로 오판해 AMI를 못 찾는다 | 목록에 `x86_64`/`arm64`가 **포함**됐는지로 판단 (`deploy.sh` `step_ami`) |
| 첫 부팅 직후 자동 업데이트가 apt 잠금을 잡아 `apt-get install`이 실패할 수 있다 | `DPkg::Lock::Timeout=300` + `update` 3회 재시도 (`server/user-data.sh`) |
| 인스턴스 종료 직후에는 ENI가 아직 남아 SG·Subnet 삭제가 `DependencyViolation`으로 실패할 수 있다 | 그 오류일 때만 10초 간격으로 최대 12회 재시도 (`cleanup.sh` `try`) |
| IP 자동 감지 실패 시 SSH를 넓게 열어 버리는 실수 | IPv4가 아니면 **중단**하고 `MY_IP`를 직접 넣게 안내 (`lib/common.sh` `detect_my_ip`) |
| 중간 실패 후 다시 실행하면 VPC가 2개 생기는 문제 | 리소스 ID를 만들자마자 `state/resources.env`에 저장하고, 있으면 건너뜀. 상태 파일을 잃어도 `cleanup.sh`가 태그로 찾아 지움 |
