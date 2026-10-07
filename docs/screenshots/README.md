# 스크린샷 (⏳ AWS 실행 후 추가)

AWS에서 직접 실행한 뒤 아래 두 장(필수)과 선택 한 장을 이 폴더에 저장한다. 가짜 화면은 넣지 않는다.

| 파일 | 내용 | 언제 |
|---|---|---|
| `health.png` | 브라우저 주소창에 `http://<퍼블릭IP>/health`가 보이고 본문 `{"status":"ok"}`가 표시된 화면 (방식 B 외부 접속 증빙, ai_chatbot 앱의 응답) | `./deploy.sh` 완료 직후 |
| `app.png` (선택) | `http://<퍼블릭IP>/`로 열린 PULSE 로그인 화면(또는 테스트 계정으로 로그인한 채팅 화면) (방식 A) | `./deploy.sh` 완료 직후 |
| `billing.png` | Billing 화면 또는 EC2 인스턴스 목록(terminated)·VPC 목록이 비어 있는 화면 (정리 증빙) | `./cleanup.sh` 완료 후 |

저장한 뒤 README의 "외부 접속 검증" 절과 `docs/cleanup-checklist.md`의 체크박스를 채운다.
