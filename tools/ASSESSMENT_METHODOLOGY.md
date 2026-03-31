# CLIO Assessment Methodology

**Version:** 1.0
**Date:** 2026-03-31
**Tool:** `tools/assess_codebase.pl`

---

## Principles

1. Every metric must be **automatically collectible** (no human interpretation)
2. Rubric thresholds are **defined before** seeing data, not adjusted after
3. Categories and weights are **fixed across assessments**
4. Both code quality AND product completeness are measured
5. Metrics are **normalized per-module** where growth would inflate absolutes

---

## Categories and Weights

| # | Category | Weight | What It Measures |
|---|----------|--------|------------------|
| 1 | Code Hygiene | 10% | strict/warnings/utf8 coverage, POD, consistent JSON/Logger/croak usage |
| 2 | Error Handling | 10% | eval blocks with $@ checking, croak vs bare die |
| 3 | Architecture | 20% | Module size distribution, namespace count, import fan-out, dead modules |
| 4 | Method Quality | 15% | Methods >100 lines (rate), >200 lines (count), worst method, top-5 average |
| 5 | Testing | 15% | Unit/integration pass rates, test/module ratio, CI, runner reliability |
| 6 | Product Completeness | 15% | Tools, providers, protocols, commands, CI, containers, install methods |
| 7 | Documentation | 10% | README, doc files, SYNOPSIS/method POD coverage, CONTRIBUTING/LICENSE |
| 8 | Dependencies & Portability | 5% | CPAN deps, Perl version requirement, platform support |

---

## Scoring Rubric

### Category 1: Code Hygiene (10%)

| Score | Criteria |
|-------|----------|
| 10/10 | 100% strict+warnings+utf8+POD, 0 print STDERR leaks, 0 JSON::PP direct |
| 9/10 | >95% coverage, <5 legacy patterns |
| 8/10 | >90% coverage, <15 legacy patterns |
| 7/10 | >80% coverage, <30 legacy patterns |
| 6/10 | >60% coverage |
| 5/10 | <60% coverage |

### Category 2: Error Handling (10%)

| Score | Criteria |
|-------|----------|
| 10/10 | >95% evals checked, 0 bare die outside fork/signal |
| 9/10 | >90% evals checked, <5 bare die |
| 8/10 | >80% evals checked, <15 bare die |
| 7/10 | >70% evals checked, <30 bare die |
| 6/10 | >60% evals checked |
| 5/10 | <60% evals checked |

**Note:** "Checked" includes both proper `$@` handling AND intentional defensive try-ignore (short eval blocks).

### Category 3: Architecture (20%)

| Score | Criteria |
|-------|----------|
| 10/10 | 0 modules >1000 lines, >10 namespaces, max fan-out <50, 0 dead modules |
| 9/10 | <3% modules >1000 lines, >8 namespaces, fan-out <75, <3 dead |
| 8/10 | <7% modules >1000 lines, >6 namespaces, fan-out <100 |
| 7/10 | <10% modules >1000 lines, >5 namespaces |
| 6/10 | <15% modules >1000 lines, >3 namespaces |
| 5/10 | >15% modules >1000 lines |

**Note:** Fan-out for Logger-type modules is expected to be high and is not a concern if the module is stable.

### Category 4: Method Quality (15%)

| Score | Criteria |
|-------|----------|
| 10/10 | 0 methods >200 lines, <0.3 rate >100-line/module, worst <150 |
| 9/10 | <3 methods >200 lines, <0.5 rate, worst <250 |
| 8/10 | <8 methods >200 lines, <0.7 rate, worst <400 |
| 7/10 | <15 methods >200 lines, <1.0 rate, worst <600 |
| 6/10 | <25 methods >200 lines, <1.5 rate, worst <1000 |
| 5/10 | >25 methods >200 lines or worst >1000 |

**Note:** Template/data methods (like prompt content) count the same as logic methods. The metric measures maintainability, not complexity.

### Category 5: Testing (15%)

| Score | Criteria |
|-------|----------|
| 10/10 | >95% unit pass, >90% integration pass, test/module ratio >0.8, runner works |
| 9/10 | >95% unit pass, >80% integration pass, ratio >0.6 |
| 8/10 | >90% unit pass, >70% integration pass, ratio >0.5 |
| 7/10 | >85% unit pass, >60% integration pass, ratio >0.4 |
| 6/10 | >80% unit pass, >50% integration pass |
| 5/10 | <80% unit pass |

**Note:** Infrastructure-dependent tests (requiring broker, running agents, etc.) are counted separately and do not affect standalone integration pass rate.

### Category 6: Product Completeness (15%)

| Score | Criteria |
|-------|----------|
| 10/10 | >10 tools, >2 providers, MCP support, multi-agent, CI, container, 2+ install methods |
| 9/10 | >8 tools, >2 providers, CI, container OR install script |
| 8/10 | >6 tools, >1 provider, CI |
| 7/10 | >4 tools, 1 provider |
| 6/10 | >2 tools |
| 5/10 | <3 tools |

### Category 7: Documentation (10%)

| Score | Criteria |
|-------|----------|
| 10/10 | README >200 lines, >15 doc files, >90% SYNOPSIS, >90% method POD, CONTRIBUTING+LICENSE |
| 9/10 | README >100 lines, >10 doc files, >80% SYNOPSIS, >80% method POD |
| 8/10 | README exists, >5 doc files, >60% SYNOPSIS |
| 7/10 | README exists, >3 doc files |
| 6/10 | README exists |
| 5/10 | No README |

### Category 8: Dependencies & Portability (5%)

| Score | Criteria |
|-------|----------|
| 10/10 | 0 CPAN deps, Perl 5.14+, Docker + native support |
| 9/10 | <3 CPAN deps, core Perl |
| 8/10 | <5 CPAN deps, common modules only |
| 7/10 | <10 CPAN deps |
| 6/10 | <20 CPAN deps |
| 5/10 | >20 CPAN deps or compiled XS required |

---

## Usage

```bash
# Full report with raw metrics
perl tools/assess_codebase.pl

# JSON output (for tracking/automation)
perl tools/assess_codebase.pl --json

# Score summary only
perl tools/assess_codebase.pl --score-only
```

---

## Changelog

| Version | Date | Change |
|---------|------|--------|
| 1.0 | 2026-03-31 | Initial methodology. 8 categories, fixed rubrics, automated collector. |
