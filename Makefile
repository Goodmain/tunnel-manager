# TunnelManager release tooling.
# Requires full Xcode (xcodebuild). If xcode-select points at Command Line
# Tools, prefix commands with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

SCHEME   := TunnelManager
PROJECT  := TunnelManager.xcodeproj
APP      := TunnelManager.app
BUILD    := $(CURDIR)/build
ZIP      := $(BUILD)/TunnelManager.zip

.PHONY: release clean

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

# Remove all build output.
clean:
	rm -rf "$(BUILD)"
