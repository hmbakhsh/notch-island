# make install     build Island.app into ~/Applications, link `notch`, start at login
# make uninstall   undo all of that (keeps your history in ~/.local/state/notch)
# make run         run a debug build in the foreground

APP_DIR ?= $(HOME)/Applications
BIN_DIR ?= $(HOME)/.local/bin
LABEL   := dev.notchisland.island
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
APP     := build/Island.app

.PHONY: build app install uninstall run clean

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Island $(APP)/Contents/MacOS/Island
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

install: app
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	-pkill -x Island
	mkdir -p $(APP_DIR) $(BIN_DIR) $(dir $(AGENT))
	rm -rf $(APP_DIR)/Island.app
	cp -R $(APP) $(APP_DIR)/Island.app
	ln -sf $(APP_DIR)/Island.app/Contents/MacOS/Island $(BIN_DIR)/notch
	sed "s|@APP@|$(APP_DIR)/Island.app|" Resources/launchagent.plist > $(AGENT)
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "Installed. Try: notch \"Hello\" -b \"from the notch\" -i hand.wave.fill -c yellow"

uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	-pkill -x Island
	rm -rf $(APP_DIR)/Island.app $(AGENT) $(BIN_DIR)/notch

run:
	swift run Island

clean:
	rm -rf .build build
