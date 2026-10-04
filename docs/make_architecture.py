"""B3-1 아키텍처 다이어그램(docs/architecture.png)을 Pillow로 그린다.

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
    if bg is not None:
        box = d.multiline_textbbox(xy, text, font=f, anchor=anchor, spacing=6)
        d.rectangle([box[0] - 6, box[1] - 4, box[2] + 6, box[3] + 4], fill=bg)
    d.multiline_text(xy, text, font=f, fill=color, anchor=anchor, spacing=6)


def boundary(d, box, color, title, width=3, fill=None):
    d.rounded_rectangle(box, radius=18, outline=color, width=width, fill=fill)
    label(d, (box[0] + 18, box[1] + 12), title, size=21, color=color, bold=True)


def main():
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    label(d, (W // 2, 26), "B3-1 웹 서비스 아키텍처 — 외부 → Internet Gateway → Public Subnet → Security Group → EC2(Nginx)",
          size=27, bold=True, anchor="ma")

    # 바깥: 사용자와 운영자
    d.rounded_rectangle([40, 360, 270, 560], radius=16, outline=INK, width=3, fill=(246, 248, 250))
    label(d, (155, 378), "인터넷", size=24, bold=True, anchor="ma")
    label(d, (155, 418), "사용자 / 학습자 PC\n브라우저 · curl · ssh\n(내 공인 IP = MY_IP)", size=19, color=MUTED, anchor="ma")

    d.rounded_rectangle([40, 110, 270, 300], radius=16, outline=MUTED, width=2, fill=(250, 250, 252))
    label(d, (155, 124), "운영자 PC", size=21, bold=True, anchor="ma")
    label(d, (155, 160), "./deploy.sh · cleanup.sh\n→ AWS API (HTTPS)\nIAM 사용자 b3-1-operator\n최소권한: EC2·VPC·SG·키페어\n서울 리전 · t2/t3.micro만",
          size=16, color=MUTED, anchor="ma")

    # AWS 리전 → VPC → 서브넷 → SG
    boundary(d, [320, 90, 1570, 870], REGION, "AWS 클라우드 — 서울 리전 ap-northeast-2   (모든 리소스 태그: Project=b3-1)")
    dashed_line(d, (270, 205), (320, 205), MUTED, width=2)
    arrow_head(d, (320, 205), (270, 205), MUTED, size=12)
    label(d, (328, 214), "AWS API\n(IAM 통제)", size=14, color=MUTED)

    boundary(d, [430, 150, 1540, 840], VPC, "VPC b3-1-vpc  10.0.0.0/16  (DNS 호스트 이름 사용)")
    boundary(d, [610, 250, 1510, 660], SUBNET,
             "Public Subnet b3-1-public-subnet  10.0.1.0/24 · ap-northeast-2a · 퍼블릭 IP 자동 할당")

    sg_box = (790, 315, 1480, 640)
    dashed_rect(d, sg_box, SG, width=3)
    label(d, (sg_box[0] + 16, sg_box[1] + 10), "Security Group b3-1-web-sg  (패킷 통제)", size=19, color=SG, bold=True)
    label(d, (sg_box[0] + 16, sg_box[1] + 40),
          "인바운드 허용: TCP 80 ← 0.0.0.0/0   ·   TCP 22 ← 내 IP/32   ·   그 외 전부 차단\n아웃바운드: 전체 허용(기본값)",
          size=16, color=SG)

    # EC2
    ec2 = (880, 430, 1420, 625)
    d.rounded_rectangle(ec2, radius=12, outline=EC2, width=3, fill=(255, 247, 238))
    d.rounded_rectangle([ec2[0], ec2[1], ec2[2], ec2[1] + 40], radius=12, fill=EC2)
    label(d, (ec2[0] + 16, ec2[1] + 6), "EC2 b3-1-web · t3.micro · Ubuntu 24.04 LTS", size=20, color="white", bold=True)
    label(d, (ec2[0] + 16, ec2[1] + 52),
          "Nginx :80\n  GET /        → Hello Cloud 페이지 (방식 A)\n  GET /health  → 200 \"OK\" (방식 B, 검증 대상)\nEBS gp3 8GiB(종료 시 삭제) · IMDSv2 필수 · 키페어 b3-1-key\n퍼블릭 IP: 시작할 때 서브넷이 자동 할당 (EIP 미사용)",
          size=17, color=INK)

    # Internet Gateway (VPC 경계에 걸쳐 배치)
    igw = (360, 420, 500, 540)
    d.rounded_rectangle(igw, radius=14, outline=IGW, width=3, fill=(245, 238, 252))
    label(d, (430, 440), "Internet\nGateway\nb3-1-igw", size=18, color=IGW, bold=True, anchor="ma")

    # Route Table
    rt = (610, 690, 1060, 810)
    d.rounded_rectangle(rt, radius=12, outline=VPC, width=3, fill=(248, 244, 253))
    label(d, (rt[0] + 16, rt[1] + 10), "Route Table b3-1-public-rt", size=19, color=VPC, bold=True)
    label(d, (rt[0] + 16, rt[1] + 42), "10.0.0.0/16 → local\n0.0.0.0/0   → Internet Gateway", size=17, color=INK)
    d.line([(760, 660), (760, 690)], fill=VPC, width=3)
    label(d, (772, 664), "서브넷에 명시적 연결", size=15, color=VPC)

    # 인바운드: HTTP(파랑), SSH(초록)
    arrow(d, [(270, 460), (360, 460)], INBOUND_HTTP)
    arrow(d, [(500, 460), (880, 460)], INBOUND_HTTP)
    label(d, (520, 425), "① HTTP 80 — 누구나 (0.0.0.0/0)", size=17, color=INBOUND_HTTP, bold=True, bg="white")
    arrow(d, [(270, 505), (360, 505)], INBOUND_SSH)
    arrow(d, [(500, 505), (880, 505)], INBOUND_SSH)
    label(d, (520, 513), "② SSH 22 — 내 IP/32만", size=17, color=INBOUND_SSH, bold=True, bg="white")

    # 아웃바운드: EC2 → (Route Table 0.0.0.0/0) → IGW → 인터넷
    arrow(d, [(950, 625), (950, 690)], OUTBOUND, dashed=True)
    arrow(d, [(610, 760), (470, 760), (470, 540)], OUTBOUND, dashed=True)
    arrow(d, [(390, 540), (390, 548), (270, 548)], OUTBOUND, dashed=True)
    label(d, (966, 664), "③ 아웃바운드 (apt 설치 · curl https://example.com)", size=16, color=OUTBOUND, bold=True, bg="white")
    label(d, (440, 790), "0.0.0.0/0 → IGW", size=15, color=OUTBOUND, bg="white")

    # 범례
    ly = 900
    d.rounded_rectangle([40, ly - 18, 1560, ly + 78], radius=12, outline=(210, 214, 220), width=2, fill=(250, 251, 252))
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
    label(d, (60, ly + 34),
          "요청이 EC2에 닿는 조건: ① 서브넷 라우트 0.0.0.0/0 → IGW  ② 인스턴스 퍼블릭 IP  ③ SG 인바운드 허용  ④ Nginx가 :80에서 리슨.  "
          "SG는 '어떤 패킷이 들어오나', IAM은 '누가 어떤 AWS API를 부르나'를 통제한다.",
          size=16, color=MUTED)

    img.save(OUT)
    print(f"saved {OUT} ({W}x{H})")


if __name__ == "__main__":
    main()
