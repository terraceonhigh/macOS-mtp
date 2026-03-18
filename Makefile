BRIDGE_OUT := build/bridge
APP_NAME   := AndroidFS
GO         := /opt/homebrew/bin/go

.PHONY: bridge app dev clean

bridge:
	cd bridge && CGO_CFLAGS="-I$(CURDIR)/bridge/cvendor" CGO_LDFLAGS="-L/opt/homebrew/lib" $(GO) build -o ../$(BRIDGE_OUT) .

app: bridge
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj \
	           -scheme $(APP_NAME) \
	           -configuration Release \
	           build
	cp $(BRIDGE_OUT) MenuBarApp/build/Release/$(APP_NAME).app/Contents/Resources/bridge

dev: bridge
	./$(BRIDGE_OUT) 2>&1

clean:
	rm -rf build/
