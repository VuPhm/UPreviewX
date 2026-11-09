.PHONY: all libs build test app install reinstall uninstall package dist release-check validate run clean

all: app

libs:
	./Scripts/prepare_libs.sh

build: libs
	swift build -c release --arch x86_64

test: libs
	swift test --arch x86_64

app: libs
	./Scripts/build_app.sh release

package: app
	./Scripts/package_distribution.sh

dist: package

release-check:
	./Scripts/release_check.sh

validate: app
	./Scripts/validate_release.sh

install:
	./Scripts/install_app.sh

reinstall:
	./Scripts/install_app.sh --clean

uninstall:
	killall UPreviewX 2>/dev/null || true
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$$HOME/Applications/UPreviewX.app" 2>/dev/null || true
	rm -rf "$$HOME/Applications/UPreviewX.app"
	@echo "Uninstalled UPreviewX.app from $$HOME/Applications."
	@echo "Note: Preferences in ~/Library/Preferences/com.vuphm.upreviewx.plist are preserved."

clean:
	swift package clean
	rm -rf .build dist
