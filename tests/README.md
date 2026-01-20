# CLIO Test Suite

Comprehensive testing framework for CLIO (Command Line Intelligence Orchestrator).

## Overview

The CLIO test suite is organized into three categories:

```
tests/
├── unit/              # Individual module tests
├── integration/       # Multi-module workflow tests  
├── e2e/               # Full CLIO execution tests
├── lib/               # Test framework (TestData.pm, TestHelpers.pm)
├── documentation/     # Test-related documentation
├── run_all_tests.pl   # Test runner
├── README.md          # This file
└── INVENTORY.md       # Complete test file inventory
```

## Quick Start

### Run All Tests

```bash
perl tests/run_all_tests.pl --all
```

### Run Specific Categories

```bash
# Unit tests only
perl tests/run_all_tests.pl --unit

# Integration tests only
perl tests/run_all_tests.pl --integration

# End-to-end tests only
perl tests/run_all_tests.pl --e2e

# Multiple categories
perl tests/run_all_tests.pl --unit --integration
```

### Verbose Mode

```bash
# Show output for all tests (not just failures)
perl tests/run_all_tests.pl --all --verbose
```

### Stop on First Failure

```bash
# Stop immediately when a test fails (useful for debugging)
perl tests/run_all_tests.pl --all --stop-on-failure
```
