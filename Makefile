BRIDGE_OUT := build/bridge
APP_NAME   := AndroidFS
GO         := /opt/homebrew/bin/go
DERIVED    := $(HOME)/Library/Developer/Xcode/DerivedData
LIBMTP_DYLIB := /opt/homebrew/opt/libmtp/lib/libmtp.9.dylib

.PHONY: bridge app app-debug dev run clean

bridge:
	cd bridge && CGO_CFLAGS="-I$(CURDIR)/bridge/cvendor" CGO_LDFLAGS="-L/opt/homebrew/lib" $(GO) build -o ../$(BRIDGE_OUT) .

# Bundle the bridge binary + libmtp into an app directory
define BUNDLE_BRIDGE
	mkdir -p "$(1)/Contents/Frameworks" "$(1)/Contents/Resources"; \
	cp $(BRIDGE_OUT) "$(1)/Contents/Resources/bridge"; \
	cp $(LIBMTP_DYLIB) "$(1)/Contents/Frameworks/libmtp.9.dylib"; \
	install_name_tool -change $(LIBMTP_DYLIB) @executable_path/../Frameworks/libmtp.9.dylib "$(1)/Contents/Resources/bridge"; \
	echo "Bundled bridge + libmtp into $(1)"
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

clean:
	rm -rf build/
