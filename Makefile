# Saarathi developer Makefile — one entry point for the backend stack, the
# dashboard, Valhalla routing, and the usual Rust chores. Run `make` for help.
#
# The backend runs as containers (backend/docker-compose.yml); the dashboard is
# a Next.js dev server. Most targets just wrap docker compose / cargo / npm.

BACKEND   := backend
DASHBOARD := dashboard
APP       := app
COMPOSE   := docker compose

.DEFAULT_GOAL := help

.PHONY: help env up down restart stop ps logs clean infra \
        valhalla valhalla-logs valhalla-rebuild \
        build test lint fmt check \
        dashboard dashboard-install dashboard-build \
        app app-create app-get app-l10n app-build app-clean \
        dev smoke

help: ## Show this help
	@echo "Saarathi — make targets:"
	@grep -E '^[a-zA-Z0-9_%-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

env: ## Create .env files from the examples if missing
	@test -f $(BACKEND)/.env || cp $(BACKEND)/.env.example $(BACKEND)/.env
	@test -f $(DASHBOARD)/.env.local || cp $(DASHBOARD)/.env.local.example $(DASHBOARD)/.env.local
	@echo "env ready: $(BACKEND)/.env, $(DASHBOARD)/.env.local"

# ── Backend stack (containers) ───────────────────────────────────────────────

up: env ## Build + start the whole backend (infra + services + gateway)
	cd $(BACKEND) && $(COMPOSE) up -d --build

down: ## Stop the backend stack (keeps data)
	cd $(BACKEND) && $(COMPOSE) down

stop: down ## Alias for down

restart: down up ## Restart the backend stack

ps: ## Show stack status
	cd $(BACKEND) && $(COMPOSE) ps

logs: ## Tail logs from all services (Ctrl-C to stop)
	cd $(BACKEND) && $(COMPOSE) logs -f --tail=100

infra: env ## Start only infra (postgres, redis, nats, gateway)
	cd $(BACKEND) && $(COMPOSE) up -d postgres redis nats gateway

clean: ## Stop the stack and REMOVE volumes (drops DB + KYC data!)
	cd $(BACKEND) && $(COMPOSE) down -v

# ── Valhalla routing ─────────────────────────────────────────────────────────

valhalla: ## Start the Valhalla routing engine (routing profile)
	cd $(BACKEND) && $(COMPOSE) --profile routing up -d valhalla

valhalla-logs: ## Tail Valhalla logs (tile build progress on first boot)
	cd $(BACKEND) && $(COMPOSE) --profile routing logs -f valhalla

valhalla-rebuild: ## Force-rebuild Valhalla tiles from OSM (clears the tile cache)
	rm -rf $(BACKEND)/.data/valhalla
	cd $(BACKEND) && $(COMPOSE) --profile routing up -d valhalla

# ── Rust (backend workspace) ─────────────────────────────────────────────────

build: ## Build the Rust workspace
	cd $(BACKEND) && cargo build

test: ## Run the Rust test suite
	cd $(BACKEND) && cargo test

lint: ## Clippy over all targets
	cd $(BACKEND) && cargo clippy --all-targets

fmt: ## Format the Rust workspace
	cd $(BACKEND) && cargo fmt

check: ## CI-style gate: fmt check + clippy + tests
	cd $(BACKEND) && cargo fmt --check && cargo clippy --all-targets && cargo test

run-%: ## Run one service on the host, e.g. make run-rides
	cd $(BACKEND) && cargo run -p saarathi-$*

# ── Dashboard (Next.js) ──────────────────────────────────────────────────────

dashboard-install: ## Install dashboard dependencies
	cd $(DASHBOARD) && npm install

dashboard: env ## Start the dashboard dev server (http://localhost:3000)
	cd $(DASHBOARD) && npm run dev

dashboard-build: ## Production build of the dashboard
	cd $(DASHBOARD) && npm run build

# ── Mobile app (Flutter) ──────────────────────────────────────────────

app-create: ## Generate native runner folders (first-time only)
	cd $(APP) && flutter create --org com.saarathi --project-name saarathi --platforms=android,ios,web .

app-get: ## Fetch app packages
	cd $(APP) && flutter pub get

app-l10n: ## Regenerate localization (en/ne) from ARB files
	cd $(APP) && flutter gen-l10n

app: ## Run the app (device/emulator); points at the gateway on the host
	cd $(APP) && flutter run --dart-define=SAARATHI_API_BASE=http://localhost:8080

app-build: ## Release Android APK
	cd $(APP) && flutter build apk --release

app-clean: ## Clean the app build
	cd $(APP) && flutter clean

# ── Combined ─────────────────────────────────────────────────────────────────

dev: up ## Start the backend stack, then run the dashboard in the foreground
	cd $(DASHBOARD) && npm run dev

smoke: ## Run the end-to-end smoke test (stack must be up)
	./scripts/smoke.sh
