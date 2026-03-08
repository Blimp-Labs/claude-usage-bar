.PHONY: build app zip install clean

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip

install: app
	rm -rf /Applications/ClaudeUsageBar.app
	cp -R macos/ClaudeUsageBar.app /Applications/

clean:
	cd macos && swift package clean
	rm -rf macos/ClaudeUsageBar.app macos/ClaudeUsageBar.zip
