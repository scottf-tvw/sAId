.PHONY: build test app install bench release
build:
	swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

test:
	swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
	python3 -m unittest discover -s Tests/ScriptTests -v

app:
	./scripts/build-app.sh

install:
	./scripts/install.sh

bench:
	./scripts/bench.sh --preview Tests/Fixtures Tests/Fixtures/transcripts.json

release:
	./scripts/release.sh "$(VERSION)"
