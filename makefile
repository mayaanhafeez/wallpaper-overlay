bin/wallpaper_overlay: wallpaper_overlay.swift | bin
	swiftc -O $< -o $@ -framework AppKit -framework QuartzCore

bin:
	mkdir bin
