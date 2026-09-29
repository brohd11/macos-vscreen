# XREAL layouts

## Layout scripts

XREAL has a 32:9 ultrawide mode and a 21:9 mode. There is one layout per arrangement, and each name ends in the mode it's for:

| Layout | XREAL mode | Displays |
| --- | --- | --- |
| `xreal-uw-dual-32` | 32:9 | `Xreal-Virtual-Left` + `Xreal-Virtual-Right`, half the width each |
| `xreal-uw-triple-32` | 32:9 | `Xreal-Virtual-Left` + `Xreal-Virtual-Center` + `Xreal-Virtual-Right`, a quarter / half / quarter |
| `xreal-uw-dual-21` | 21:9 | `Xreal-Virtual-Left` at 16:9 + `Xreal-Virtual-Right`, a vertical strip filling the rest |

Install them, plus an [auto-connect hook](auto-connect.md#xreal-example), with the `xreal-uw` preset. No source checkout is needed:

```sh
vscreen generate xreal-uw
vscreen layout xreal-uw-dual-32   # or xreal-uw-triple-32, xreal-uw-dual-21
```

From a checkout you can also run them directly, e.g. `./presets/xreal-uw/layout/xreal-uw-dual-32.sh`. They use only shell built-ins and `vscreen` on PATH (`VSCREEN_BIN=/path/to/vscreen` overrides it); no Python, jq, or grep. Each finds the first display whose name begins with `XREAL` and splits its current logical width. Every virtual uses XREAL's full logical height, and each virtual resolution matches its preview size, so XREAL is filled edge to edge with no stretching or margins. Odd widths give the extra pixel to the right display (the center, for triple).

All layouts use the same display names, so switching between them reuses and resizes the existing displays. The dual layouts close `Xreal-Virtual-Center` first (a no-op if it's not open), so switching from triple back to dual needs no manual step.

| XREAL logical size | dual-32 | triple-32 | dual-21 | Height of every virtual |
| --- | --- | --- | --- | --- |
| 3840×1080 (32:9) | 1920 + 1920 | 960 + 1920 + 960 | — | 1080 |
| 2560×1080 (21:9) | — | — | 1920 + 640 | 1080 |
| 2560×1440 | 1280 + 1280 | 640 + 1280 + 640 | — | 1440 |

`--aspect` prints the ratio in lowest terms, so XREAL's 21:9 mode (2560×1080) reports `64:27`, not `21:9`. The preset hook checks for `32:9` and `64:27`.

Every layout centers the virtual row directly above the main display in Arrange, then rereads XREAL's origin to position the previews. They use logical desktop dimensions from `screens ID --size`, not Retina backing pixels, and never introduce a HiDPI mode. Rerun after moving, resizing, or reconnecting XREAL. Physical displays are never rearranged, except for the shift described in [XREAL as the only display](#xreal-as-the-only-display).

If XREAL is missing, or a layout would fall outside the supported resolution limits (480–7680 wide, 480–4320 high per virtual), the script stops before changing anything. If XREAL disconnects or changes size during setup, the previews stay hidden and the script asks you to rerun.

## XREAL as the only display

With only XREAL connected, as on a Mac mini, XREAL is the main display, and the previews would cover all of it. The Dock would be hidden underneath them, and new windows and alerts would open under them too.

Each layout detects this: XREAL is main, or one of its own virtuals is main after an earlier run. It then places the row directly above XREAL rather than centering it on the main display, and runs `--main` on one virtual: `Xreal-Virtual-Left` for the dual layouts, `Xreal-Virtual-Center` for triple. That virtual moves to `0x0` and every display, XREAL included, shifts by the same amount, so the arrangement keeps its shape. The menu bar, Dock and new windows then appear on a desktop the previews show. Rerunning or switching layouts keeps a virtual as main. `vscreen close` or `quit` removes the virtuals, and macOS makes XREAL main again.

Sources: [dual-32](../presets/xreal-uw/layout/xreal-uw-dual-32.sh), [triple-32](../presets/xreal-uw/layout/xreal-uw-triple-32.sh), [dual-21](../presets/xreal-uw/layout/xreal-uw-dual-21.sh), [hook](../presets/xreal-uw/hooks/xreal-uw.sh).

## Manual arrangement

The logical display arrangement and preview placement are independent:

```text
      [      XREAL actual      ]                ← both previews fill this display
      [ Xreal-Virtual-Left ][ Xreal-Virtual-Right ]  ← pointer enters these first
           [ MacBook ]
```

For a 1408-point-wide main MacBook display and a 3840×1080 XREAL, center the XREAL at **`-1216x-2160`** in System Settings. These commands then create/configure the two virtuals between it and the MacBook and place their previews over the XREAL:

```sh
vscreen --new Xreal-Virtual-Left  --resolution 1920x1080 --size 1920x1080 --origin -1216x-1080 --position -1216x-2160 --borderless --show
vscreen --new Xreal-Virtual-Right --resolution 1920x1080 --size 1920x1080 --origin   704x-1080 --position   704x-2160 --borderless --show
```

Adjust coordinates if `vscreen --screens` reports different logical sizes. VScreen modifies only its own virtual displays; arrange physical displays in System Settings. The preview windows cover the XREAL while the pointer is logically on Xreal-Virtual-Left/Right, and ScreenCaptureKit draws that pointer in the corresponding preview.
