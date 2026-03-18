RMRF ?= rm -rf
SHELLCHECK ?= shellcheck
DOCKER ?= docker

.PHONY: lint
lint:
	$(SHELLCHECK) scripts/*.sh

.PHONY: fetch
fetch: scripts/fetch.sh
	./$< ./build/specs

.PHONY: schemas
schemas: scripts/schemas.sh
	./$< ./build/specs ./build/schemas

.PHONY: one
one:
	$(DOCKER) build --tag overheid . --file Dockerfile --progress plain

.PHONY: one-dev
one-dev: one
	$(DOCKER) run --rm --publish 8000:8000 overheid

.PHONY: clean
clean:
	$(RMRF) build
