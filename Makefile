PREFIX ?= /usr/local

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

install: build
	install -d $(PREFIX)/bin
	install .build/release/titan $(PREFIX)/bin/titan

uninstall:
	rm -f $(PREFIX)/bin/titan
