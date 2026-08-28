# wallpaper-overlay

Full-screen macOS wallpaper picker overlay for `set-wallpaper`. It browses a
folder of images, prints the selected absolute path on stdout, and leaves the
actual wallpaper update to the wrapper.

## Build

```sh
make
```

## Usage

```sh
./wallpaper-pick [optional-wallpaper-directory]
```

The wrapper builds `bin/wallpaper_overlay` on first run, reads the active theme
from `~/set-theme/current_theme`, scrapes matching sketchybar palette colours,
and falls back to `~/Pictures/wallpapers` when the theme folder has no images.

## Wiring

Point any hotkey, sketchybar item, or launcher at `wallpaper-pick`. On selection
it calls `set-wallpaper "$chosen"`, resolving `set-wallpaper` from `PATH` first
and then `~/.local/bin/set-wallpaper`.
