from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

# 네트워크 노드 (정규화 좌표, 오른쪽으로 몰리고 텍스트 오른쪽과 겹침)
NODES = [(0.55, 0.52), (0.63, 0.30), (0.78, 0.20), (0.90, 0.36), (0.72, 0.50),
         (0.88, 0.60), (0.66, 0.72), (0.81, 0.80), (0.96, 0.50), (0.58, 0.80)]
EDGES = [(0, 1), (1, 2), (2, 3), (1, 4), (4, 3), (4, 5), (3, 8), (5, 8), (4, 6),
         (6, 7), (7, 5), (0, 4), (6, 9), (0, 9), (5, 7)]

SUP = 2  # 슈퍼샘플링


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render_back(W, H):
    """배경 그라데이션 (불투명)."""
    w, h = W * SUP, H * SUP
    img = Image.new("RGB", (w, h))
    top, bot = (8, 22, 46), (10, 52, 74)
    px = img.load()
    for y in range(h):
        row = _lerp(top, bot, y / (h - 1))
        for x in range(w):
            px[x, y] = row
    return img.convert("RGBA").resize((W, H), Image.LANCZOS)


def render_front(W, H):
    """네트워크 메쉬 + 'Vada Web' 텍스트 (투명 배경)."""
    w, h = W * SUP, H * SUP
    base = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    mesh = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    md = ImageDraw.Draw(mesh)
    cyan = (80, 210, 235, 255)
    R = 0.020 * h
    lw = max(2, int(0.0055 * h))
    pts = [(int(x * w), int(y * h)) for (x, y) in NODES]
    for a, b in EDGES:
        md.line([pts[a], pts[b]], fill=(90, 200, 230, 180), width=lw)
    for (x, y) in pts:
        md.ellipse([x - R, y - R, x + R, y + R], fill=cyan)
        md.ellipse([x - R * 0.4, y - R * 0.4, x + R * 0.4, y + R * 0.4], fill=(220, 250, 255, 255))

    glow = mesh.filter(ImageFilter.GaussianBlur(int(0.018 * h)))
    base = Image.alpha_composite(base, glow)
    base = Image.alpha_composite(base, mesh)

    txt = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    td = ImageDraw.Draw(txt)
    fs = int(0.30 * h)
    font = ImageFont.truetype(FONT, fs)
    x0 = int(0.07 * w)
    line_h = int(fs * 1.02)
    y0 = int(h / 2 - line_h)
    for i, word in enumerate(["Vada", "Web"]):
        td.text((x0 + int(0.006 * h), y0 + i * line_h + int(0.006 * h)), word, font=font, fill=(0, 0, 0, 160))
        td.text((x0, y0 + i * line_h), word, font=font, fill=(255, 255, 255, 255))
    base = Image.alpha_composite(base, txt)

    # 텍스트 위로 겹치는 앞쪽 노드/선
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fd = ImageDraw.Draw(front)
    for a, b in [(0, 1), (0, 4), (0, 9)]:
        fd.line([pts[a], pts[b]], fill=(120, 220, 245, 210), width=lw)
    x, y = pts[0]
    fd.ellipse([x - R, y - R, x + R, y + R], fill=cyan)
    fd.ellipse([x - R * 0.4, y - R * 0.4, x + R * 0.4, y + R * 0.4], fill=(230, 252, 255, 255))
    fglow = front.filter(ImageFilter.GaussianBlur(int(0.012 * h)))
    base = Image.alpha_composite(base, fglow)
    base = Image.alpha_composite(base, front)

    return base.resize((W, H), Image.LANCZOS)


def render(W, H):
    """배경+전경 합성 (탑셸프 이미지 / 미리보기용, 불투명 RGB)."""
    out = Image.alpha_composite(render_back(W, H), render_front(W, H))
    return out.convert("RGB")


if __name__ == "__main__":
    render(800, 480).save("/tmp/icon_preview.png")
    print("saved /tmp/icon_preview.png")
