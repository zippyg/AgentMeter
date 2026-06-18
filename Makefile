SHELL := /bin/bash

.PHONY: build check format lint release restart start start-debug start-release stop test test-live test-tty

start:
	swift run AgentMeter

start-debug: start

start-release:
	swift build -c release --product AgentMeter
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
	swift build

test:
	swift test

test-tty:
	swift test --filter TTYIntegrationTests

test-live:
	LIVE_TEST=1 swift test --filter LiveAccountTests

release:
	swift build -c release --product AgentMeter
	./Scripts/agentmeter_package_local_app.sh
