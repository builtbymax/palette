.PHONY: build install test e2e release publish clean

build:
	./scripts/build.sh

install:
	./scripts/build.sh --install

test:
	swift test

e2e:
	swift build
	python3 Tests/e2e.py

# make release VERSION=0.0.2 (see scripts/release.sh for the one-time setup)
release:
	./scripts/release.sh $(VERSION)

# make publish VERSION=0.0.2
publish:
	./scripts/publish.sh $(VERSION)

clean:
	rm -rf .build dist
