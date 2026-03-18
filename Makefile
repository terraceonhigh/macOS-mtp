BRIDGE_OUT := build/bridge
APP_NAME   := AndroidFS
GO         := /opt/homebrew/bin/go
DERIVED    := $(HOME)/Library/Developer/Xcode/DerivedData
LIBMTP_DYLIB := /opt/homebrew/opt/libmtp/lib/libmtp.9.dylib
LIBUSB_DYLIB := /opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
DIST_DIR   := dist

.PHONY: bridge app app-debug dev run dist clean

bridge:
	cd bridge && CGO_CFLAGS="-I$(CURDIR)/bridge/cvendor" CGO_LDFLAGS="-L/opt/homebrew/lib" $(GO) build -o ../$(BRIDGE_OUT) .

# Bundle bridge + all dylibs into an app directory, fix rpaths
define BUNDLE_BRIDGE
	mkdir -p "$(1)/Contents/Frameworks" "$(1)/Contents/Resources"; \
	rm -f "$(1)/Contents/Resources/bridge" \
	      "$(1)/Contents/Frameworks/libmtp.9.dylib" \
	      "$(1)/Contents/Frameworks/libusb-1.0.0.dylib"; \
	cp $(BRIDGE_OUT) "$(1)/Contents/Resources/bridge"; \
	cp $(LIBMTP_DYLIB) "$(1)/Contents/Frameworks/libmtp.9.dylib"; \
	cp $(LIBUSB_DYLIB) "$(1)/Contents/Frameworks/libusb-1.0.0.dylib"; \
	install_name_tool -change $(LIBMTP_DYLIB) \
		@executable_path/../Frameworks/libmtp.9.dylib \
		"$(1)/Contents/Resources/bridge"; \
	install_name_tool -change $(LIBUSB_DYLIB) \
		@executable_path/../Frameworks/libusb-1.0.0.dylib \
		"$(1)/Contents/Frameworks/libmtp.9.dylib"; \
	codesign --force --sign - "$(1)/Contents/Frameworks/libmtp.9.dylib"; \
	codesign --force --sign - "$(1)/Contents/Frameworks/libusb-1.0.0.dylib"; \
	codesign --force --sign - "$(1)/Contents/Resources/bridge"; \
	echo "Bundled bridge + libmtp + libusb into $(1)"
endef

app: bridge
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj \
	           -scheme $(APP_NAME) \
	           -configuration Release \
	           build
	@APP_DIR=$$(find $(DERIVED) -path "*/Release/$(APP_NAME).app" -maxdepth 5 2>/dev/null | head -1); \
	if [ -n "$$APP_DIR" ]; then \
		$(call BUNDLE_BRIDGE,$$APP_DIR); \
	fi

app-debug: bridge
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj \
	           -scheme $(APP_NAME) \
	           -configuration Debug \
	           build
	@APP_DIR=$$(find $(DERIVED) -path "*/Debug/$(APP_NAME).app" -maxdepth 5 2>/dev/null | head -1); \
	if [ -n "$$APP_DIR" ]; then \
		$(call BUNDLE_BRIDGE,$$APP_DIR); \
	fi

dev: bridge
	./$(BRIDGE_OUT) 2>&1

run: app-debug
	@killall $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@APP_DIR=$$(find $(DERIVED) -path "*/Debug/$(APP_NAME).app" -maxdepth 5 2>/dev/null | head -1); \
	echo "Launching $$APP_DIR"; \
	"$$APP_DIR/Contents/MacOS/$(APP_NAME)"

# Build a distributable .app + zip
dist: bridge
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj \
	           -scheme $(APP_NAME) \
	           -configuration Release \
	           build
	@APP_DIR=$$(find $(DERIVED) -path "*/Release/$(APP_NAME).app" -maxdepth 5 2>/dev/null | head -1); \
	if [ -z "$$APP_DIR" ]; then echo "ERROR: app not found"; exit 1; fi; \
	$(call BUNDLE_BRIDGE,$$APP_DIR); \
	rm -rf $(DIST_DIR); \
	mkdir -p $(DIST_DIR); \
	cp -R "$$APP_DIR" $(DIST_DIR)/$(APP_NAME).app; \
	cd $(DIST_DIR) && zip -r $(APP_NAME).zip $(APP_NAME).app; \
	echo ""; \
	echo "=== Distribution ready ==="; \
	echo "  $(DIST_DIR)/$(APP_NAME).app"; \
	echo "  $(DIST_DIR)/$(APP_NAME).zip ($$(du -h $(DIST_DIR)/$(APP_NAME).zip | cut -f1))"; \
	echo ""; \
	echo "Testers: right-click → Open on first launch (unsigned)"

clean:
	rm -rf build/ dist/
