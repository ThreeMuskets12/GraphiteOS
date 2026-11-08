"""Preview the GraphiteOS e-ink filter on an image (same math as kEinkSkSL in the SurfaceFlinger patch).

Usage: uv run --with pillow --with numpy python tools/einkfilter.py input.png output.png
"""
import sys

import numpy as np
from PIL import Image


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def bayer2(x, y):
    x, y = np.floor(x), np.floor(y)
    return np.mod(x / 2 + y * y * 0.75, 1.0)


def bayer8(x, y):
    return (bayer2(x / 4, y / 4) * 0.25 + bayer2(x / 2, y / 2)) * 0.25 + bayer2(x, y)


def eink(rgb):
    h, w = rgb.shape[:2]
    py, px = np.mgrid[0:h, 0:w] + 0.5  # pixel centres, like SkSL coords
    c = srgb_to_linear(rgb)
    l = np.cbrt(c @ [0.4122214708, 0.5363325363, 0.0514459929])
    m = np.cbrt(c @ [0.2119034982, 0.6806995451, 0.1073969566])
    s = np.cbrt(c @ [0.0883024619, 0.2817188376, 0.6299787005])
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    n = bayer8(np.floor(px / 2), np.floor(py / 2)) - 0.5 + 1 / 128
    t = np.clip(np.floor(np.clip(L, 0, 1) * 15 + n + 0.5), 0, 15) / 15
    chroma = np.hypot(A, B)
    k = np.clip(np.floor(np.clip(chroma * 0.38 / 0.09, 0, 1) * 3 + n + 0.5), 0, 3) / 3 * 0.09
    hue = np.where(chroma > 1e-5, np.floor(np.arctan2(B, A) / (2 * np.pi) * 12 + 0.5) / 12 * 2 * np.pi, 0)
    k *= np.minimum(1, 2.2 * np.minimum(t, 1 - t) + 0.25)
    L = 0.32 + 0.60 * t
    A = k * np.cos(hue) + 0.004 * t
    B = k * np.sin(hue) + 0.020 * t
    l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
    m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
    s = (L - 0.0894841775 * A - 1.2914855480 * B) ** 3
    out = np.stack([4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s], -1)
    return linear_to_srgb(out)


if __name__ == "__main__":
    src = np.asarray(Image.open(sys.argv[1]).convert("RGB")) / 255.0
    Image.fromarray((eink(src) * 255 + 0.5).astype(np.uint8)).save(sys.argv[2])
