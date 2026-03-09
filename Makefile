.PHONY: build app zip verify-release install clean

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip

verify-release:
	bash macos/scripts/verify-release.sh

install: app
	rm -rf /Applications/ClaudeUsageBar.app
	cp -R macos/ClaudeUsageBar.app /Applications/

clean:
	cd macos && swift package clean
	rm -rf macos/ClaudeUsageBar.app macos/ClaudeUsageBar.zip
