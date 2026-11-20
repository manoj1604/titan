PREFIX ?= /usr/local
# The in-VM port forwarder: a static Linux binary, mounted read-only into app VMs.
FWD := .build/titan-share/titan-fwd-linux-arm64
# The tunnel gate: password, visit log, friendly errors in front of `titan share` (runs on the Mac).
GATE := .build/titan-share/titan-gate

.PHONY: build forwarder gate test install uninstall docs release

build: forwarder gate
	swift build -c release

forwarder: $(FWD)

gate: $(GATE)

$(GATE): gate/main.go gate/go.mod
	cd gate && go test ./... && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
		go build -trimpath -ldflags="-s -w" -o ../$(GATE) .

$(FWD): forwarder/main.go forwarder/go.mod
	cd forwarder && go test ./... && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		go build -trimpath -ldflags="-s -w" -o ../$(FWD) .

test: forwarder gate
	swift test
	cd forwarder && go test ./...
	cd gate && go test ./...

install: build
	install -d $(PREFIX)/bin $(PREFIX)/share/titan
	install .build/release/titan $(PREFIX)/bin/titan
	install -m 755 $(FWD) $(PREFIX)/share/titan/titan-fwd-linux-arm64
	install -m 755 $(GATE) $(PREFIX)/share/titan/titan-gate

uninstall:
	rm -f $(PREFIX)/bin/titan
	rm -rf $(PREFIX)/share/titan

docs:
	scripts/gen-cli-docs.sh

release:
	scripts/package.sh
