APP_NAME  := Kiwi
BUNDLE_ID := io.github.lftorresg.kiwi
BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
ENTITLEMENTS := Resources/Kiwi.entitlements

# Signs with a stable local identity named "Kiwi Local" when one exists in the
# keychain (permissions then survive rebuilds), otherwise ad hoc. See README.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Kiwi Local"' && echo "Kiwi Local" || echo "-")

.PHONY: build app verify run install uninstall reset-permissions checksum clean

build:
	swift build -c release

# Assembles the bundle and signs it with the hardened runtime and an empty
# entitlements file, so nothing can be injected into a process that holds the
# Screen Recording permission.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/Kiwi.icns "$(APP)/Contents/Resources/Kiwi.icns"
	xattr -cr "$(APP)"
	codesign --force --options runtime --entitlements "$(ENTITLEMENTS)" --sign "$(SIGN_ID)" "$(APP)"
	@echo "Built $(APP) (signed with: $(SIGN_ID), hardened runtime)"

# Checks the built app: signature, hardened runtime, entitlements, linked
# libraries, network symbols, dependencies. Fails on any finding.
verify: app
	@bash scripts/verify.sh "$(APP)"

# run and install print the same report but do not block on it.
run: app
	-@bash scripts/verify.sh "$(APP)"
	-pkill -x $(APP_NAME) 2>/dev/null; sleep 0.4
	open "$(APP)"

install: app
	-@bash scripts/verify.sh "$(APP)"
	-pkill -x $(APP_NAME) 2>/dev/null; sleep 0.4
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	open "/Applications/$(APP_NAME).app"

uninstall:
	-pkill -x $(APP_NAME) 2>/dev/null
	rm -rf "/Applications/$(APP_NAME).app"
	rm -rf "$(HOME)/Library/Caches/Kiwi"
	-defaults delete $(BUNDLE_ID) 2>/dev/null

# Use after a rebuild with ad hoc signing if macOS stops honouring the
# Screen Recording grant.
reset-permissions:
	tccutil reset ScreenCapture $(BUNDLE_ID)

checksum: app
	@shasum -a 256 "$(APP)/Contents/MacOS/$(APP_NAME)"

clean:
	rm -rf .build $(BUILD_DIR)
