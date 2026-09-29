# XREAL layouts

## Example scripts

For automatic preview placement, run from the project root:

```sh
./presets/xreal-uw/layout/xreal-uw-dual.sh
```

Uses only shell built-ins and `vscreen` on PATH (`VSCREEN_BIN=/path/to/vscreen` overrides it); no Python, jq, or grep required. The script finds the first display whose name begins with `XREAL` and splits its current logical width between UWLeft/UWRight. Both use its full logical height, and each virtual resolution matches its preview size. Odd widths give the extra pixel to the right display.

For three displays, run `./presets/xreal-uw/layout/xreal-uw-triple.sh`. It reuses UWLeft/UWRight and adds UWCenter: each side gets one quarter of XREAL's logical width and the center gets the remainder, all at its full height. Both examples fill XREAL edge to edge without stretching fixed-resolution desktops or adding margins.

To run them from anywhere without a source checkout, install the `xreal-uw` preset. It writes both [layouts](cli.md#layouts) plus an [auto-connect hook](auto-connect.md#xreal-example):

```sh
vscreen generate xreal-uw
vscreen layout xreal-uw-dual      # or xreal-uw-triple
```

Sources: [xreal-uw-dual.sh](../presets/xreal-uw/layout/xreal-uw-dual.sh), [xreal-uw-triple.sh](../presets/xreal-uw/layout/xreal-uw-triple.sh), [hook](../presets/xreal-uw/hooks/xreal-uw.sh).

| XREAL logical size | Two-display widths | Three-display widths | Height of every virtual |
| --- | --- | --- | --- |
| 3840×1080 | 1920 + 1920 | 960 + 1920 + 960 | 1080 |
| 1920×1080 | 960 + 960 | 480 + 960 + 480 | 1080 |
| 2560×1440 | 1280 + 1280 | 640 + 1280 + 640 | 1440 |

Both scripts center the virtual row directly above the main display in Arrange, then reread XREAL's origin to position the previews. They use logical desktop dimensions from `screens ID --size`, not Retina backing pixels; no HiDPI mode is introduced. Rerun after moving, resizing, or reconnecting XREAL. Physical displays are not explicitly rearranged.

Missing XREAL or a layout outside the supported resolution limits (480–7680 wide, 480–4320 high per virtual) aborts before changes. If XREAL disconnects or changes size during setup, the scripts leave the previews hidden and ask you to rerun. To return from three displays to two, close the extra center with `vscreen UWCenter --close`, then rerun `vscreen layout xreal-uw-dual`.

## Manual arrangement

The logical display arrangement and preview placement are independent:

```text
      [ XREAL actual ]       ← both previews fill this display
      [ UWLeft ][ UWRight ]  ← pointer enters these first
           [ MacBook ]
```

For a 1408-point-wide main MacBook display and a 3840×1080 XREAL, center the XREAL at **`-1216x-2160`** in System Settings. These commands then create/configure the two virtuals between it and the MacBook and place their previews over the XREAL:

```sh
vscreen --new UWLeft  --resolution 1920x1080 --size 1920x1080 --origin -1216x-1080 --position -1216x-2160 --borderless --show
vscreen --new UWRight --resolution 1920x1080 --size 1920x1080 --origin   704x-1080 --position   704x-2160 --borderless --show
```

Adjust coordinates if `vscreen --screens` reports different logical sizes. VScreen modifies only its own virtual displays; arrange physical displays in System Settings. The preview windows cover the XREAL while the pointer is logically on UWLeft/UWRight, and ScreenCaptureKit draws that pointer in the corresponding preview.
