CACHE_DIR ?= $(CURDIR)/.cache/go-build
export GOCACHE := $(CACHE_DIR)

.PHONY: all build test fmt tidy clean ensure-cache

all: build

build:
	go build ./...

test: ensure-cache
	go test ./...

fmt:
	go fmt ./...

tidy:
	go mod tidy

clean:
	go clean -cache
	rm -rf $(CACHE_DIR)

ensure-cache:
	mkdir -p $(CACHE_DIR)
