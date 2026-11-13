# AGENTS.md

Notes for AI agents (and humans) working on GraphiteOS. `README.md` is the user-facing overview.
This file covers how the patches and the release pipeline work, and the rules for changing them.

## What this is

A minimal-diff fork of GrapheneOS for one device: the Pixel 9 Pro (`caiman`). There is no source
tree here. The repo holds patches against GrapheneOS projects, plus CI that applies them to each
new GrapheneOS stable tag, builds, signs and publishes an OTA on GitHub releases. Phones update
through the stock GrapheneOS Updater, which is pointed at this repo.

## Hard rules

- **Never brick the phone.** Anything that could stop it booting (signing keys, AVB, firmware,
  bootloader) gets checked with the owner first.
- **Minimal diff.** Touch as few upstream lines as possible, so patches keep applying to new
  upstream tags. Mark every change with a `GraphiteOS:` comment.
- **Signing keys never go in the repo.** They live only in GitHub secrets and the owner's offline
  backup. `.gitignore` blocks key files; only `certs/caiman/*.x509.pem` and `avb_pkmd.bin`
  (public) are committed. The dev server never gets the keys.
- **Never replace the keys.** If the keys change, installed phones can't take updates without a wipe.
- **The repo is public.** Treat anything committed, any Actions log and any artifact as public. The
  build server's SSH key passes between jobs encrypted for this reason.
- **Don't create Hetzner servers early.** They bill by the hour. CI creates them only after the
  patch and review checks pass, and deletes them when done.
- **Never ask for secret values in chat.** The owner sets them with `gh secret set`.
- **Commit author:** `ThreeMuskets12 <23061574+ThreeMuskets12@users.noreply.github.com>` (already
  set in the repo-local git config). Never commit as another identity.
- **Locking or unlocking the Pixel bootloader wipes the phone.** Say so before suggesting either.

## Layout

| Path | Contents |
|---|---|
| `patches/<project path>/*.patch` | `git format-patch` files, applied with `git am` in name order. The directory is the project's path in the GrapheneOS manifest. Adding a directory is all it takes to patch a new project; CI handles any project here. |
| `overlay/` | Files copied over the source tree as-is, at the same relative path. The build fails if the target file no longer exists upstream. |
| `ci/` | Release scripts (below). |
| `.github/workflows/` | `watch-upstream`, `release`, `cleanup`, `dev-server`. |
| `certs/caiman/` | Public signing certificates and the AVB public key `avb_pkmd.bin`. |
| `scripts/generate-keys.sh` | One-time key generation. Already run; refuses to run again. |
| `tools/einkfilter.py` | Previews the filter on an image using the shader's math: `uv run --with pillow --with numpy python -I tools/einkfilter.py in.png out.png`. Keep it in sync with the shader. |
| `assets/` | Brand kit, banners, boot animation sources. |
| `Reference/` | Local photos, gitignored. Never commit. |

## The patches

### frameworks/native

1. **`0001` e-ink look.** The core feature.
   - **SurfaceFlinger** forces GPU (client) composition on the primary display and flags its
     output for the filter.
   - **CompositionEngine** (`Output.cpp`) passes the flag through `CompositionRefreshArgs` and
     `OutputCompositionState`, and bypasses client-composition caching for e-ink frames.
   - **RenderEngine** (`SkiaRenderEngine::drawLayersInternal`) runs the composited frame through
     the SkSL shader `kEinkSkSL`.
   - **Frame rate:** a new filtered frame is shown only every 1/fps seconds; in between, the last
     filtered frame is shown again. Apps still latch and present at the normal rate, so the
     filter can't be detected from app code.
   - **Bypass:** `kEinkBypassApps` in `SurfaceFlinger.cpp` lists photo and camera apps, which skip
     the filter whenever they are visible. Calling apps skip it only while showing video (a
     visible SurfaceView). Camera buffers and protected (DRM) content also skip it.
   - **Never filtered:** screenshots (`ScreenCaptureOutput`), virtual displays and external
     displays.
   - **Toggle:** `adb shell service call SurfaceFlinger 1999 i32 <0|1>`. The caller check is in
     `onTransact`.
2. **`0002` tuning over adb.** Reads `debug.eink.*` properties (settable from the adb shell on
   user builds, reset on reboot) and passes them to the shader as uniforms.
   - Each value is parsed with `base::ParseFloat` with min/max bounds and a NaN check. Keep that
     for any new property.
   - **The defaults live in this patch.** The README tuning table must match them.
   - The commit messages of `0001` and `0002` still quote the old defaults (300 colors, 2px, 15
     fps). The code and README are what count.
3. **`0003` backlight cap.** In `SurfaceFlinger::setDisplayBrightness`, `debug.eink.maxbrightness`
   (0.05–1) scales down `displayBrightness`, `sdrWhitePoint` and the nits fields when they are
   positive (-1 means unknown). It takes effect on the next brightness change.

### packages/apps/Launcher3

**`0001` Private Space pinning.** Removes `FLAG_NOT_PINNABLE` for Private Space apps and shortcuts
(`AppInfo.java`, `WorkspaceItemInfo.java`).
- **Locked behavior:** while Private Space is locked, pinned icons get
  `FLAG_DISABLED_QUIET_USER` (greyed out). `ItemClickHandler.onClickAppShortcut` then calls
  `PrivateProfileManager.setQuietMode(false)` to ask for unlocking, instead of showing the
  framework's work-profile dialog.
- **Known tradeoff, accepted by the owner:** pinned icons stay visible while locked, which reveals
  that Private Space exists.
- **Widgets are out of scope.** `AppWidgetServiceImpl` would need a frameworks/base patch.

### packages/apps/Updater

**`0001` update URL.** Points the `url` string in `res/values/config.xml` at
`https://github.com/ThreeMuskets12/GraphiteOS/releases/latest/download/`.

### overlay

`branding/bootanimation/1280.zip` replaces the GrapheneOS boot animation. The build checks that it
ended up in the image.

## Changing a patch

The owner's Mac can't build AOSP (it needs x86_64 Linux, 32 GB+ RAM and ~250 GB of disk). Edit
patches on any machine; compile on a dev server or let a release build compile them.

1. Find the project's revision for the target tag in
   `https://raw.githubusercontent.com/GrapheneOS/platform_manifest/refs/tags/<TAG>/default.xml`.
   `ci/preflight.sh` shows how to look it up.
2. Clone the project, check out that revision, then `git am patches/<project>/*.patch`.
3. Make the change, either as an amend of the relevant commit or as a new commit. Keep one concern
   per patch.
4. Re-export with `git format-patch <rev>..HEAD -o patches/<project>/`. Delete the old files first
   if names changed.
5. Update `README.md` for anything user-visible (tuning table, feature list).
6. Update the review `PROMPT` in `ci/ai-review.py` when a patch's purpose changes. The review
   checks semantics against that description.
7. **Compile before releasing** when the change is non-trivial. Start the `Dev server` workflow
   (`action=start`, it auto-deletes after `hours`, `action=stop` when done), sync the tag, apply
   the patches, and build the module (e.g. `m surfaceflinger`). A release build that fails to
   compile costs a whole build-server run.

## Release pipeline

### `watch-upstream.yml`

Runs daily, but only when the repo variable `AUTO_RELEASE` is `true`. It compares GrapheneOS
`caiman-stable` with the `Upstream: GrapheneOS <tag>` line in our latest release body. When
upstream is newer and no release is running, it starts `release.yml`.

### `release.yml`

Can also be run by hand with inputs `tag`, `build_number` and `server_type`. Its steps:

1. **`ci/resolve-versions.sh`** works out the tag, the build number, and the previous release's
   tag and OTA timestamp. It refuses an existing build number or a tag older than the last
   release's, since that could mean older firmware than what's on the phone.
2. **`ci/preflight.sh`** runs on the free GitHub runner. For each patched project it clones the
   pinned revision and applies the patches with `git am -3`; a conflict stops here, before
   anything is billed. It writes the rebased patches to `work/patches/` and review diffs to
   `work/review/`.
3. **`ci/ai-review.py`** sends Claude (`claude-opus-5-5`) our applied diff plus upstream's
   changes to the files we touch since our last release. It returns `ok` or `concern`, and
   fails closed: any error counts as `concern`.
4. A **draft release** is created with the upstream tag and the review summary.
5. **`ci/hetzner.sh create`** makes a temporary server (CCX43 by default) with a fresh SSH key,
   labelled `graphiteos=1` and `expires=<unix time>`. It tries several locations.
6. **`ci/remote-build.sh start`** uploads the repo, the keys and the passphrase (to `/dev/shm`)
   and starts `ci/vm-build.sh` detached. The build outlives one GitHub job (6 h max), so the
   `build` and `finish` jobs both follow its log.
7. **`ci/vm-build.sh`** on the server:
   - installs dependencies
   - `repo sync`s the tag and verifies the manifest tag signature
   - applies `work/patches`, then `overlay/`
   - decrypts the keys and checks that every key GrapheneOS expects exists
   - runs adevtool, then `m vendorbootimage vendorkernelbootimage target-files-package` and
     `m otatools-package`
   - signs with `finalize.sh` and `generate-release.sh`
   - checks the OTA signature and the Updater metadata (build number, timestamp newer than the
     previous release, A/B, device)
   - stages the files in `/build/upload`; the install zip is split into parts under GitHub's
     2 GiB limit
8. **`finish`** uploads the assets. If the verdict is `ok`, it publishes the release as latest and
   phones get it. Otherwise the release stays a draft and an issue is opened.
9. **`cleanup`** always runs. It deletes the server and the encrypted key artifact. If the build
   failed, it deletes the draft release and opens an issue.

### `cleanup.yml` and `dev-server.yml`

- **`cleanup.yml`** runs every 30 min and deletes any labelled Hetzner server or SSH key past its
  expiry. It's the safety net for crashed runs.
- **`dev-server.yml`** starts, stops or extends a dev server that has `ci/dev_ssh_key.pub` and no
  signing keys.

### Build numbers

A release's build number is the GrapheneOS tag (`YYYYMMDDNN`). To rebuild the same tag with
changed patches, run `release.yml` by hand with `build_number` set to the tag plus 50–99 (e.g. tag
`2026110200` → `2026110250`, `2026110251`, ...). Each build must be newer than the last release,
or the Updater ignores it.

### Timing and cost

- **Time per build on CCX43:** sync ~40–55 min, compile ~3 h 10 min, signing ~20 min, about
  4.5 h total.
- **Cost:** about $3–4 per build (Hetzner ~$0.50/h, billed for about 5 h), plus well under $2 for
  the AI review.
- The Hetzner account has default quotas, which rules out bigger server types.

### Secrets and variables

All are on the GitHub repo (Settings → Secrets and variables → Actions):
- `HCLOUD_TOKEN`
- `ANTHROPIC_API_KEY`
- `SIGNING_KEYS_TGZ_B64` (keys encrypted with GrapheneOS's own scheme)
- `SIGNING_KEYS_PASSPHRASE`
- variable `AUTO_RELEASE`

The values can't be read back.

## Phone and update facts

- The Updater's Check button only schedules a background job; progress shows as notifications. It
  fetches `caiman-stable`, tries an incremental (404 here, since we don't build them) and falls
  back to the full OTA. It waits while the battery is low.
- OTAs install to the inactive A/B slot. If a build won't boot, the phone falls back to the
  previous slot.
- **Locked with our AVB key** (`fastboot flash avb_custom_key avb_pkmd.bin` must come first):
  - The boot screen is yellow ("different operating system") with an ID starting `92D45C17`,
    the start of the SHA-256 of `certs/caiman/avb_pkmd.bin`.
  - Play Integrity tops out at basic integrity, the same as on GrapheneOS.
- **Unlocked** (orange boot screen): basic integrity fails too, so apps that check it, such as
  DoorDash, refuse to sign in.
- **When the phone is connected over adb:**
  - read state with `getprop` and `dumpsys`
  - tune with `setprop debug.eink.*`
  - never run anything that writes partitions or touches the bootloader without the owner's
    explicit go-ahead
