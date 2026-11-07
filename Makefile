.PHONY: all libs build test app run clean

all: app

libs:
	./Scripts/prepare_libs.sh

build: libs
	swift build -c release --arch x86_64

test: libs
	swift test --arch x86_64

app:
	./Scripts/build_app.sh release

clean:
	swift package clean
	rm -rf .build dist

