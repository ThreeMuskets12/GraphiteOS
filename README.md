# GraphiteOS

A minimal-diff fork of [GrapheneOS](https://grapheneos.org) for the Pixel 9 Pro (`caiman`).

The only change from GrapheneOS is a display filter. Everything on the built-in screen looks like it is on a color e-ink panel:

- warm, desaturated colors
- a palette of about 300 colors with 2px ordered dithering
- an output refresh of about 15 fps

Apps are unaware of the filter. They render and present frames at the normal rate. The filter is skipped for:

- camera apps
- photo apps
- video calls, while video is showing

External displays (casting, Android Auto, wired monitors) and screenshots are unaffected.

The patches apply on top of upstream GrapheneOS release tags. CI follows the upstream stable channel, then builds, signs, and publishes OTA updates. Those updates install through the standard GrapheneOS Updater.

**Status:** work in progress.
