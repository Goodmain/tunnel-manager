# TunnelManager release tooling.
# Requires full Xcode (xcodebuild). If xcode-select points at Command Line
# Tools, prefix commands with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCHEME   := TunnelManager
PROJECT  := TunnelManager.xcodeproj
APP      := TunnelManager.app
BUILD    := $(CURDIR)/build
ZIP      := $(BUILD)/TunnelManager.zip

ICON_SVG     := Assets/icon.svg
MENUBAR_SVG  := Assets/menubar.svg
ICONSET      := TunnelManager.iconset
ICNS         := TunnelManager.icns
APPICONSET   := TunnelManager/Assets.xcassets/AppIcon.appiconset
STATUSSET    := TunnelManager/Assets.xcassets/StatusBarIcon.imageset

.PHONY: release clean icons

# Build Release, package the .app to a zip, print its SHA-256.
release: clean
	@echo "==> Building $(SCHEME) (Release) into $(BUILD)"
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		CONFIGURATION_BUILD_DIR=$(BUILD) \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES
	@echo "==> Packaging $(APP) -> $(ZIP)"
	/usr/bin/ditto -c -k --keepParent "$(BUILD)/$(APP)" "$(ZIP)"
	@echo "==> SHA-256:"
	@shasum -a 256 "$(ZIP)"

# Regenerate the app icon from the SVG source: iconset -> .icns -> asset catalog.
# Requires rsvg-convert (brew install librsvg); iconutil/sips are built in.
icons:
	@command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert not found. Install with: brew install librsvg"; exit 1; }
	@echo "==> Rendering $(ICON_SVG) into $(ICONSET)"
	rm -rf "$(ICONSET)"
	mkdir -p "$(ICONSET)"
	rsvg-convert -w 16   -h 16   "$(ICON_SVG)" -o "$(ICONSET)/icon_16x16.png"
	rsvg-convert -w 32   -h 32   "$(ICON_SVG)" -o "$(ICONSET)/icon_16x16@2x.png"
	rsvg-convert -w 32   -h 32   "$(ICON_SVG)" -o "$(ICONSET)/icon_32x32.png"
	rsvg-convert -w 64   -h 64   "$(ICON_SVG)" -o "$(ICONSET)/icon_32x32@2x.png"
	rsvg-convert -w 128  -h 128  "$(ICON_SVG)" -o "$(ICONSET)/icon_128x128.png"
	rsvg-convert -w 256  -h 256  "$(ICON_SVG)" -o "$(ICONSET)/icon_128x128@2x.png"
	rsvg-convert -w 256  -h 256  "$(ICON_SVG)" -o "$(ICONSET)/icon_256x256.png"
	rsvg-convert -w 512  -h 512  "$(ICON_SVG)" -o "$(ICONSET)/icon_256x256@2x.png"
	rsvg-convert -w 512  -h 512  "$(ICON_SVG)" -o "$(ICONSET)/icon_512x512.png"
	rsvg-convert -w 1024 -h 1024 "$(ICON_SVG)" -o "$(ICONSET)/icon_512x512@2x.png"
	@echo "==> Building $(ICNS)"
	iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@echo "==> Copying PNGs into $(APPICONSET)"
	cp "$(ICONSET)"/icon_*.png "$(APPICONSET)/"
	rm -rf "$(ICONSET)"
	@echo "==> Rendering menu-bar glyph into $(STATUSSET)"
	rsvg-convert -w 18 -h 18 "$(MENUBAR_SVG)" -o "$(STATUSSET)/statusbar.png"
	rsvg-convert -w 36 -h 36 "$(MENUBAR_SVG)" -o "$(STATUSSET)/statusbar@2x.png"
	@echo "==> Icons updated."

# Remove all build output.
clean:
	rm -rf "$(BUILD)"
