# XREAL layouts

## Layout scripts

XREAL has a 32:9 ultrawide mode and a 21:9 mode. There is one layout per arrangement, and each name ends in the mode it's for:

| Layout | XREAL mode | Displays |
| --- | --- | --- |
| `xreal-uw-dual-32` | 32:9 | `Xreal-Virtual-Left` + `Xreal-Virtual-Right`, half the width each |
| `xreal-uw-triple-32` | 32:9 | `Xreal-Virtual-Left` + `Xreal-Virtual-Center` + `Xreal-Virtual-Right`, a quarter / half / quarter |
| `xreal-uw-dual-21` | 21:9 | `Xreal-Virtual-Left` at 16:9 + `Xreal-Virtual-Right`, a vertical strip filling the rest |

You can install them, plus an [auto-connect hook](auto-connect.md#xreal-example), with the `xreal-uw` preset:

```sh
vscreen generate xreal-uw
vscreen layout xreal-uw-dual-32   # or xreal-uw-triple-32, xreal-uw-dual-21
```

Each finds the first display whose name begins with `XREAL` and applys a layout of virtual screens. The XREAL display is filled edge to edge, overlayed over the menu bar. Odd widths give the extra pixel to the right display (the center, for triple).

All layouts use the same display names, so switching between them reuses and resizes the existing displays. The dual layouts close `Xreal-Virtual-Center` first (a no-op if it's not open), so switching from triple back to dual needs no manual step.

| XREAL logical size | dual-32 | triple-32 | dual-21 | Height of every virtual |
| --- | --- | --- | --- | --- |
| 3840×1080 (32:9) | 1920 + 1920 | 960 + 1920 + 960 | — | 1080 |
| 2560×1080 (21:9) | — | — | 1920 + 640 | 1080 |
| 2560×1440 | 1280 + 1280 | 640 + 1280 + 640 | — | 1440 |

`--aspect` prints the ratio in lowest terms, so XREAL's 21:9 mode (2560×1080) reports `64:27`, not `21:9`. The preset hook checks for `32:9` and `64:27`.

My macbook loses it's remembered resolution for the XReal glasses when swapping betweem aspect ratios. So the hook will attempt to resize the display to full res if it needs to. Then the layout centers the the virtuals above the main screen. Mouseing up from your screen enters them.

If XREAL is missing, or a layout would fall outside the supported resolution limits (480–7680 wide, 480–4320 high per virtual), the script stops before changing anything. If XREAL disconnects or changes size during setup, the previews stay hidden and the script asks you to rerun.

## XREAL as the only display

With only XREAL connected (ie. Mac mini with no monitor), XREAL is the main display, and the previews would cover all of it. The Dock would be hidden underneath them, and new windows and alerts would open under them too.

Each layout detects this: XREAL is main, or one of its own virtuals is main after an earlier run. It then places the row directly above XREAL rather than centering it on the main display, and runs `--main` on one virtual: `Xreal-Virtual-Left` for the dual layouts, `Xreal-Virtual-Center` for triple. That virtual moves to `0x0` and every display, XREAL included, shifts by the same amount, so the arrangement keeps its shape. The menu bar, Dock and new windows then appear on a desktop the previews show. Rerunning or switching layouts keeps a virtual as main. `vscreen close` or `quit` removes the virtuals, and macOS makes XREAL main again.

Sources: [dual-32](../presets/xreal-uw/layout/xreal-uw-dual-32.sh), [triple-32](../presets/xreal-uw/layout/xreal-uw-triple-32.sh), [dual-21](../presets/xreal-uw/layout/xreal-uw-dual-21.sh), [hook](../presets/xreal-uw/hooks/xreal-uw.sh).

## Layout example

```text
      [ Virtual-Left ][ Virtual-Right ]      ← Virtual screens, where the apps actually are
                [ MacBook ][ XREAL actual ]   ← previews sit in this display, where you can see the
```
