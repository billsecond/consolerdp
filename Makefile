# Developer Makefile — convenience targets only. Production install is via
# ./install.sh on the target host.

PY     ?= python3
RUFF   ?= ruff
SHELLCHECK ?= shellcheck

.PHONY: help lint test fmt check shellcheck unit clean

help:
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-15s %s\n",$$1,$$2}' $(MAKEFILE_LIST)

lint: shellcheck pylint  ## Run all linters

pylint:  ## Lint Python with ruff if available
	@if command -v $(RUFF) >/dev/null; then \
		$(RUFF) check bin/ tests/ ; \
	else \
		echo "ruff not installed, skipping"; \
	fi

shellcheck:  ## Lint shell scripts
	@if command -v $(SHELLCHECK) >/dev/null; then \
		$(SHELLCHECK) -x install.sh uninstall.sh \
			bin/consolerdp-takeover bin/consolerdp-release ; \
	else \
		echo "shellcheck not installed, skipping"; \
	fi

test: unit  ## Run all tests

unit:  ## Run unit tests (pytest if available, else stdlib smoke)
	@if $(PY) -c 'import pytest' 2>/dev/null; then \
		$(PY) -m pytest -q tests/ ; \
	else \
		echo "pytest not installed, falling back to stdlib smoke tests" ; \
		$(PY) tests/smoke.py ; \
	fi

fmt:  ## Format Python code with ruff
	@$(RUFF) format bin/ tests/ 2>/dev/null || true

check: lint test  ## CI entrypoint

clean:
	rm -rf .pytest_cache .ruff_cache __pycache__ */__pycache__
