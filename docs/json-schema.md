# JSON Report Schema

Field-by-field documentation of the machine-readable JSON that `mutation_test`
produces (written to `mutation_report.json` and, with `--json`, streamed to
stdout). See the [Reports and output](../readme.md#reports-and-output) section of
the README for the stdout/stderr contract and the quick-start `jq` recipes.

A run that resolves exactly one positional source file, or an explicit
`SOURCE_FILE TEST_FILE` pair, prints the plain per-file report documented in
[Single-file report](#single-file-report-schema_version-1). A multi-file run (a
`FILE` list with more than one file, `--staged`, or `--glob`) prints one
aggregate envelope instead; see
[Multi-file runs: the aggregate envelope](#multi-file-runs-the-aggregate-envelope).

## Schema versioning

The report carries a top-level `schema_version` (currently `1`). It is bumped on
any **incompatible** change to the shape (a removed or renamed field, or a
changed type or meaning); purely additive fields do not bump it. Read
`schema_version` before relying on the payload, and see the CHANGELOG for the
history of changes.

## Single-file report (schema_version 1)

```json
{
  "schema_version": 1,
  "interrupted": false,
  "metadata": {
    "version": "1.0.0",
    "generated_at": "2024-01-15T10:30:00Z",
    "source_file": "app/models/user.rb"
  },
  "summary": {
    "total": 20,
    "killed": 18,
    "survived": 2,
    "mutation_score": 90.0
  },
  "mutations": [
    ...
  ]
}
```

| Field                          | Type    | Description                                                                                                                                                                                                                                                                                                                                     |
|--------------------------------|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `schema_version`               | integer | Version of this schema. Start value `1`.                                                                                                                                                                                                                                                                                                        |
| `interrupted`                  | boolean | Additive (does not bump `schema_version`). `true` only when `--fail-fast` stopped the run before every generated mutation was processed, so the report is partial; `false` for a complete run, including a run whose first surviving mutant was the last mutation.                                                                              |
| `metadata.version`             | string  | Version of the `mutation_tester` gem that produced the report.                                                                                                                                                                                                                                                                                  |
| `metadata.generated_at`        | string  | ISO 8601 timestamp of when the report was generated.                                                                                                                                                                                                                                                                                            |
| `metadata.source_file`         | string  | Absolute path of the mutated source file.                                                                                                                                                                                                                                                                                                       |
| `metadata.spec_file`           | string  | Absolute path of the test file that was run.                                                                                                                                                                                                                                                                                                    |
| `summary.total`                | integer | Total number of mutations produced (all statuses).                                                                                                                                                                                                                                                                                              |
| `summary.killed`               | integer | Effective kills (a `timeout` counts as a kill; under the opt-in `timeout_policy: :separate` only real kills are counted). Kept for backward compatibility.                                                                                                                                                                                      |
| `summary.survived`             | integer | Number of surviving mutants.                                                                                                                                                                                                                                                                                                                    |
| `summary.mutation_score`       | number  | Percentage `(killed + timeout) / (killed + timeout + survived) * 100`, rounded to 2 decimals; under the opt-in `timeout_policy: :separate` it is `killed / (killed + survived) * 100` with timeouts excluded. `stillborn` and `error` are excluded from the denominator.                                                                        |
| `summary.quality_rating`       | string  | Human label derived from the score (Excellent/Good/Fair/Poor/Critical).                                                                                                                                                                                                                                                                         |
| `summary.categories.killed`    | integer | Mutants whose covering tests failed.                                                                                                                                                                                                                                                                                                            |
| `summary.categories.survived`  | integer | Mutants whose covering tests still passed (a test gap candidate).                                                                                                                                                                                                                                                                               |
| `summary.categories.timeout`   | integer | Mutants that exceeded the per-mutant deadline (counted as kills in the score by default; excluded from the score under `timeout_policy: :separate`).                                                                                                                                                                                            |
| `summary.categories.stillborn` | integer | Mutants whose code no longer parses. Never run; excluded from the score.                                                                                                                                                                                                                                                                        |
| `summary.categories.error`     | integer | Mutants that hit a runner-side error. Excluded from the score.                                                                                                                                                                                                                                                                                  |
| `mutations[].id`               | integer | Stable id of the mutation within this run.                                                                                                                                                                                                                                                                                                      |
| `mutations[].type`             | string  | Mutation category (e.g. `arithmetic`, `boolean`, `comparison`, `call_removal`, `nil_injection`, `argument`, `strict_equality` when the opt-in mode is enabled).                                                                                                                                                                                 |
| `mutations[].line`             | integer | 1-based line number of the mutated code.                                                                                                                                                                                                                                                                                                        |
| `mutations[].file_path`        | string  | Absolute path of the mutated source file.                                                                                                                                                                                                                                                                                                       |
| `mutations[].original`         | string  | The original operator/literal that was mutated; for `call_removal`, the removed call expression (e.g. `items.uniq`); for `nil_injection`, the replaced expression (e.g. `self`); for `argument`, the full original call (e.g. `raise ArgumentError, msg`) or, for a default-value mutant, the original parameter (e.g. `opts = {}`).            |
| `mutations[].mutated`          | string  | The replacement operator/literal; for `call_removal`, the bare receiver (e.g. `items`); for `nil_injection`, always `nil`; for `argument`, the call after the mutation (e.g. `raise ArgumentError`) or, for a default-value mutant, the parameter after the mutation (e.g. `opts` or `opts = nil`).                                             |
| `mutations[].source_line`      | string  | The original source line.                                                                                                                                                                                                                                                                                                                       |
| `mutations[].mutated_line`     | string  | The source line after mutation.                                                                                                                                                                                                                                                                                                                 |
| `mutations[].killed`           | boolean | Legacy passthrough flag from the runner (`true` for `killed` and `timeout`). Kept for backward compatibility; prefer `status`.                                                                                                                                                                                                                  |
| `mutations[].timeout`          | boolean | Legacy passthrough flag from the runner (`true` only when the mutant timed out). Kept for backward compatibility; prefer `status`.                                                                                                                                                                                                              |
| `mutations[].status`           | string  | One of the taxonomy statuses below. This is the authoritative per-mutant result.                                                                                                                                                                                                                                                                |
| `mutations[].description`      | string  | Human-readable description of the mutation (for `error`, the failure message).                                                                                                                                                                                                                                                                  |
| `kill_matrix`                  | boolean | Optional, additive (does not bump `schema_version`). Present and `true` only for a run with the opt-in `--kill-matrix` mode, which guarantees that every `mutations[].killed_by` list is complete. Absent otherwise. See [Kill matrix fields](#kill-matrix-fields-opt-in).                                                                       |
| `tests[]`                      | array   | Optional, additive. Present only with `--kill-matrix`: every test of the unmutated baseline run, ordered by line. See [Kill matrix fields](#kill-matrix-fields-opt-in).                                                                                                                                                                       |
| `mutations[].killed_by`        | array   | Optional, additive. Present only with `--kill-matrix`, on every mutant: the sorted `tests[].id` values of every test that failed under this mutant. See [Kill matrix fields](#kill-matrix-fields-opt-in).                                                                                                                                       |
| `mutations[].diff`             | string  | Optional, additive (does not bump `schema_version`). Present only for `survived` and `timeout` mutants: a unified diff of the change with a few lines of surrounding context (`@@` hunk header, lines prefixed with `- `, `+ ` or two spaces). Falls back to a context-free `- `/`+ ` pair when the source file is not readable at report time. |

**Status taxonomy** (`mutations[].status`): `killed` (tests caught it), `survived`
(tests missed it), `timeout` (ran too long, scored as a kill), `stillborn`
(unparseable, excluded from the score), `error` (runner failure, excluded from
the score).

## Kill matrix fields (opt-in)

A normal run stops every mutant at its first failing test, so it cannot say which
tests kill a mutant and emits none of the fields below. With `--kill-matrix`
(`config.kill_matrix = true`) every mutant runs the full test file, on every
runner and for both RSpec and Minitest, and the report gains:

```json
{
  "schema_version": 1,
  "interrupted": false,
  "kill_matrix": true,
  "tests": [
    { "id": "InvoiceTest#test_rejects_negative_total", "name": "test_rejects_negative_total", "line": 12, "status": "passed" },
    { "id": "InvoiceTest#test_total_sums_lines", "name": "test_total_sums_lines", "line": 20, "status": "passed" }
  ],
  "mutations": [
    {
      "id": 12,
      "status": "killed",
      "line": 41,
      "killed_by": ["InvoiceTest#test_rejects_negative_total", "InvoiceTest#test_total_sums_lines"]
    }
  ]
}
```

| Field                   | Type            | Description                                                                                                                                                                                                                                                              |
|-------------------------|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `tests[].id`            | string          | Stable id of the test within the run. Minitest: `TestClass#test_name`. RSpec: the spec path relative to the project root plus the scoped example id, e.g. `spec/invoice_spec.rb[1:2:1]`, which `rspec` accepts as an argument from the project root.                      |
| `tests[].name`          | string          | Human-readable name: the full example description for RSpec, the test method name for Minitest.                                                                                                                                                                          |
| `tests[].line`          | integer or null | 1-based line where the test is defined in the test file. `null` when the framework does not report it or the example is defined in another file (RSpec shared examples).                                                                                                 |
| `tests[].status`        | string          | `passed` or `skipped` (RSpec `pending`/`skip`/`xit`, Minitest `skip`) in the baseline run. The baseline must pass, so there is no `failed`.                                                                                                                              |
| `mutations[].killed_by` | array of string | Sorted ids of every test that failed under the mutant. Always `[]` for `survived`, `stillborn`, `error` and `timeout`. Also `[]` for a `killed` mutant whose run failed without any test failing (typically the mutated file no longer loads, or an error outside a test). |

An empty `killed_by` on a `killed` or `timeout` mutant means the killers are
**unknown**, not that there are none: a consumer must never call a test redundant
because of such a mutant. In the multi-file envelope the fields appear inside each
`files[]` report. The redundancy recipes live under
[Finding redundant tests](../readme.md#finding-redundant-tests) in the README.

## Extracting the score and the survived mutants

A ready-to-use snippet for an agent or script: read the score and list every
surviving mutant with its location.

```bash
# Overall score and per-status breakdown
bundle exec mutation_test --json examples/calculator.rb examples/calculator_spec.rb \
  | jq '{score: .summary.mutation_score, categories: .summary.categories}'

# Just the survivors: file, line and what changed (the test gaps to close)
bundle exec mutation_test --json examples/calculator.rb examples/calculator_spec.rb \
  | jq '[.mutations[] | select(.status == "survived")
         | {file: .file_path, line: .line, from: .original, to: .mutated}]'
```

## Multi-file runs: the aggregate envelope

With `--json` on a multi-file run (a `FILE` list with more than one file,
`--staged`, or `--glob`) stdout carries exactly one JSON document: an envelope
with a top-level `schema_version`, a run summary, a condensed `survivors` array,
and the full per-file reports. All diagnostics and progress stay on stderr, and
the exit code keeps its meaning (`0` passed, `1` failed).

```json
{
  "schema_version": 1,
  "summary": {
    "files": 3,
    "processed": 2,
    "skipped": [
      {
        "file": "lib/orphan.rb",
        "reason": "no matching spec file"
      }
    ],
    "score": 83.33,
    "passed": false,
    "interrupted": false
  },
  "survivors": [
    {
      "file": "/home/you/project/lib/calc.rb",
      "line": 4,
      "type": "arithmetic",
      "original": "+",
      "mutated": "-"
    }
  ],
  "files": [
    {
      "schema_version": 1,
      "...": "one full per-file report per processed file"
    }
  ]
}
```

| Field                  | Type    | Description                                                                                                                                                                                                                                  |
|------------------------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `schema_version`       | integer | Version of the envelope schema. Start value `1`. Distinct from the per-file `files[].schema_version`: the envelope and the per-file report version independently.                                                                            |
| `summary.files`        | integer | Files that entered the run: processed plus skipped. Files a `--since` filter left out as unchanged are not counted; they are reported on stderr.                                                                                             |
| `summary.processed`    | integer | Files that were actually mutation-tested.                                                                                                                                                                                                    |
| `summary.skipped`      | array   | One entry per skipped file: `file` (the path as given) and `reason`, one of `file not found`, `not a Ruby source file`, `a test file, not a mutable source`, `no matching spec file`.                                                        |
| `summary.score`        | number  | Aggregate mutation score over every mutant of every processed file, with the per-file formula: `(killed + timeout) / (killed + timeout + survived) * 100` (or `killed / (killed + survived) * 100` under `timeout_policy: :separate`), rounded to 2 decimals; `stillborn` and `error` are excluded from the denominator. |
| `summary.passed`       | boolean | `true` exactly when the process exits `0`: the run matched/processed files and every processed file met the threshold.                                                                                                                       |
| `summary.interrupted`  | boolean | `true` when `--fail-fast` stopped the batch at a surviving mutant, so remaining files were not run and the envelope is partial.                                                                                                              |
| `survivors[].file`     | string  | Absolute path of the mutated source file, the same convention as `files[].metadata.source_file`, so a survivor joins its full per-file report by an exact string match on this value.                                                        |
| `survivors[].line`     | integer | 1-based line number of the mutated code.                                                                                                                                                                                                     |
| `survivors[].type`     | string  | Mutation category, same values as `mutations[].type`.                                                                                                                                                                                        |
| `survivors[].original` | string  | The original code fragment.                                                                                                                                                                                                                  |
| `survivors[].mutated`  | string  | The fragment after the mutation.                                                                                                                                                                                                             |
| `files[]`              | object  | One complete per-file report per processed file, exactly the single-file schema above: `schema_version`, `interrupted`, `metadata`, `summary`, and `mutations` with the five statuses `killed`, `survived`, `timeout`, `stillborn`, `error`. |

`survivors` is the agent-facing view: every mutant the tests failed to detect,
with just the fields needed to decide which test to add and where, so there is
no need to descend into `files[]` for the common loop.

```bash
# The test gaps to close, straight from the staging area
bundle exec mutation_test --staged --json | jq '.survivors'

# Join a survivor to its full per-file report: survivors[].file == files[].metadata.source_file
bundle exec mutation_test --staged --json \
  | jq '.survivors[0] as $s | .files[] | select(.metadata.source_file == $s.file)'

# Gate a script on the aggregate outcome (exit code of jq -e follows .summary.passed)
bundle exec mutation_test --staged --json | jq -e '.summary.passed'
```
