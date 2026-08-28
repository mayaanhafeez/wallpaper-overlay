SWIFTC ?= swiftc
SWIFTFLAGS ?= -O

.PHONY: all check clean

all: bin/wallpaper_overlay

bin/wallpaper_overlay: wallpaper_overlay.swift | bin
	$(SWIFTC) $(SWIFTFLAGS) $< -o $@ -framework AppKit -framework QuartzCore

bin:
	mkdir -p $@

check:
	$(SWIFTC) -warnings-as-errors -typecheck wallpaper_overlay.swift -framework AppKit -framework QuartzCore
	bash -n wallpaper-pick

clean:
	rm -rf bin
