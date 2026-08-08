.PHONY: build app zip dmg release-artifacts verify-release install clean coverage

build:
	cd macos && swift build -c release

app:
	bash macos/scripts/build.sh

zip:
	bash macos/scripts/build.sh --zip
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip

dmg:
	bash macos/scripts/build.sh --dmg
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.dmg

release-artifacts:
	bash macos/scripts/build.sh --zip --dmg
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.dmg

verify-release:
	bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.zip
	if [ -f macos/ClaudeUsageBar.dmg ]; then bash macos/scripts/verify-release.sh macos/ClaudeUsageBar.dmg; fi

install: app
	rm -rf /Applications/ClaudeUsageBar.app
	cp -R macos/ClaudeUsageBar.app /Applications/

coverage:
	cd macos && swift test --enable-code-coverage
	xcrun llvm-cov report \
		macos/.build/debug/ClaudeUsageBarPackageTests.xctest/Contents/MacOS/ClaudeUsageBarPackageTests \
		-instr-profile macos/.build/debug/codecov/default.profdata \
		--ignore-filename-regex='\.build|Tests'

clean:
	cd macos && swift package clean
	rm -rf macos/ClaudeUsageBar.app macos/ClaudeUsageBar.zip macos/ClaudeUsageBar.dmg
