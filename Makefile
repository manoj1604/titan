PREFIX ?= /usr/local
# The in-VM port forwarder: a static Linux binary, mounted read-only into app VMs.
FWD := .build/titan-share/titan-fwd-linux-arm64

.PHONY: build forwarder test install uninstall

build: forwarder
	swift build -c release

forwarder: $(FWD)

$(FWD): forwarder/main.go forwarder/go.mod
	cd forwarder && go test ./... && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		go build -trimpath -ldflags="-s -w" -o ../$(FWD) .

test: forwarder
	swift test
	cd forwarder && go test ./...

install: build
	install -d $(PREFIX)/bin $(PREFIX)/share/titan
	install .build/release/titan $(PREFIX)/bin/titan
	install -m 755 $(FWD) $(PREFIX)/share/titan/titan-fwd-linux-arm64

uninstall:
	rm -f $(PREFIX)/bin/titan
	rm -rf $(PREFIX)/share/titan
