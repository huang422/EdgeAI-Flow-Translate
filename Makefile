.PHONY: help bootstrap project build test run install dmg clean

help:
	@echo "FlowTranslate — common tasks"
	@echo "  make bootstrap   Generate the Xcode project and open it"
	@echo "  make project     Generate FlowTranslate.xcodeproj (xcodegen)"
	@echo "  make build       Build the FlowTranslateCore package"
	@echo "  make test        Run core unit tests (works under CLT or Xcode)"
	@echo "  make run         Build the app (Debug) and launch it in place (dev loop)"
	@echo "  make install     Build Release and install/update into /Applications"
	@echo "  make dmg         Build a distributable .dmg (requires Xcode)"
	@echo "  make clean       Remove build artifacts"

bootstrap:
	bash Scripts/bootstrap.sh

project:
	xcodegen generate

run:
	bash Scripts/run-app.sh

install:
	bash Scripts/install-app.sh

build:
	swift build

test:
	bash Scripts/run-tests.sh

dmg:
	bash Packaging/build_dmg.sh

clean:
	rm -rf .build Packaging/build DerivedData
