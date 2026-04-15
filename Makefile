# CLIO Makefile
# SPDX-License-Identifier: GPL-3.0-only

PERL = perl
VERSION_FILE = VERSION
CURRENT_VERSION = $(shell cat $(VERSION_FILE) 2>/dev/null || echo "unknown")

.PHONY: help version test release check-syntax install

# Default target
help:
	@echo "CLIO $(CURRENT_VERSION)"
	@echo ""
	@echo "Targets:"
	@echo "  make version        - Show current version"
	@echo "  make test           - Run unit tests"
	@echo "  make check-syntax   - Syntax-check all Perl modules"
	@echo "  make release VERSION=YYYYMMDD.N - Prepare a new release"
	@echo "  make install        - Install CLIO (runs install.sh)"
	@echo ""

# Show current version
version:
	@echo "$(CURRENT_VERSION)"

# Run unit tests
test:
	@echo "Running tests..."
	@if [ -d tests/unit ]; then \
		failed=0; \
		for t in tests/unit/test_*.pl; do \
			echo "  $$t"; \
			$(PERL) -I./lib "$$t" || failed=1; \
		done; \
		if [ "$$failed" -eq 1 ]; then \
			echo "Some tests failed."; \
			exit 1; \
		fi; \
		echo "All tests passed."; \
	else \
		echo "No tests found in tests/unit/"; \
	fi

# Syntax-check all modules
check-syntax:
	@echo "Checking Perl syntax..."
	@failed=0; \
	find lib -name '*.pm' | while read f; do \
		if ! $(PERL) -I./lib -c "$$f" 2>&1 | grep -q "syntax OK"; then \
			echo "FAIL: $$f"; \
			failed=1; \
		fi; \
	done; \
	if ! $(PERL) -I./lib -c clio 2>&1 | grep -q "syntax OK"; then \
		echo "FAIL: clio"; \
		failed=1; \
	fi; \
	if [ "$$failed" -eq 1 ]; then \
		echo "Syntax checks failed."; \
		exit 1; \
	fi; \
	echo "All syntax checks passed."

# Prepare a release
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release VERSION=YYYYMMDD.N"; \
		echo "Example: make release VERSION=20260415.1"; \
		exit 1; \
	fi
	@./scripts/release.sh $(VERSION)

# Install
install:
	@./install.sh
