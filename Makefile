RMRF ?= rm -rf
SHELLCHECK ?= shellcheck

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
	docker build --tag overheid . --file Dockerfile --progress plain

.PHONY: clean
clean:
	$(RMRF) build
