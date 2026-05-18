BINARY  := serverdoc
VERSION := 0.3.7

# Локальная сборка под текущую систему
build:
	go build -ldflags "-s -w -X main.version=$(VERSION)" -o $(BINARY) ./cmd/serverdoc

# Кросс-компиляция статичных бинарников под Linux (заливаются в Releases)
build-all:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o dist/$(BINARY)-linux-amd64 ./cmd/serverdoc
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w -X main.version=$(VERSION)" -o dist/$(BINARY)-linux-arm64 ./cmd/serverdoc

run: build
	./$(BINARY)

vet:
	go vet ./...

clean:
	rm -f $(BINARY)
	rm -rf dist

.PHONY: build build-all run vet clean
