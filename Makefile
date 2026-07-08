# ARPG monorepo task runner. Run everything from the repo root.
#
# Godot is not always on PATH; override with `make test-game GODOT=/path/to/godot`.

GODOT ?= godot
GO ?= go
GAME_DIR := game
SERVER_DIR := server

.PHONY: help check test test-game test-server run-server \
        fmt-server vet-server lint-server validate-data tidy-server sqlc-generate

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

check: validate-data lint-server test-server test-game ## Run everything CI runs
test: test-server test-game ## Run all unit tests

## --- Game (Godot) ---------------------------------------------------------

test-game: ## Run domain unit tests headless via gdUnit4
	# Requires Godot + the gdUnit4 addon installed locally (see CLAUDE.md).
	# CI runs the equivalent via the gdUnit4 GitHub Action.
	# --ignoreHeadlessMode: gdUnit4 refuses plain headless runs because InputEvent-
	# driven UI tests can't work there; our tests are pure domain/data, so it's safe.
	$(GODOT) --headless --path $(GAME_DIR) \
	  -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests --ignoreHeadlessMode

## --- Server (Go) ----------------------------------------------------------

test-server: ## Run Go tests (race detector on)
	cd $(SERVER_DIR) && $(GO) test -race ./...

run-server: ## Start the Go server (ARPG_ADDR overrides :8080)
	cd $(SERVER_DIR) && $(GO) run ./cmd/server

vet-server: ## go vet
	cd $(SERVER_DIR) && $(GO) vet ./...

fmt-server: ## Fail if any Go file is not gofmt-clean
	@out="$$(cd $(SERVER_DIR) && gofmt -l .)"; \
	  if [ -n "$$out" ]; then echo "gofmt needed for:"; echo "$$out"; exit 1; fi

lint-server: fmt-server vet-server ## gofmt check + go vet + golangci-lint
	cd $(SERVER_DIR) && golangci-lint run ./...

tidy-server: ## Tidy and verify go.mod/go.sum
	cd $(SERVER_DIR) && $(GO) mod tidy

sqlc-generate: ## Regenerate internal/store/sqlcgen from db/migrations + db/queries
	cd $(SERVER_DIR) && sqlc generate

## --- Shared data ----------------------------------------------------------

validate-data: ## Validate shared/*.json against their JSON Schemas
	check-jsonschema --schemafile shared/schemas/monsters.schema.json shared/monsters.json
	check-jsonschema --schemafile shared/schemas/player.schema.json shared/player.json
	check-jsonschema --schemafile shared/schemas/combat.schema.json shared/combat.json
	check-jsonschema --schemafile shared/schemas/items.schema.json shared/items.json
	check-jsonschema --schemafile shared/schemas/loot_tables.schema.json shared/loot_tables.json
	check-jsonschema --schemafile shared/schemas/skills.schema.json shared/skills.json
