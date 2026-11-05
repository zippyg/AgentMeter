SHELL := /bin/bash

# Swift 6.4's default build system rejects this package (duplicatedTargetIdentifier for the
# resource bundle). The native build system builds it. Override with SWIFT_BUILD_FLAGS= to try the default.
SWIFT_BUILD_FLAGS ?= --build-system native

.PHONY: build check format lint release restart start start-debug start-release stop test test-live test-tty

start:
	swift run $(SWIFT_BUILD_FLAGS) AgentMeter

start-debug: start

start-release:
	swift build $(SWIFT_BUILD_FLAGS) -c release --product AgentMeter
	./Scripts/agentmeter_package_local_app.sh
	./Scripts/agentmeter_install_local_artifact.sh

restart: start

stop:
	pkill -f "/Applications/AgentMeter.app/Contents/MacOS/AgentMeter" || true

check lint:
	./Scripts/lint.sh lint

format:
	./Scripts/lint.sh format

build:
	swift build $(SWIFT_BUILD_FLAGS)

test:
	swift test $(SWIFT_BUILD_FLAGS)

test-tty:
	swift test $(SWIFT_BUILD_FLAGS) --filter TTYIntegrationTests

test-live:
	LIVE_TEST=1 swift test $(SWIFT_BUILD_FLAGS) --filter LiveAccountTests

release:
	swift build $(SWIFT_BUILD_FLAGS) -c release --product AgentMeter
	./Scripts/agentmeter_package_local_app.sh
