SHELL = /bin/sh

BIN = .tools/bin
LUAU = $(BIN)/luau
LUAU_LSP = $(BIN)/luau-lsp
STYLUA = $(BIN)/stylua
SELENE = $(BIN)/selene
TERN_DEFS = .tools/types/tern.lsp.d.luau

LUAU_DIRS = $(wildcard plugin tests)
FILTER =

.PHONY: bootstrap tools test test-runner-selfcheck e2e lint fmt fmt-check typecheck check \
	stack-up stack-down fixtures-capture

bootstrap:
	sh scripts/bootstrap.sh

tools:
	@for f in $(LUAU) $(LUAU_LSP) $(STYLUA) $(SELENE) $(TERN_DEFS); do \
		[ -e "$$f" ] || { echo "missing $$f: run 'make bootstrap'" >&2; exit 1; }; \
	done

# Zero specs is a valid state until the first pure module lands.
test: tools
	@set -- $$( [ -d tests/unit ] && find tests/unit -name '*.spec.luau' | sort); \
	if [ $$# -eq 0 ]; then echo "0 specs ran (no tests/unit/**/*.spec.luau yet)"; exit 0; fi; \
	if [ -n "$(FILTER)" ]; then set -- "$(FILTER)" "$$@"; fi; \
	$(LUAU) tests/run.luau -a "$$@"

test-runner-selfcheck: tools
	@LUAU=$(LUAU) sh tests/selfcheck/check.sh

# Drives an isolated sandbox Tern (local only).
e2e:
	@if [ -f scripts/e2e.sh ]; then sh scripts/e2e.sh; else echo "e2e skipped: scripts/e2e.sh does not exist yet"; fi

lint: tools
	$(SELENE) $(LUAU_DIRS)

fmt: tools
	$(STYLUA) $(LUAU_DIRS)

fmt-check: tools
	$(STYLUA) --check $(LUAU_DIRS)

typecheck: tools
	$(LUAU_LSP) analyze --platform=standard --definitions=@tern=$(TERN_DEFS) $(LUAU_DIRS)

check: fmt-check lint typecheck test-runner-selfcheck test

# Docker dev stack (dev/); scripts/stack.sh owns the details.
STACK = @[ -f scripts/stack.sh ] || { echo "scripts/stack.sh is missing: the dev stack is not set up" >&2; exit 1; }; sh scripts/stack.sh

stack-up:
	$(STACK) up

stack-down:
	$(STACK) down

fixtures-capture:
	$(STACK) capture
