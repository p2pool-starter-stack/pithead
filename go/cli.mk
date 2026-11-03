GO_VERSION := 1.26.10
GO_ENV = GOTOOLCHAIN=go$(GO_VERSION) GOCACHE=$(CURDIR)/.go-cache/build GOMODCACHE=$(CURDIR)/.go-cache/mod

.PHONY: go-build test-go test-go-parity test-go-status-parity test-go-shipping lint-go

go-build: pithead ## Build the optional native CLI with the pinned toolchain
	mkdir -p go/bin
	cd go && $(GO_ENV) CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags=-buildid= -o bin/pithead ./cmd/pithead

test-go: lint-go ## Native CLI unit tests and race detector
	mkdir -p .go-cache
	cd go && $(GO_ENV) CGO_ENABLED=1 go test -race -coverprofile=../.go-cache/unit.cover ./...
	cd go && $(GO_ENV) go tool cover -func=../.go-cache/unit.cover | tail -1 | awk '{ if ($$3+0 < 80) exit 1 }'

lint-go:
	cd go && $(GO_ENV) go vet ./...
	@test -z "$$(cd go && gofmt -l cmd internal)"

test-go-parity: go-build ## Bash/native CLI, status, fallback and shipping contracts
	python3 -m unittest discover -s tests/go-parity -p 'test_*.py' -v

test-go-status-parity: go-build ## Focused bare-status parity
	python3 -m unittest discover -s tests/go-parity -p 'test_status*.py' -v

test-go-shipping: pithead ## Reproduce Linux release artifacts without executing them
	PITHEAD_REAL_GO_BUILD=1 python3 -m unittest discover -s tests/go-parity -p test_shipping.py -v
