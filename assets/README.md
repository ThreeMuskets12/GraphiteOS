# GraphiteOS brand kit

## github/
- `social-preview-1280x640.png` — repo **Settings → General → Social preview**.
- `avatar-500x500.png` — org or profile picture.
- `readme-banner-light.png` / `readme-banner-dark.png` — header for README.md. Put both in the repo (e.g. `.github/assets/`) and use this so GitHub picks the right one for each viewer's theme:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/assets/readme-banner-dark.png">
  <img alt="GraphiteOS — a GrapheneOS fork that looks like color e-paper" src=".github/assets/readme-banner-light.png">
</picture>
```

## logo/
Transparent PNGs: `graphiteos-app-icon.png` (512px app icon on its paper tile), `mark-color-1024.png` (default), `mark-graphite-1024.png` (one-color), `lockup-1600w.png` (mark + name), `favicon-32.png`, `favicon-180.png` (apple-touch / small sizes).

## svg/
Vector masters of everything above, text already converted to outlines (no fonts needed).

## boot/
Pixel 9 Pro boot animation, 1280×1280 at 15fps on the paper color (#ECE8DF). See `boot/README.md` for details.
- `intro/` (30 frames, 2s, plays once) and `loop/` (30 frames, 2s, repeats): numbered PNG sequences.
- `graphiteos-boot-intro-1280-15fps.mp4`, `graphiteos-boot-loop-1280-15fps.mp4`: the same as video.
- `bootanimation.zip`: both parts packaged in Android's format, stored uncompressed.
- `graphiteos-boot-static-1280.png`: static boot logo.
- `graphiteos-boot-preview.gif`: preview.

To ship it in your build, copy it to the product partition's `media/` folder, e.g. in your device or vendor makefile:

```make
PRODUCT_COPY_FILES += \
    path/to/bootanimation.zip:$(TARGET_COPY_OUT_PRODUCT)/media/bootanimation.zip
```

Check where your GrapheneOS tree currently sets its boot animation and replace that one, so the two don't conflict.

To test on a device without rebuilding (needs root or a userdebug build): `adb root && adb remount && adb push bootanimation.zip /product/media/ && adb reboot`.

Note: the very first logo at power-on on Pixels is the bootloader splash. It's part of Google's signed bootloader and can't be replaced; this animation is what comes right after it.
