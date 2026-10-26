PREFIX ?= $(HOME)/.local/bin
LABEL  := xyz.pyvno.notchroom
PLIST  := $(HOME)/Library/LaunchAgents/$(LABEL).plist
GUI    := gui/$(shell id -u)

notchroom: $(wildcard Sources/*.swift)
	swiftc -O Sources/*.swift -o $@
	# hardened runtime: no injected libraries, and its code hash is what the permission channel trusts
	codesign -s - -o runtime --force $@ 2>/dev/null

test: notchroom
	./notchroom --test

# the binary into PREFIX, the hooks into ~/.claude/settings.json, and a LaunchAgent that starts it at login
install: notchroom
	mkdir -p $(PREFIX) $(HOME)/Library/LaunchAgents
	cp notchroom $(PREFIX)/notchroom
	$(PREFIX)/notchroom --install-hooks
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>$(LABEL)</string>' \
	  '<key>ProgramArguments</key><array><string>$(PREFIX)/notchroom</string></array>' \
	  '<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>' \
	  '<key>MachServices</key><dict><key>xyz.pyvno.notchroom.answers</key><true/></dict>' \
	  '</dict></plist>' > $(PLIST)
	-launchctl bootout $(GUI)/$(LABEL) 2>/dev/null
	-pkill -x notchroom
	launchctl bootstrap $(GUI) $(PLIST)
	@echo "notchroom is running and starts at login. Hover the notch."

uninstall:
	-launchctl bootout $(GUI)/$(LABEL) 2>/dev/null
	rm -f $(PLIST)
	-$(PREFIX)/notchroom --uninstall-hooks
	rm -f $(PREFIX)/notchroom
	@echo "Removed. State in ~/.claude/notchroom stays until you delete it."

# after pulling or editing: rebuild, replace the installed binary, restart it
update: notchroom
	cp notchroom $(PREFIX)/notchroom
	launchctl kickstart -k $(GUI)/$(LABEL)

# the pictures in docs/, drawn offscreen from demo data
screenshots: $(wildcard Sources/*.swift) Tools/screenshots.swift
	mkdir -p .build && cp Tools/screenshots.swift .build/main.swift # top-level code has to live in a main.swift
	swiftc -O $(filter-out Sources/main.swift,$(wildcard Sources/*.swift)) .build/main.swift -o .build/screenshots
	./.build/screenshots docs

clean:
	rm -rf notchroom .build

.PHONY: test install uninstall update screenshots clean
