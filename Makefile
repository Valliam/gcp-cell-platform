# ==============================================================================
# gcp-cell-platform — cell lifecycle
#
#   make check                       everything CI runs, with no credentials
#   make plan  CELL=acme/prod-syd    plan one cell
#   make apply CELL=acme/prod-syd    apply one cell
#   make drill CELL=acme/prod-syd    non-destructive DR failover drill
#
# One root module serves every cell; CELL selects both the contract and the
# state prefix. There is no per-cell directory to keep in sync.
# ==============================================================================

CELL          ?=
VENTURE        = $(firstword $(subst /, ,$(CELL)))
CELL_NAME      = $(lastword $(subst /, ,$(CELL)))
CELL_FILE      = ventures/$(VENTURE)/cells/$(CELL_NAME).yaml
STATE_PREFIX   = cells/$(CELL)

# Set these for a real apply. `make check` needs none of them.
STATE_BUCKET     ?= $(shell cat .state-bucket 2>/dev/null)
BILLING_ACCOUNT  ?= $(shell cat .billing-account 2>/dev/null)
GITHUB_REPOSITORY ?= Valliam/gcp-cell-platform

TF        = terraform -chdir=stacks/cell
TF_VARS   = -var="cell_file=../../$(CELL_FILE)" \
            -var="state_bucket=$(STATE_BUCKET)" \
            -var="billing_account=$(BILLING_ACCOUNT)" \
            -var="github_repository=$(GITHUB_REPOSITORY)" \
            -var="config_sync_repo=https://github.com/$(GITHUB_REPOSITORY)"

STACKS  = stacks/bootstrap stacks/org stacks/cell
MODULES = $(wildcard modules/*)

.PHONY: help check fmt validate lint policy cells render render-check \
        init plan apply destroy drill outputs

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Credential-free checks (identical to the validate workflow) --------------

check: fmt validate cells render-check policy ## Run every offline check
	@echo "\n✓ all offline checks passed"

fmt: ## terraform fmt across the repo
	terraform fmt -check -recursive -diff

# terraform validate emits a trailing blank line, so match the message rather
# than taking the last line.
validate: ## terraform validate every module and stack
	@for d in $(MODULES) $(STACKS); do \
	  printf '  %-28s ' "$$d"; \
	  (cd $$d && terraform init -backend=false -input=false >/dev/null 2>&1 \
	    && terraform validate -no-color 2>&1 | grep -m1 -E 'Success|Error') || exit 1; \
	done

lint: ## tflint (requires tflint on PATH)
	tflint --recursive --format compact

# Not part of `check` because checkov pulls a large dependency tree; CI runs it
# on every pull request. Needs Python 3.11 or 3.12 — 3.13+ is not yet supported
# by this pinned version.
scan: ## checkov static analysis (requires checkov on PATH)
	checkov --directory . --framework terraform --config-file .checkov.yml

cells: ## Validate the cell registry: schema, residency, CIDR overlap, naming
	python3 scripts/validate_cells.py --root .

render: ## Regenerate platform/cells/** from the cell contracts
	python3 scripts/render_platform.py --root .

render-check: ## Fail if the committed Kubernetes baseline is stale
	python3 scripts/render_platform.py --root . --check

policy: ## Compliance audit, plus proof the policies can actually reject
	conftest test --policy policy ventures/*/cells/*.yaml
	@if conftest test --policy policy policy/fixtures/noncompliant-prod.yaml >/dev/null 2>&1; then \
	  echo "✗ the non-compliant fixture was accepted — the policy gate is broken"; exit 1; \
	else \
	  echo "✓ policy correctly rejects the non-compliant fixture"; \
	fi

# --- Cell lifecycle ------------------------------------------------------------

guard-cell:
	@test -n "$(CELL)" || { echo "CELL is required, e.g. make plan CELL=acme/prod-syd"; exit 1; }
	@test -f "$(CELL_FILE)" || { echo "no such cell contract: $(CELL_FILE)"; exit 1; }

init: guard-cell ## Init the cell stack against this cell's state prefix
	$(TF) init -input=false -reconfigure \
	  -backend-config="bucket=$(STATE_BUCKET)" \
	  -backend-config="prefix=$(STATE_PREFIX)"

plan: init ## Plan one cell
	$(TF) plan -input=false $(TF_VARS)

apply: init ## Apply one cell
	$(TF) apply -input=false $(TF_VARS)

outputs: init ## Show one cell's outputs
	$(TF) output -json | jq

# Prod cells set deletion_policy=PREVENT on the project and deletion_protection
# on the cluster and database, so this fails loudly on prod by design. Removing
# those guards is a reviewed change, not a flag on a destroy command.
destroy: init ## Destroy one cell (dev only; prod is protected)
	@grep -q 'env: prod' $(CELL_FILE) && { echo "refusing to destroy a prod cell"; exit 1; } || true
	$(TF) destroy -input=false $(TF_VARS)

drill: guard-cell ## Run the read-only DR failover drill
	bash scripts/dr_drill.sh $(CELL)
