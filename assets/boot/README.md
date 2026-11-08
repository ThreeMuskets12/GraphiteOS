# GraphiteOS boot animation — Pixel 9 Pro

1280 × 1280 px, 15 fps, opaque PNGs on the paper color #ECE8DF.

| | frames | length |
|---|---|---|
| `intro/0000.png`–`0029.png` | 30 | 2.0 s, plays once |
| `loop/0000.png`–`0029.png` | 30 | 2.0 s, loops seamlessly until boot completes |

Intro: the hexagon outline draws itself, the three inner edges grow out from the centre, then the faces shade in (red hatch line by line, blue cross-hatch, ochre e-ink dither), then the GraphiteOS wordmark and a row of five grey squares fade in. Its last frame matches the loop's.

Loop: the five squares light up one at a time (red, ochre, green, blue, ink) as a loading indicator; everything else holds still.

Also included:
- `graphiteos-boot-intro-1280-15fps.mp4`, `graphiteos-boot-loop-1280-15fps.mp4`: the same two parts as video (H.264).
- `bootanimation.zip`: the two sequences already packaged in Android's format (`desc.txt`: `1280 1280 15`, intro plays once, loop repeats, background #ECE8DF; stored uncompressed).
- `graphiteos-boot-static-1280.png`: static boot logo, 1280 × 1280, with all five squares in color.
- `graphiteos-boot-preview.gif`: small preview.

Colors are already muted, and the darkest ink is #2E3033 (dark grey, not black), so the desaturation filter should change very little.
