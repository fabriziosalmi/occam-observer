# State Vectors

The engine reduces a diff to six vectors plus a bounded health score, then
derives a severity level suitable for gating pipelines.

## The six vectors

| Vector         | Field                              | Source                                                       |
|----------------|-------------------------------------|--------------------------------------------------------------|
| Security       | `metrics.security_violations`      | `grep -ciE` of added lines against `config/rules/security.yml` |
| Mass           | `metrics.mass_insertions/deletions/mass_files_changed` | `git diff --shortstat`                          |
| Entropy        | `metrics.entropy_nodes`            | lexical stripper (removes strings + comments) then branch-keyword count |
| Testing        | `metrics.test_files_modified`      | filename match against `config/rules/tests.yml`             |
| Debt           | `metrics.debt_issues`              | `grep -ciE` of added lines against `config/rules/debt.yml`   |
| Check verdict  | `check.level`, `check.reasons[]`   | derived (see below)                                         |

The regex bundles ship with sensible defaults; replace them with your own in
`config/rules/*.yml`. `--validate` confirms each `patterns` key is a valid
POSIX ERE before load.

## Health score

Starts at 100. Penalty rules:

| Trigger                                          | Penalty                            |
|--------------------------------------------------|-------------------------------------|
| Any `security_violations > 0`                    | -50                                |
| `mass_insertions > threshold_mass_critical`      | -(20 + files_changed × 2)          |
| `mass_insertions > threshold_mass_warn`          | -(10 + files_changed)              |
| `entropy_nodes > threshold_entropy_critical`     | -15                                |
| `entropy_nodes > threshold_entropy_warn`         | -8                                 |
| Each `debt_issues`                               | -5 per occurrence                  |
| Any `test_files_modified > 0`                    | +10 (clamped ≤ 100)                |

Clamped to `[0, 100]`. Exposed as `health_score` and shown as a bar in
the TUI / dashboard.

## Severity levels

Computed independently of the score; the score is a continuous heuristic,
severity is a discrete gate.

```
none  <  low  <  medium  <  high  <  critical
```

Promotion rules (always move up, never down):

| Level    | Promoted when                                                       |
|----------|---------------------------------------------------------------------|
| critical | `security_violations > 0` · `intelligence.syntax_invalid` non-empty · any analyzer finding `severity: critical` |
| high     | `mass_insertions > threshold_mass_critical` · `entropy_nodes > threshold_entropy_critical` · `infrastructure_changes` non-empty · `schema_mutations` non-empty · any analyzer `high` |
| medium   | `mass_insertions > threshold_mass_warn` · `entropy_nodes > threshold_entropy_warn` · `debt_issues >= 5` · any analyzer `medium` |
| low      | `debt_issues > 0` · `network_outbound` non-empty · any analyzer `low` |
| none     | no triggers                                                         |

`check.reasons[]` enumerates every trigger that fired, in the order listed
above. Agents can inspect this array to explain a failed `--check --fail-on`.

## Thresholds

Defaults (overridable in `config/main.yml`):

| Key                           | Default |
|-------------------------------|---------|
| `threshold_mass_warn`         | 150     |
| `threshold_mass_critical`     | 300     |
| `threshold_entropy_warn`      | 5       |
| `threshold_entropy_critical`  | 10      |

Constraint enforced by `--validate`: `warn < critical` for both mass and
entropy, otherwise the config is rejected with exit 3.

## Example `check` block

```json
"check": {
  "level": "critical",
  "reasons": [
    "security_violations=1",
    "mass=420>300",
    "schema_mutations_present",
    "analyzer_critical=2",
    "analyzer_high=1"
  ]
}
```

Each reason is a stable, machine-parseable token of the form
`<signal>=<value>` or `<signal>_present`.
