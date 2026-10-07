"""B3-1 아키텍처 다이어그램(docs/architecture.png)을 Pillow로 그린다(Nginx :80 → ai_chatbot 127.0.0.1:8000 → SQLite).

실행: python3 docs/make_architecture.py  → docs/architecture.png (1600x1000)
런타임 의존성이 아니라 문서 생성용 스크립트다. 폰트는 Noto Sans CJK를 쓴다.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1600, 1000
FONT_DIR = Path("/usr/share/fonts/opentype/noto")
OUT = Path(__file__).resolve().parent / "architecture.png"

INK = (33, 37, 41)
MUTED = (96, 103, 112)
REGION = (232, 120, 30)
VPC = (124, 77, 190)
SUBNET = (46, 139, 87)
SG = (214, 51, 51)
EC2 = (237, 125, 49)
IGW = (125, 60, 152)
INBOUND_HTTP = (30, 100, 200)
INBOUND_SSH = (20, 140, 110)
OUTBOUND = (226, 120, 20)


def font(size, bold=False):
    """한글이 들어간 Noto Sans CJK(KR 변형, TTC 인덱스 1)를 연다."""
    name = "NotoSansCJK-Bold.ttc" if bold else "NotoSansCJK-Regular.ttc"
    return ImageFont.truetype(str(FONT_DIR / name), size, index=1)


def dashed_line(d, p1, p2, color, width=3, dash=14, gap=9):
    """두 점 사이에 점선을 그린다(Pillow에는 점선 옵션이 없다)."""
    (x1, y1), (x2, y2) = p1, p2
    length = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
    if length == 0:
        return
    ux, uy = (x2 - x1) / length, (y2 - y1) / length
    pos = 0.0
    while pos < length:
        end = min(pos + dash, length)
        d.line([(x1 + ux * pos, y1 + uy * pos), (x1 + ux * end, y1 + uy * end)], fill=color, width=width)
        pos += dash + gap


def dashed_rect(d, box, color, width=3):
    x1, y1, x2, y2 = box
    for a, b in [((x1, y1), (x2, y1)), ((x2, y1), (x2, y2)), ((x2, y2), (x1, y2)), ((x1, y2), (x1, y1))]:
        dashed_line(d, a, b, color, width)


def arrow_head(d, tip, frm, color, size=16):
    """frm → tip 방향의 화살촉을 tip에 그린다."""
    (tx, ty), (fx, fy) = tip, frm
    length = ((tx - fx) ** 2 + (ty - fy) ** 2) ** 0.5
    ux, uy = (tx - fx) / length, (ty - fy) / length
    px, py = -uy, ux
    base = (tx - ux * size, ty - uy * size)
    d.polygon(
        [tip, (base[0] + px * size * 0.55, base[1] + py * size * 0.55), (base[0] - px * size * 0.55, base[1] - py * size * 0.55)],
        fill=color,
    )


def arrow(d, points, color, dashed=False, width=4):
    """여러 점을 잇는 화살표(마지막 점에 화살촉)."""
    for a, b in zip(points, points[1:]):
        if dashed:
            dashed_line(d, a, b, color, width)
        else:
            d.line([a, b], fill=color, width=width)
    arrow_head(d, points[-1], points[-2], color)


def label(d, xy, text, size=20, color=INK, bold=False, anchor="la", bg=None):
    f = font(size, bold)
    # 가운데 기준(ma)으로 놓은 여러 줄 글은 줄마다 가운데 정렬한다
    align = "center" if anchor[0] == "m" else "left"
    if bg is not None:
        box = d.multiline_textbbox(xy, text, font=f, anchor=anchor, spacing=6, align=align)
        d.rectangle([box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4], fill=bg)
    d.multiline_text(xy, text, font=f, fill=color, anchor=anchor, spacing=6, align=align)


def boundary(d, box, color, title, width=3, fill=None):
    d.rounded_rectangle(box, radius=18, outline=color, width=width, fill=fill)
    label(d, (box[0] + 18, box[1] + 12), title, size=21, color=color, bold=True)


def main():
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    label(d, (W // 2, 26),
          "B3-1 웹 서비스 아키텍처 — 외부 → IGW → Public Subnet → Security Group → EC2(Nginx → ai_chatbot)",
          size=27, bold=True, anchor="ma")

    # 바깥: 운영자, 사용자, 외부 서비스
    d.rounded_rectangle([40, 100, 290, 330], radius=16, outline=MUTED, width=2, fill=(250, 250, 252))
    label(d, (165, 112), "운영자 PC", size=21, bold=True, anchor="ma")
    label(d, (165, 146),
          "deploy.sh · verify.sh · cleanup.sh\n→ AWS API (HTTPS, IAM 통제)\n→ SSH 22: 앱 소스·.env 전송\nIAM 사용자 b3-1-operator\n최소권한: EC2·VPC·SG·키페어\n서울 리전 · t2/t3.micro만",
          size=14, color=MUTED, anchor="ma")

    d.rounded_rectangle([40, 380, 290, 620], radius=16, outline=INK, width=3, fill=(246, 248, 250))
    label(d, (165, 396), "인터넷", size=24, bold=True, anchor="ma")
    label(d, (165, 436), "사용자 / 학습자 PC\n브라우저 · curl · ssh\n(내 공인 IP = MY_IP)", size=18, color=MUTED, anchor="ma")

    d.rounded_rectangle([40, 680, 290, 870], radius=16, outline=OUTBOUND, width=2, fill=(255, 249, 240))
    label(d, (165, 692), "외부 서비스 (아웃바운드)", size=17, color=OUTBOUND, bold=True, anchor="ma")
    label(d, (165, 724),
          "Codyssey LLM API\n(copa.codyssey.kr)\n네이버 뉴스·데이터랩 API\nPyPI · Ubuntu apt 미러\nexample.com (점검)",
          size=15, color=INK, anchor="ma")

    # AWS 리전 → VPC → 서브넷 → SG
    boundary(d, [320, 90, 1570, 870], REGION, "AWS 클라우드 — 서울 리전 ap-northeast-2   (모든 리소스 태그: Project=b3-1)")
    dashed_line(d, (290, 205), (320, 205), MUTED, width=2)
    arrow_head(d, (320, 205), (290, 205), MUTED, size=12)
    label(d, (328, 214), "AWS API\n(IAM 통제)", size=14, color=MUTED)

    boundary(d, [430, 150, 1540, 840], VPC, "VPC b3-1-vpc  10.0.0.0/16  (DNS 호스트 이름 사용)")
    boundary(d, [610, 220, 1510, 672], SUBNET,
             "Public Subnet b3-1-public-subnet  10.0.1.0/24 · ap-northeast-2a · 퍼블릭 IP 자동 할당")

    sg_box = (780, 266, 1497, 658)
    dashed_rect(d, sg_box, SG, width=3)
    label(d, (sg_box[0] + 16, sg_box[1] + 6), "Security Group b3-1-web-sg  (패킷 통제)", size=19, color=SG, bold=True)
    label(d, (sg_box[0] + 16, sg_box[1] + 34),
          "인바운드 허용: TCP 80 ← 0.0.0.0/0  ·  TCP 22 ← 내 IP/32  ·  그 외(8000 포함) 전부 차단\n"
          "아웃바운드: 전체 허용(기본값) — apt·pip 설치, LLM·네이버 API, example.com",
          size=15, color=SG)

    # EC2와 그 안의 Nginx → 앱 → SQLite
    ec2 = (805, 350, 1482, 645)
    d.rounded_rectangle(ec2, radius=12, outline=EC2, width=3, fill=(255, 247, 238))
    d.rounded_rectangle([ec2[0], ec2[1], ec2[2], ec2[1] + 38], radius=12, fill=EC2)
    label(d, (ec2[0] + 14, ec2[1] + 6),
          "EC2 b3-1-web · t3.micro · Ubuntu 24.04 LTS · IMDSv2 · EBS gp3 8GiB",
          size=19, color="white", bold=True)

    nginx = (825, 400, 1010, 520)
    d.rounded_rectangle(nginx, radius=10, outline=INBOUND_HTTP, width=3, fill=(236, 244, 255))
    label(d, ((nginx[0] + nginx[2]) // 2, nginx[1] + 10), "Nginx", size=20, color=INBOUND_HTTP, bold=True, anchor="ma")
    label(d, ((nginx[0] + nginx[2]) // 2, nginx[1] + 42), "0.0.0.0:80\n프록시(read 90s)\nsystemd nginx", size=15, color=INK, anchor="ma")

    app = (1060, 400, 1290, 520)
    d.rounded_rectangle(app, radius=10, outline=SUBNET, width=3, fill=(236, 248, 241))
    label(d, ((app[0] + app[2]) // 2, app[1] + 10), "ai_chatbot (FastAPI)", size=18, color=SUBNET, bold=True, anchor="ma")
    label(d, ((app[0] + app[2]) // 2, app[1] + 40), "uvicorn 127.0.0.1:8000\nworkers 1 · .env(600)\nsystemd ai-chatbot", size=15, color=INK, anchor="ma")

    db = (1330, 400, 1468, 520)
    d.rounded_rectangle(db, radius=10, outline=VPC, width=3, fill=(246, 241, 253))
    label(d, ((db[0] + db[2]) // 2, db[1] + 10), "SQLite", size=18, color=VPC, bold=True, anchor="ma")
    label(d, ((db[0] + db[2]) // 2, db[1] + 42), "app.db\n가입·대화 기록\n(종료 시 삭제)", size=15, color=INK, anchor="ma")

    arrow(d, [(1010, 460), (1060, 460)], INBOUND_HTTP, width=3)
    arrow(d, [(1290, 460), (1330, 460)], VPC, width=3)

    label(d, (ec2[0] + 18, 534),
          "GET /health → 앱이 200 {\"status\":\"ok\"} (방식 B, 검증 대상)\n"
          "GET / → 비로그인 303 → /login → 로그인 화면 200 (방식 A, curl -L)\n"
          "8000은 서버 안(127.0.0.1)에서만 · 앱 .env는 SSH로 전달(user-data에 비밀값 없음)",
          size=15, color=INK)

    # Internet Gateway (VPC 경계에 걸쳐 배치)
    igw = (360, 420, 500, 600)
    d.rounded_rectangle(igw, radius=14, outline=IGW, width=3, fill=(245, 238, 252))
    label(d, (430, 470), "Internet\nGateway\nb3-1-igw", size=18, color=IGW, bold=True, anchor="ma")

    # Route Table
    rt = (610, 700, 1060, 820)
    d.rounded_rectangle(rt, radius=12, outline=VPC, width=3, fill=(248, 244, 253))
    label(d, (rt[0] + 16, rt[1] + 10), "Route Table b3-1-public-rt", size=19, color=VPC, bold=True)
    label(d, (rt[0] + 16, rt[1] + 42), "10.0.0.0/16 → local\n0.0.0.0/0   → Internet Gateway", size=17, color=INK)
    d.line([(760, 672), (760, 700)], fill=VPC, width=3)
    label(d, (772, 676), "서브넷에 명시적 연결", size=14, color=VPC)

    # 인바운드: HTTP(파랑) → Nginx, SSH(초록) → EC2
    arrow(d, [(290, 460), (360, 460)], INBOUND_HTTP)
    arrow(d, [(500, 460), (825, 460)], INBOUND_HTTP)
    label(d, (515, 424), "① HTTP 80 — 누구나 (0.0.0.0/0)", size=17, color=INBOUND_HTTP, bold=True, bg="white")
    arrow(d, [(290, 575), (360, 575)], INBOUND_SSH)
    arrow(d, [(500, 575), (805, 575)], INBOUND_SSH)
    label(d, (515, 584), "② SSH 22 — 내 IP/32만\n(관리 · 앱 소스·.env 전송)", size=16, color=INBOUND_SSH, bold=True, bg="white")

    # 아웃바운드: EC2 → (Route Table 0.0.0.0/0) → IGW → 인터넷의 외부 서비스
    arrow(d, [(1100, 645), (1100, 700)], OUTBOUND, dashed=True)
    arrow(d, [(610, 760), (470, 760), (470, 600)], OUTBOUND, dashed=True)
    arrow(d, [(390, 600), (390, 775), (290, 775)], OUTBOUND, dashed=True)
    label(d, (1112, 676), "③ 아웃바운드: apt·pip 설치, LLM·네이버 API, example.com", size=15, color=OUTBOUND, bold=True, bg="white")
    label(d, (480, 790), "0.0.0.0/0 → IGW", size=15, color=OUTBOUND, bg="white")

    # 범례
    ly = 900
    d.rounded_rectangle([40, ly - 18, 1560, ly + 82], radius=12, outline=(210, 214, 220), width=2, fill=(250, 251, 252))
    label(d, (60, ly - 6), "범례", size=19, bold=True)
    arrow(d, [(140, ly + 6), (220, ly + 6)], INBOUND_HTTP)
    label(d, (230, ly - 6), "인바운드 HTTP 80", size=17)
    arrow(d, [(410, ly + 6), (490, ly + 6)], INBOUND_SSH)
    label(d, (500, ly - 6), "인바운드 SSH 22", size=17)
    arrow(d, [(670, ly + 6), (750, ly + 6)], OUTBOUND, dashed=True)
    label(d, (760, ly - 6), "아웃바운드 (점선)", size=17)
    dashed_rect(d, (950, ly - 6, 1010, ly + 18), SG, width=2)
    label(d, (1020, ly - 6), "보안 그룹 경계 (점선)", size=17)
    d.rounded_rectangle([1230, ly - 6, 1290, ly + 18], radius=6, outline=VPC, width=2)
    label(d, (1300, ly - 6), "VPC·서브넷 경계", size=17)
    label(d, (60, ly + 32),
          "요청이 앱에 닿는 조건: ① 서브넷 라우트 0.0.0.0/0 → IGW  ② 인스턴스 퍼블릭 IP  ③ SG 인바운드 80 허용  ④ Nginx가 :80에서 리슨  "
          "⑤ 앱(uvicorn)이 127.0.0.1:8000에서 응답.\n"
          "8000은 SG에도 열지 않고 127.0.0.1에만 바인딩한다. SG는 '어떤 패킷이 들어오나', IAM은 '누가 어떤 AWS API를 부르나'를 통제한다.",
          size=15, color=MUTED)

    img.save(OUT)
    print(f"saved {OUT} ({W}x{H})")


if __name__ == "__main__":
    main()
