# Contributing

Contributions that keep wallpaper-overlay fast, native, and focused are welcome.

## Development

You need macOS, Xcode Command Line Tools, and Bash.

```sh
git clone https://github.com/mayaanhafeez/wallpaper-overlay.git
cd wallpaper-overlay
make check
make
```

Run `./wallpaper-pick /path/to/wallpapers` to exercise the complete flow. The
wrapper expects a `set-wallpaper` executable in `PATH` or at
`~/.local/bin/set-wallpaper` after a wallpaper is selected.

## Pull requests

- Keep changes scoped and explain the user-facing behavior.
- Run `make check` and `make` before opening a pull request.
- Manually test keyboard, mouse, cancellation, and multiple displays for UI changes.
- Include before and after screenshots for visual changes.

For larger features, open an issue first so the behavior and scope can be agreed on.
