.PHONY: all libs build test app install reinstall uninstall run clean

all: app

libs:
	./Scripts/prepare_libs.sh

build: libs
	swift build -c release --arch x86_64

test: libs
	swift test --arch x86_64

app:
	./Scripts/build_app.sh release
	@if [ -d "$$HOME/Applications/UPreviewX.app" ]; then \
		./Scripts/install_app.sh --no-build; \
	fi

install:
	./Scripts/install_app.sh

reinstall:
	./Scripts/install_app.sh --clean

uninstall:
	killall UPreviewX 2>/dev/null || true
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$$HOME/Applications/UPreviewX.app" 2>/dev/null || true
	rm -rf "$$HOME/Applications/UPreviewX.app"

clean:
	swift package clean
	rm -rf .build dist

