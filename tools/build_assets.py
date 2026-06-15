import os, json, shutil
from gen_icon import render, render_back, render_front

ROOT = os.path.join(os.path.dirname(__file__), "..", "VadaWeb", "Assets.xcassets")
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}


def wjson(path, obj):
    with open(os.path.join(path, "Contents.json"), "w") as f:
        json.dump(obj, f, indent=2)


def make_imageset(path, sizes, fn_render):
    """sizes: list of (scale, (W,H)); fn_render(W,H) -> PIL image"""
    os.makedirs(path, exist_ok=True)
    images = []
    for scale, (W, H) in sizes:
        fn = f"img_{scale}.png"
        fn_render(W, H).save(os.path.join(path, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    wjson(path, {"images": images, "info": INFO})


def make_layer(stack_path, name, sizes, fn_render):
    layer = os.path.join(stack_path, f"{name}.imagestacklayer")
    os.makedirs(layer, exist_ok=True)
    wjson(layer, {"info": INFO})
    make_imageset(os.path.join(layer, "Content.imageset"), sizes, fn_render)


def make_imagestack(path, sizes):
    """앞(Front: 메쉬+텍스트) / 뒤(Back: 배경) 2개 레이어로 패럴랙스 구성."""
    os.makedirs(path, exist_ok=True)
    wjson(path, {"info": INFO, "layers": [
        {"filename": "Front.imagestacklayer"},
        {"filename": "Back.imagestacklayer"},
    ]})
    make_layer(path, "Front", sizes, render_front)
    make_layer(path, "Back", sizes, render_back)


def build():
    if os.path.exists(BRAND):
        shutil.rmtree(BRAND)
    os.makedirs(BRAND, exist_ok=True)

    # 홈 화면 아이콘 (5:3)
    make_imagestack(os.path.join(BRAND, "App Icon.imagestack"),
                    [("1x", (400, 240)), ("2x", (800, 480))])
    # App Store 아이콘 (1x만)
    make_imagestack(os.path.join(BRAND, "App Icon - App Store.imagestack"),
                    [("1x", (1280, 768))])
    # 탑셸프 (가로 배너)
    make_imageset(os.path.join(BRAND, "Top Shelf Image.imageset"),
                  [("1x", (1920, 720)), ("2x", (3840, 1440))], render)
    make_imageset(os.path.join(BRAND, "Top Shelf Image Wide.imageset"),
                  [("1x", (2320, 720)), ("2x", (4640, 1440))], render)

    wjson(BRAND, {
        "assets": [
            {"filename": "App Icon.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "400x240"},
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
             "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "Top Shelf Image.imageset", "idiom": "tv",
             "role": "top-shelf-image", "size": "1920x720"},
            {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
             "role": "top-shelf-image-wide", "size": "2320x720"},
        ],
        "info": INFO,
    })
    print("brand assets written to", BRAND)


if __name__ == "__main__":
    build()
