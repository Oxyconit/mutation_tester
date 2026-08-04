# MutationTester 🧬

[![CI](https://github.com/Oxyconit/mutation_tester/actions/workflows/ci.yml/badge.svg)](https://github.com/Oxyconit/mutation_tester/actions/workflows/ci.yml)

Simple mutation testing framework for Ruby applications with RSpec or Minitest. Improve your AI workflow and test
quality by identifying weak spots in your test suite through code mutations.

```bash
# Install, then mutation-test a file (its spec is found by convention):
bundle add mutation_tester
bundle exec mutation_test lib/calculator.rb
```

See [Getting Started](#getting-started) for the full quick start.

## Table of Contents

- [Features](#features)
- [Requirements and Compatibility](#requirements-and-compatibility)
- [Installation](#installation)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Configuration](#configuration)
- [Execution model](#execution-model)
- [Mutation types](#mutation-types)
- [Equivalent mutants](#equivalent-mutants)
- [Reports and output](#reports-and-output)
- [Pre-push hook](#pre-push-hook)
- [CI/CD integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

Reference material lives under [`docs/`](docs): the full
[mutation catalog](docs/mutation-types.md), the [JSON report schema](docs/json-schema.md),
and the [CI/CD recipes](docs/ci.md).

## Features

- ✅ **Multiple Mutation Types**: Arithmetic, comparison, logical, boolean, number, string, conditional, call-removal,
  nil-injection, and argument mutations, plus an opt-in strict-equality mode
- 📊 **Rich Reporting for you and your AI workflow**: Console, HTML, and JSON reports
- ⚡ **Fast by Default**: Runs mutants in memory and in parallel on the available CPU cores out of the box, with an
  always-announced fallback to file-based execution
- 🔧 **Configurable**: Customize mutation types, parallel processes, and thresholds
- 🚀 **Rails Integration**: Rake tasks for easy integration
- 💎 **Clean API**: Simple and intuitive interface

## Requirements and Compatibility

MutationTester keeps its requirements low so it drops into a wide range of projects.

| Component               | Supported       | Notes                                                                                                                                                                                                                                                              |
|-------------------------|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Ruby                    | `>= 3.0`        | Floor is Ruby 3.0. CI runs the suite on 3.0, 3.1, 3.2 and 3.3. The gem is developed on Ruby 4.0.2, and 4.x is supported. Ruby 4.x has no prebuilt binary on the GitHub-hosted runners yet, so it is verified on the development host rather than in the CI matrix. |
| RSpec (your project)    | `3.x`           | The gem shells out to your project's own `rspec`, so any RSpec 3.x works. Both ends of the range are exercised by a real mutation run: the lowest 3.0.x line in the CI framework matrix, and 3.13.x in the example jobs.                                           |
| Minitest (your project) | `5.x` and `6.x` | The gem runs your project's own test file (`ruby test_file.rb`, or the same file inside a preloaded fork worker), so both the 5.x and 6.x lines work. Both are exercised by a real mutation run: 5.x in the example jobs, and 6.x in the CI framework matrix.                                                          |

Notes:

- These are the versions the gem runs *your* tests against. It detects the framework, runs a baseline, then runs the
  covering tests for each mutant, all inside your project's environment (through `bundle exec` when your project has a
  `Gemfile`).
- Every advertised framework version is backed by CI, not just the ones the gem's dev bundle happens to pin. A dedicated
  `framework-matrix` job (see `.github/workflows/ci.yml`) installs an alternate user-project bundle for each boundary
  version (`gemfiles/minitest6.gemfile` and `gemfiles/rspec3_low.gemfile`) and runs an end-to-end mutation run against
  it via `gemfiles/run_matrix.rb`; the job is green only when every mutant is killed on that version.
- The gem's *own* test suite pins `minitest ~> 5.0`, because Minitest 6.x dropped `minitest/mock`, which those internal
  tests use. That pin does not constrain your project: your project may use Minitest 5.x or 6.x, and the 6.x path is
  verified through the framework matrix above rather than the gem's dev bundle.
- On Ruby 3.4+/4.x the bundled `parser` gem prints one benign syntax-level warning per run (it recognizes syntax up to
  Ruby 3.3); see [Parser Version Warning on Newer Ruby](#parser-version-warning-on-newer-ruby-supported-syntax-level).

## Installation

MutationTester requires Ruby >= 3.0 (see [Requirements and Compatibility](#requirements-and-compatibility)). There are
two supported ways to install it.

### In your project's bundle (recommended)

Add it to your application's `Gemfile` and install in one step:

```bash
bundle add mutation_tester
```

(this writes `gem "mutation_tester"` into your `Gemfile` and runs `bundle install`).

Then run it through Bundler so it uses your project's locked dependency versions:

```bash
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

### As a global gem

Install it once, system-wide:

```bash
gem install mutation_tester
```

Then run the `mutation_test` command directly (no `bundle exec`):

```bash
mutation_test app/models/user.rb spec/models/user_spec.rb
```

This is convenient for a project that does not list the gem in its `Gemfile`.
The CLI then cannot load itself from that project bundle, so it loads the
globally installed gem *outside* the bundle and prints one line to stderr:

```
mutation_tester loaded outside the project bundle
```

In this fallback the gem and its own dependencies (parser, unparser, parallel,
rainbow) come from the global install, so their versions may differ from your
project's `Gemfile.lock`. Your own tests are unaffected: when your project has a
`Gemfile`, each mutant still runs through `bundle exec`, in your project's
environment. Running in a directory with no `Gemfile` at all works too and
prints no notice. If your project *does* list `mutation_tester`, prefer
`bundle exec mutation_test ...`, which runs fully inside your bundle with no
notice.

## Getting Started

Install the gem, then point `mutation_test` at one or more source files. Each
file is mapped to its spec by convention (`lib/X.rb` -> `spec/X_spec.rb`,
override with `--spec-glob`):

```bash
# Install
bundle add mutation_tester

# Test a file: the spec is found by convention (lib/X.rb -> spec/X_spec.rb)
bundle exec mutation_test lib/calculator.rb

# Test several files in one aggregated run
bundle exec mutation_test lib/calculator.rb lib/parser.rb

# Test exactly what you have staged in git (the "test what I changed" flow)
bundle exec mutation_test --staged

# Minitest layout under test/
bundle exec mutation_test --spec-glob 'test/{name}_test.rb' lib/calculator.rb

# Or point at the test file explicitly: exactly two arguments, the second a test file
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
bundle exec mutation_test lib/calculator.rb test/calculator_test.rb

# Or with rake (non-Rails: first add `require 'mutation_tester/rake_task'` to your Rakefile)
bundle exec rake "mutation_test[app/models/user.rb,spec/models/user_spec.rb]"
```

That's it! 🎉 The gem will:

- ✅ Run your original tests to make sure they pass
- ✅ Generate mutations of your code
- ✅ Run tests against each mutation
- ✅ Generate reports showing which mutations survived

Press Ctrl+C at any time to stop early: the run cleans up its worker processes and temporary workspaces, prints a single
interruption line (no backtrace), and exits with status 130.

See [Usage](#usage) for the full command reference and [Configuration](#configuration) to tune it.

## Usage

`mutation_test` is the main CLI executable for running mutation tests. Pass one
or more source files (specs mapped by convention), the git staging area, an
explicit pair, or a glob:

```bash
# Main interface: one or more source files, specs mapped by convention
mutation_test [OPTIONS] FILE...

# The files currently staged in git (see File lists and --staged below)
mutation_test [OPTIONS] --staged

# Explicit pair: exactly two arguments where the second is a test file
mutation_test [OPTIONS] SOURCE_FILE TEST_FILE

# Many files in one run: select sources with a glob (see Batch mode below)
mutation_test [OPTIONS] --glob 'lib/**/*.rb'
```

**Arguments:**

- `FILE...` - Ruby source files to mutate; each is mapped to its spec by convention (`lib/X.rb` -> `spec/X_spec.rb`,
  override with `--spec-glob`). Files that cannot be mutated are reported as skipped with a reason (
  see [File lists and --staged](#file-lists-and---staged-test-what-you-changed)).
- `SOURCE_FILE TEST_FILE` - Explicit pair: with exactly two arguments where the second is recognized as a test file (
  `*_spec.rb`, `*.spec.rb`, `*_test.rb`, `test_*.rb`, or a file requiring minitest), the second is used as the test file
  directly.

### CLI options

| Flag | Description |
|---|---|
| `-p, --parallel N` | Run with N parallel processes (default: auto, derived from the CPU core count with a cap of 8; `-p 1` forces serial execution). |
| `--runner MODE` | Mutant execution runner: `auto` (default) tries `in_memory` first (`Process.fork` available and a passing unmutated-source probe), then falls back to `fork`, then `spawn`, announcing every step down on stderr with its reason; `fork` (preloaded environment, on platforms with `Process.fork`), `spawn` (one full process per mutant) and `in_memory` (mutations applied in child-process memory, zero file writes per mutant) force the specific mode. See [Execution runners](#execution-runners-fork-spawn-in-memory). |
| `--staged` | Mutation-test the files staged in git (`git diff --cached --name-only`; files staged as deleted are ignored), mapping each to its spec like a positional `FILE` list. Cannot be combined with positional arguments or `--glob`. See [File lists and --staged](#file-lists-and---staged-test-what-you-changed). |
| `--glob PATTERN` | Batch mode: mutation-test every source file matching `PATTERN`, mapping each to its spec by convention (see [Batch mode](#batch-mode-run-many-files-in-one-command)). |
| `--spec-glob TEMPLATE` | Spec-mapping template with a `{name}` placeholder (default: `spec/{name}_spec.rb`). Requires a positional `FILE` list, `--staged`, or `--glob`. |
| `--since REV` | Incremental batch mode: mutate only the files matched by `--glob` that changed since git revision `REV` (new files count as changed). Requires `--glob`. See [Incremental mode](#incremental-mode-mutate-only-what-changed). |
| `--fail-fast` | Stop the run at the first surviving mutant and finish with a failing status. Works in single-file mode and with `--glob`. |
| `--timeout-factor N` | Per-mutant timeout budget as `N` times the measured baseline test run, never below 5 s (default: 5, must be > 0). Ignored when `config.timeout` is set explicitly, which keeps a fixed budget. See [Configuration](#configuration). |
| `--timeout-policy MODE` | Scoring policy for timed-out mutants: `killed` (default) counts a timeout as a kill; `separate` keeps timeouts out of the score entirely (`killed / (killed + survived)`) and reports them only as their own category in the console, JSON and HTML reports. |
| `--worker-env NAME` | Set environment variable `NAME` to a distinct per-worker value before each parallel worker boots (`parallel_tests` `TEST_ENV_NUMBER` convention: worker 0 -> `""`, worker N -> `N+1`), so a `parallel_tests`-style `database.yml` selects a per-worker database. You provision the databases (e.g. `rake parallel:prepare`). Not supported by the `in_memory` runner (it falls back to `fork`). See [Making parallelism work with Rails](#making-parallelism-work-with-rails). |
| `--strict-equality` | Enable the opt-in strict-equality probes (`==` → `eql?` and `==` → `equal?`). Default off; expect noise on code that does not distinguish numeric types or object identity. See [Strict Equality Mutations](docs/mutation-types.md#strict-equality-mutations-opt-in). |
| `-h, --help` | Show help message. |
| `-v, --version` | Show version. |
| `--verbose` | Show a per-mutation warning for every skipped mutation (quiet by default; the "Generated N mutations, skipped M" summary always prints when mutants are dropped). |
| `--no-progress` | Disable progress display. |
| `--no-test-selection` | Disable two-phase test selection and always run the full test file for every mutant. See [Test selection](#test-selection-fast-kill-with-full-file-confirmation). |
| `--json` | Machine mode: print ONLY the JSON report to stdout (banner, progress and colours go to stderr). A single file prints the per-file report; a multi-file run (`FILE` list with more than one file, `--staged`, `--glob`) prints one aggregate envelope with a condensed `survivors` list. See [Reports and output](#reports-and-output). |
| `--reporters LIST` | Comma-separated reporters to run: `console`, `html`, `json` (default: `console,html,json`). An unknown name errors and exits 1. |
| `--output-dir PATH` | Directory for the generated report files (default: `tmp/mutation_reports`). In batch mode each file writes to its own subdirectory under this path. |

```bash
# Choose which reporters run and where their files land
bundle exec mutation_test --reporters json,html --output-dir build/mutation \
  app/models/user.rb spec/models/user_spec.rb
```

### Exit codes (single-file mode)

- `0` - the run passed (score met the threshold, or `fail_on_threshold` is disabled).
- `1` - the mutation score is below the threshold, or the input is unusable (missing
  file, unknown reporter, source with a syntax error).
- `2` - a usage error (conflicting flags; see the batch sections below).
- `3` - the run aborted or degraded before reaching a verdict: the shadow workspace
  was unreliable (the unmutated source failed there, or the workspace copy of the
  source turned out not to be the code the tests execute), or every mutant ended as
  `error`/`stillborn` so nothing was scored.
  This signals an infrastructure or runner problem, not a test-quality gap, so CI
  hooks can distinguish it from a genuine threshold failure.
- `130` - interrupted with Ctrl+C.

Batch modes (`FILE...` lists, `--staged`, `--glob`) keep the exit codes documented in
their sections below (`0`/`1`/`2`); a degraded file is named explicitly in the batch
summary instead of being blamed on the threshold.

### Running with rake

You can also run mutation tests through rake tasks.

In a **non-Rails** project, require the tasks from your `Rakefile`:

```ruby
# Rakefile
require 'mutation_tester/rake_task'
```

In a **Rails** app the tasks load automatically through the gem's railtie, so no
Rakefile change is needed.

Then run either task. Rake takes the file arguments inside brackets (not
space-separated), so quote the invocation for your shell:

```bash
# Top-level task
bundle exec rake "mutation_test[app/models/user.rb,spec/models/user_spec.rb]"

# Namespaced task
bundle exec rake "mutation:test[app/models/user.rb,spec/models/user_spec.rb]"
```

### Programmatic usage

You can also run the gem directly from Ruby with `MutationTester.run(source, test)`:

```ruby
# RSpec
MutationTester.run('examples/calculator.rb', 'examples/calculator_spec.rb')

# Minitest
MutationTester.run('examples/calculator.rb', 'examples/calculator_minitest.rb')
```

### File lists and --staged: test what you changed

Passing one or more source files is the main interface. Each file is mapped to
its spec by convention (`lib/X.rb` -> `spec/X_spec.rb`, override with
`--spec-glob`), and the whole list runs as one aggregated batch: every file is
processed, the summary shows one `PASS`/`FAIL` line per file, reports land in
per-file subdirectories, and the exit code reflects the whole run.

```bash
bundle exec mutation_test lib/calculator.rb lib/parser.rb

# The natural "test what I changed" flow:
bundle exec mutation_test --staged
bundle exec mutation_test $(git diff --cached --name-only)
```

`--staged` reads the list from the git staging area (`git diff --cached
--name-only`), so the two commands above are equivalent when run from the
repository root. Files staged as deleted are ignored. Outside a git repository,
or when nothing is staged, the CLI prints a readable error instead of running.
`--staged` cannot be combined with positional arguments or `--glob`.

When any mutant survives, the aggregate summary ends with a survivors section:
one `file:line original -> mutated` line per surviving mutant. A surviving
mutant is a change to your code that your tests do not detect, so each line is
a concrete test gap to close. With zero survivors the section is absent.

The list may contain anything a real `git diff` produces; unmutable entries are
reported as `SKIPPED` with an explicit reason and never count as a success:

- **file not found** - the path does not exist.
- **not a Ruby source file** - e.g. a staged `.md` or config file.
- **a test file, not a mutable source** - a test file passed directly
  (`*_spec.rb`, `*.spec.rb`, `*_test.rb`, `test_*.rb`, or minitest content).
- **no matching spec file** - the convention (or `--spec-glob`) points at a
  spec that does not exist; the expected path is printed.

Exit codes: `0` when at least one file was processed and every processed file
met the threshold; `1` when any processed file was below threshold or when
every listed file was skipped (nothing was actually mutation-tested); `2` for
usage errors (flag conflicts, `--staged` outside a git repository).

**Legacy pair heuristic:** exactly two arguments where the second is recognized
as a test file (by the name patterns above or by minitest content) keep the
original `SOURCE_FILE TEST_FILE` behavior. Two source files enter list mode. An
RSpec test file with an unconventional name (no `_spec.rb` suffix) is not
recognized, so that pair is treated as a file list; rename the test or use the
conventional layout to get the explicit pair.

### Batch mode: run many files in one command

`--glob PATTERN` mutation-tests every source file the pattern matches in a single
run, so you no longer need to script a loop around `mutation_test` or depend on
the Rails-only `rake mutation:test_models` task.

Each matched source file is mapped to its spec by convention: `lib/X.rb` becomes
`spec/X_spec.rb`. Concretely the spec path is `spec/{name}_spec.rb` where `{name}`
is the source path with a leading `lib/` segment removed and the `.rb` extension
stripped, subdirectories preserved (`lib/foo/bar.rb` -> `spec/foo/bar_spec.rb`).

Override the convention with `--spec-glob TEMPLATE`, a template containing the
`{name}` placeholder. For a Minitest project laid out under `test/`:

```bash
bundle exec mutation_test --glob 'lib/**/*.rb' --spec-glob 'test/{name}_test.rb'
```

Behaviour:

- **Every file is processed.** A file whose score is below the threshold does not
  abort the batch; the run continues to the next file (the `mutation:test_models`
  pattern).
- **Reports never overwrite each other.** Each processed file writes its reporter
  output to its own subdirectory under `--output-dir` (a slug derived from the
  source path), so per-file HTML/JSON reports coexist.
- **A console aggregate summary** is printed at the end: one line per processed
  file with its score and `PASS`/`FAIL` against the threshold, followed by a
  clearly separated `SKIPPED` list.
- **A source file with no matching spec is `SKIPPED`**, reported explicitly and
  never counted as a success. A skipped file does not by itself fail the run.

Exit codes:

- `0` - every processed file met the mutation score threshold (including a
  `--since` run where nothing changed, see below).
- `1` - at least one processed file was below threshold, the glob matched no
  source files at all, or `--fail-fast` stopped the run at a surviving mutant.
- `2` - a usage error: `--spec-glob` with an explicit `SOURCE_FILE TEST_FILE`
  pair, `--since` given without `--glob`, `--staged` combined with positional
  arguments or `--glob`, or `--since`/`--staged` used outside a git repository
  (for `--since` also an unknown revision).

```bash
# Minitest project, JSON report per file, custom output directory
bundle exec mutation_test --glob 'lib/**/*.rb' --spec-glob 'test/{name}_test.rb' \
  --reporters json --output-dir build/mutation
```

### Incremental mode: mutate only what changed

`--since REV` narrows a `--glob` batch to the files that changed since a git
revision, which is how you keep mutation testing affordable on pull requests:

```bash
bundle exec mutation_test --glob 'lib/**/*.rb' --since origin/main
```

Behaviour:

- A matched file counts as **changed** when `git diff --name-only REV` lists it;
  new files the revision does not know about (committed or still untracked) also
  count as changed.
- Unchanged matched files are reported as skipped in the batch summary
  (`SKIPPED (unchanged since REV)`), never mutated.
- When nothing matched by the glob changed since `REV`, the run succeeds with a
  "Nothing to mutate" message and exit code `0`, so a PR that does not touch
  your sources does not fail the gate.
- Outside a git repository (or without a `git` executable), or with a revision
  the repository does not know, the CLI prints a readable error and exits `2`
  before any mutation runs.

### Fail fast: stop at the first surviving mutant

`--fail-fast` turns the run into a cheap gate: the run stops as soon as one
mutant survives, the reports contain the results obtained up to that point with
a clear interruption notice, and the process finishes with exit code `1`. It
works in single-file mode, with `--glob` (the batch stops and remaining files
are not run), and in parallel mode:

```bash
bundle exec mutation_test --glob 'lib/**/*.rb' --since origin/main --fail-fast
```

## Configuration

```ruby
MutationTester.configure do |config|
  # Parallel by default: the process count is derived from the CPU core count
  # (capped at 8, minimum 1). Set an explicit value to override the default,
  # or force serial execution (recommended for Rails apps sharing a database):
  # config.parallel_processes = 1
  config.parallel_processes = 4

  # Per-mutant timeout (seconds). Calibrated automatically by default:
  # max(5, timeout_factor * measured baseline duration), so a loaded machine
  # cannot inflate the score by turning healthy-but-slow runs into timeout
  # kills; on code paths without a measured baseline the fixed default of 30
  # applies. Setting config.timeout explicitly (a number, or nil for no
  # deadline at all) disables calibration and keeps that fixed budget:
  # config.timeout = 30

  # Multiplier for the baseline-calibrated per-mutant timeout (> 0; an
  # invalid value falls back to the default with a warning):
  config.timeout_factor = 5

  # Scoring policy for timed-out mutants. :killed (default) counts a timeout
  # as a kill: (killed + timeout) / (killed + timeout + survived). :separate
  # keeps timeouts out of the score entirely, killed / (killed + survived),
  # and reports them only as their own category, so timeouts under load can
  # never raise the score:
  config.timeout_policy = :killed

  # Mutant execution runner: :auto (default), :fork, :spawn or :in_memory.
  # :auto picks the fastest safe path and announces any fallback on stderr;
  # setting a specific mode forces it. See the Execution model section below.
  config.runner = :auto

  # Two-phase test selection (RSpec only): fast-kill on a matching example
  # subset, always confirmed by the full file before a mutant is reported as
  # survived. Set to false to always run the full file. See Execution model.
  config.test_selection = true

  # Hard deadline for the single baseline run of the whole suite (seconds).
  # Runs every example once, so it is looser than the per-mutant timeout above.
  # Set to nil to disable the baseline deadline.
  config.baseline_timeout = 300

  # Report formats
  config.reporters = [:console, :html, :json]
  # Where reports are written. Defaults to "tmp/mutation_reports".
  # Set it explicitly to write elsewhere (this example uses "mutation_reports"):
  config.output_dir = "mutation_reports"

  # Quality thresholds
  config.minimum_score = 80.0
  config.fail_on_threshold = true

  # Display options
  # Quiet by default. When true, a per-mutation "Warning: skipped ..." line is
  # printed for each skipped mutation. The aggregate "Generated N mutations,
  # skipped M" summary is always printed when mutants are dropped, regardless of
  # this flag. The CLI --verbose flag sets this to true.
  config.verbose = false
  config.show_file_path = true # Show full file path with line number
  config.show_progress = true # Show live progress during mutation testing

  # Enable/disable mutation types
  config.mutation_types = {
    arithmetic: true,
    comparison: true,
    logical: true,
    boolean: true,
    number: true,
    string: true,
    conditional: true,
    call_removal: true,
    nil_injection: true,
    argument: true,
    strict_equality: false # Opt-in: == -> eql?/equal? probes (see Strict Equality Mutations)
  }
end
```

## Execution model

MutationTester runs in parallel by default and picks the fastest safe execution
runner automatically. This section covers when to override those defaults, how
the runners differ, and how two-phase test selection speeds up kills.

### Parallel execution (on by default)

By default, mutation_tester runs in **parallel**: the process count is derived
from the number of CPU cores (`Etc.nprocessors`), capped at 8 and never below 1.
Force a specific count, or serial execution, when your tests need it:

```bash
# Using CLI flag
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb --parallel 4

# Force serial execution (recommended for Rails apps sharing one test database)
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb -p 1

# Using environment variable
MUTATION_TESTER_PARALLEL_PROCESSES=4 bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

Precedence is: an explicit `--parallel/-p` flag overrides `MUTATION_TESTER_PARALLEL_PROCESSES`, which overrides the
auto-derived core count; an explicit `config.parallel_processes` assignment in Ruby also replaces the auto default. An
invalid value (less than 1, or non-numeric) falls back to 1 with a warning on stderr. `-p 1` forces serial execution.

**⚠️ Force serial execution with `-p 1` if your tests share database state!**

In parallel mode each mutant runs in an isolated shadow workspace. Every `.rb`
file is a physical copy (non-Ruby files stay symlinks for speed), so mutations
apply correctly even when a spec loads the source indirectly (e.g. via
`spec_helper`), and `$LOAD_PATH` entries pointing into the project resolve
inside the workspace, so a test file that reaches its source through
`require "test_helper"` gets the mutated copy too. The parallel mutation score
therefore matches serial.

Before the first mutant, the run proves this in the workspace itself: the
unmutated source must pass there, and the same suite must fail once that copy of
the source is replaced by a `raise`. A run whose tests pass even then is aborted
as an infrastructure failure (exit code `3`) rather than reported as a 0.0%
score, because the mutated file is demonstrably not the code being executed.

### When to use serial vs parallel execution

Use **parallel execution** (the default) for:

- ⚡ **Pure Ruby classes** - No database, no shared state
- ⚡ **Unit tests with mocks** - Fast and independent tests
- ⚡ **Large codebases** - Significant time savings
- ⚡ **CI/CD with powerful machines** - Make use of available resources

Force **serial execution with `-p 1`** for:

- ✅ **Rails applications with database** - Avoids conflicts
- ✅ **Tests that share state** - No interference between test runs
- ✅ **First time using mutation testing** - Easier to debug
- ✅ **Limited system resources** - Less memory/CPU usage

### Making parallelism work with Rails

Parallel workers get an isolated filesystem (each mutant runs in its own shadow workspace), but they share one
**database** unless you give each worker its own. If your app is already set up for `parallel_tests` (a `database.yml`
keyed on `TEST_ENV_NUMBER` and per-worker databases created with `rake parallel:prepare`), `--worker-env` bridges the
gem to that setup so you can run parallel instead of serial.

**`--worker-env NAME`** sets the environment variable `NAME` to a distinct value in each worker before it boots its
test environment, following the `parallel_tests` `TEST_ENV_NUMBER` convention:

| Worker | `TEST_ENV_NUMBER` | Database (example) |
|---|---|---|
| 0 | `""` (empty) | `myapp_test` |
| 1 | `"2"` | `myapp_test2` |
| 2 | `"3"` | `myapp_test3` |

You provision the databases; the gem only sets the variable. A single mutant run does not create or migrate anything.

**Worked example** (a `parallel_tests`-ready Rails app):

```bash
# 1. Provision one test database per worker (once, and after schema changes)
RAILS_ENV=test bundle exec rake parallel:prepare

# 2. Run mutation testing in parallel, one database per worker
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb \
  -p 4 --worker-env TEST_ENV_NUMBER

# Batch over a whole directory the same way
bundle exec mutation_test --glob 'app/models/**/*.rb' --spec-glob 'spec/models/{name}_spec.rb' \
  -p 4 --worker-env TEST_ENV_NUMBER
```

`MUTATION_TESTER_WORKER_ENV=TEST_ENV_NUMBER` is equivalent to passing the flag.

**Runner support.** `--worker-env` works with the `fork` and `spawn` runners, where each mutant boots its test
environment freshly and picks up the variable. The `in_memory` runner clones a single preloaded worker that has already
connected to one database, so it cannot isolate a per-worker database; when `--worker-env` is set the runner selection
skips `in_memory` and uses `fork`, announcing the reason on stderr.

**Still simplest without a parallel database setup:** if you have not provisioned per-worker databases, keep Rails
model runs on serial `-p 1`. `--worker-env` is only useful once the databases exist.

**Other strategies** if you are not using `parallel_tests`:

1. **In-Memory SQLite**: For unit tests that don't need advanced DB features, switch to SQLite in memory.
2. **Transactional Cleanup**: Ensure `DatabaseCleaner` or Rails transactional fixtures are working correctly across
   processes (though this is often insufficient for parallel processes).

### Execution runners (fork, spawn, in-memory)

Every mutant is executed by one of three runners, and `auto` (the default) picks
the fastest safe one, announcing every fallback on stderr:

- **in_memory** (default where supported): re-evaluates the mutated source in the
  memory of a fresh fork of a preloaded process, with zero file writes per mutant
  and no shadow workspaces. RSpec and Minitest; the fastest path. Mutations that only
  take effect at class-load time (constants consumed by macros, `validates`/`has_many`/
  `before_save`/`scope`/`attribute`, anything inside an `included do` block) cannot
  be observed by re-evaluating source in a preloaded process, so those mutants are
  routed automatically to the file-based path and the rest still run in memory (see
  below); the combined score matches a full `fork` run.
- **fork**: preloads the environment once (RubyGems, Bundler, the test framework)
  and forks a fresh child per mutant. RSpec and Minitest on platforms with
  `Process.fork`; removes most of the fixed per-mutant boot cost.
- **spawn**: starts one full process per mutant (`bundle exec rspec ...` or
  `bundle exec ruby test_file.rb`). Slower per mutant, but works everywhere
  (the only runner on platforms without `Process.fork`).

`auto` tries `in_memory`, then `fork`, then `spawn`; every step down prints one
stderr warning with its reason, so a fallback is never silent. All runners
produce identical scores and per-mutant statuses and enforce the same hard
per-mutant timeout (monotonic deadline plus a process-group kill).

**Load-time mutants under in-memory (Rails).** The in-memory runner classifies each
mutation by its AST context. A mutation inside a method body defined directly in a
class/module is re-appliable in memory and runs there (fast). A mutation on a
class/module-body statement (a constant, a `validates`/`has_many`/`before_save`/
`scope`/`attribute` macro, or anything inside `included do ... end`) is decided
file-based within the same run, because re-evaluating the source does not re-run
those class-load registrations. This keeps in-memory speed for the common case
while matching a full `fork` score on Rails concerns and models. When at least one
mutant is routed this way, the run prints one stderr notice. It is automatic; you
do not need to pick `--runner fork` for correctness on load-time code.

| Mode        | Picked by `auto` when                                                                                                                                                   | Falls back to                                                                                                                              |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `in_memory` | the platform has `Process.fork`, the file has no load-time `defined?` guard, and re-applying the unmutated source in a probe child passes the suite | `fork`/`spawn` (whole run) with a stderr warning naming the reason; a single worker dying mid-run falls back only for its share of mutants; a mutant that raises while being applied falls back alone |
| `fork`      | `Process.fork` is available, but in-memory is unavailable (each reason is printed)                                                                                      | `spawn`, with a stderr warning, when the helper process fails to preload the environment                                                   |
| `spawn`     | the platform has no `Process.fork`                                                                                                                                      | nothing; it works everywhere                                                                                                               |

Force a specific runner (skipping the auto attempts) with the `--runner
fork|spawn|in_memory` flag, the `MUTATION_TESTER_RUNNER` environment variable, or
`config.runner`:

```bash
mutation_test --runner spawn lib/calculator.rb spec/calculator_spec.rb
```

Reach for `--runner spawn` when you want maximum isolation or are debugging a
suspicious result from a preloaded runner, and `--runner fork` when your source
is not cleanly re-evaluable in memory but you still want the preloaded-environment
speed. For the full per-runner mechanics, when to force each one, and the complete
fork and in-memory limitation lists (frozen classes, load-time `defined?` guards,
worker-death fallback, `require_relative` idempotency), see
[docs/execution-runners.md](docs/execution-runners.md#execution-runners-fork-spawn-in-memory).

### Stopping a mutant at its first failing test

A mutant only needs one failing test to be killed, so every mutant run stops at
its first failure: RSpec mutant runs get `--fail-fast`, and Minitest mutant runs
get a preloaded reporter that aborts the run the same way (both on the file-based
runners and inside the preloaded fork worker). This never changes a verdict, only
the work done to reach it: a run that stops early had already failed, and a run
with no failure is unaffected and still executes every test.

It matters most for a mutant that breaks something every test touches (a broken
class body, a constant every example reads). Such a mutant used to pay the full
test file once per mutant, which on a large test file can exceed the per-mutant
deadline and turn a decided kill into a reported timeout. Adding tests to the file
then made the score worse. The baseline run and the shadow sanity check are
unaffected: they are expected to pass, and a passing run runs every test.

### Test selection (fast kill with full-file confirmation)

For RSpec suites on the file-based runners, MutationTester runs each mutant in
two phases: it first runs only the examples whose group matches the mutated
method (`rspec spec_file -e '#foo' -e '.foo'`) to kill it fast, then confirms a
passing subset against the full spec file before a mutant can be reported as
survived, so selection never introduces false survivors. It degrades to the full
file when the mutant is not inside a method, the spec has no matching group, or
the suite is Minitest; the in-memory runner skips selection entirely (its
examples are already loaded). Disable it with `--no-test-selection` or
`config.test_selection = false`. See
[docs/execution-runners.md](docs/execution-runners.md#test-selection-fast-kill-with-full-file-confirmation)
for the full behavior.

## Mutation types

MutationTester generates several families of mutations, enabled by default:
arithmetic, bitwise compound-assignment, comparison, logical, boolean, number,
string, conditional, call-removal, nil-injection and argument mutations. A
strict-equality family is opt-in. Enable or disable individual families through
`config.mutation_types` (see [Configuration](#configuration)) or turn
strict-equality on with `--strict-equality`.

See [docs/mutation-types.md](docs/mutation-types.md) for the full catalog: every
operator swap and structural mutation each family generates, its reported `type`,
and the constructs each family intentionally leaves alone.

## Equivalent mutants

A mutation score of 100% is not always achievable, and a surviving mutation is
not always a gap in your tests. Some mutations produce code that behaves
**identically** to the original for every possible input, an *equivalent
mutant*, and no test can ever kill it. For example, in a `max` implementation the
original `a > b ? a : b` and the mutant `a >= b ? a : b` differ only when
`a == b`, and both return the same value there, so the mutant survives no matter
how thorough your tests are. Because equivalence is undecidable in the general
case, treat survivors as *candidates* to review rather than guaranteed test gaps;
once you confirm a survivor is equivalent, it is reasonable to accept a score
below 100%.

### Excluding a line with `# mutation_tester:disable`

Once you have confirmed that a survivor is equivalent, annotate its line with a
trailing `# mutation_tester:disable` comment (the same style as
`# rubocop:disable`) so the mutator skips every mutation on that line and the
excluded line drops out of the score and the report:

```ruby
def max(a, b)
  a > b ? a : b # mutation_tester:disable
end
```

The marker is honoured only inside a real comment (never inside a string
literal), and only on the line it sits on. See
[docs/mutation-types.md](docs/mutation-types.md#excluding-a-line-with--mutation_testerdisable)
for the console output and the current limits (no block ranges or per-type
exclusion yet).

## Reports and output

### Console report

Surviving mutants are grouped by file and line (one header per location, all
mutation variants listed under it) and each group shows a unified diff with a
few lines of surrounding context:

```
🧬 MUTATION TESTING REPORT
================================================================================
📊 Summary:
  Total Mutations: 20
  Killed: 18 ✅
  Survived: 2 ❌
  Mutation Score: 90.0%
  Quality: Excellent 🌟

⚠️  Survived Mutations (Need Improvement):
--------------------------------------------------------------------------------

  Location: lib/calculator.rb:12 (2 variants)
    #4 [arithmetic] Change + to -
    #5 [arithmetic] Change + to *

    @@ -10,5 +10,6 @@
        def add(a, b)
    -     a + b
    +     a - b  (#4)
    +     a * b  (#5)
        end
  💡 Suggestion: Add tests to verify behavior for each of the 2 variants above
```

When at least one mutant timed out, the summary also names the deadline those
mutants were measured against and where it came from, so a genuine hang and a
deadline calibrated from a slow test file are distinguishable at a glance:

```
  Timeout: 3 ⏱️
    deadline: 6.50s (5x baseline 1.30s)
```

With an explicit `config.timeout` / `--timeout` the same line reads
`deadline: 30.00s (explicitly configured)`.

### HTML report

Beautiful interactive HTML report with:

- Summary statistics
- Mutation score visualization
- Filterable mutation list
- Survivors grouped by file and line, with all mutation variants under one card
- Unified diffs with surrounding context for survived and timeout mutants
- Detailed suggestions for improvements

### JSON report and machine-readable output

Machine-readable report for CI/CD integration and AI agents. Run with `--json`
to get a single, clean JSON document on **stdout** and nothing else: the banner,
progress spinner, colours and the "report saved" notice all go to **stderr**, so
the stream is safe to pipe straight into `jq` or a parser. The process still
exits `0` when the mutation score meets the configured threshold and `1` when it
does not (a degraded single-file run exits `3`, see
[Exit codes](#exit-codes-single-file-mode)), so the exit code remains a
pass/fail signal.

```bash
bundle exec mutation_test --json examples/calculator.rb examples/calculator_spec.rb | jq .

# A single listed file works too; its spec is mapped by convention
bundle exec mutation_test --json lib/calculator.rb | jq .
```

The same report is also written to `tmp/mutation_reports/mutation_report.json`
(see `--output-dir`). A run that resolves exactly one source file, or an explicit
`SOURCE_FILE TEST_FILE` pair, prints the plain per-file report; a multi-file run
(a `FILE` list with more than one file, `--staged`, or `--glob`) prints one
aggregate envelope with a condensed `survivors` array.

Every **surviving** mutant carries `file_path`, `line`, `original` and `mutated`,
which is a concrete, located test gap: the worklist you can hand to an AI agent
or a CI gate (see [CI/CD integration](#cicd-integration)).

Full field-by-field documentation of both shapes (the single-file report and the
multi-file envelope), the `schema_version` policy, and ready-to-use `jq` recipes
live in [docs/json-schema.md](docs/json-schema.md).

## Pre-push hook

Gate your pushes locally: run mutation testing on the file(s) you touched and
block the push when the score is under your bar, the fast-feedback sibling of
the CI gate below (see [CI/CD integration](#cicd-integration)).

The gem ships a ready-to-copy hook at
[`examples/hooks/pre-push`](examples/hooks/pre-push) (installed with the gem, so
you have it offline). It runs `mutation_test --json`, reads the score with
[`jq`](https://jqlang.github.io/jq/), and on a below-threshold run lists the
surviving mutants (file, line, what changed) so you see which gaps to close.
Install it with:

```bash
cp examples/hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

Then edit the `THRESHOLD` and the `SOURCE TEST` pair(s) at the top of the copied
hook.

Prefer to gate on your project's configured threshold rather than one written
into the hook? `mutation_test` already exits non-zero when the score is below
`config.minimum_score` (default 80, see [Configuration](#configuration)), so you
can drop the `jq` comparison and let the exit code be the gate:

```sh
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb || exit 1
```

lefthook or overcommit users: call the shipped hook from your `pre-push` step
instead of writing to `.git/hooks/`.

## CI/CD integration

Run MutationTester as a CI quality gate: the CLI exits non-zero when the mutation
score is below the threshold, so it fails the job with no extra configuration.

The gem ships ready-to-copy GitHub Actions workflows (installed alongside the
gem, so you have them offline too):

- [`examples/github_actions/mutation_test.yml`](examples/github_actions/mutation_test.yml)
  is the maintained template. Add the gem to your bundle, copy it to
  `.github/workflows/`, edit the `EDIT:` lines, and it runs the gate, uploads the
  HTML/JSON reports from `tmp/mutation_reports/` as an artifact (even on
  failure), and fails the job below threshold. It also carries commented variants
  for parallel execution, several file pairs, and an incremental pull-request gate.
- [`examples/github_actions/ai_mutation_gate.yml`](examples/github_actions/ai_mutation_gate.yml)
  is the AI gate: the same pass/fail gate, plus it writes the surviving-mutant
  worklist to the GitHub job summary and uploads `survivors.json` for an agent to
  turn into missing tests.

See [docs/ci.md](docs/ci.md) for the full recipes: a 5-minute setup, minimal
inline and pull-request workflows, machine mode as a gate and artifact, and the
AI workflow.

## Troubleshooting

### Tests Pass Normally but Fail During Mutation Testing

This usually means:

- Your tests depend on execution order
- Your tests share state between runs
- Database transactions aren't being properly cleaned up

**Solution**: Ensure each test is independent and can run in isolation.

### Database Conflicts in Parallel Mode

If you see errors like "database is locked" or "record not found":

**Solution**: Use serial execution (the default):

```bash
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

Or if using environment variable, make sure it's not set or set to 1:

```bash
MUTATION_TESTER_PARALLEL_PROCESSES=1 bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

### Slow Execution

Mutation testing generates many mutations and runs your tests repeatedly, so it's naturally slower than a regular test
run.

**Tips for faster execution**:

- Test only critical files (don't test everything)
- Use parallel execution if your tests support it (`--parallel N`)
- Consider using faster test databases (SQLite in-memory for unit tests)
- Focus on high-value code (models, services, core logic)

### "No Mutations Generated"

If you see "Generated 0 mutations", this usually means:

- The file only contains method signatures or delegations
- The file has no logic to mutate (e.g., only `belongs_to` associations)
- The file might be empty or only contain constants

**Solution**: Choose files with actual logic to test (calculations, conditionals, validations, etc.)

### Debugger Statement Hit

If mutation testing stops at a `debugger` or `binding.pry` statement:

- This is expected in development mode
- The mutation is testing code that hits a debugger

**Solution**: Continue (`c`), quit (`q`), or remove debuggers from your code before running mutation tests

### Parser Version Warning on Newer Ruby (Supported Syntax Level)

MutationTester parses your source with the `parser` gem. The newest published
`parser` line recognizes **Ruby 3.3 syntax**; there is not yet a release that
understands Ruby 3.4+/4.x syntax. So when you run on Ruby 3.4 or newer you may
see one line on stderr per run:

```
warning: parser/current is loading parser/ruby33, which recognizes 3.3.x-compliant syntax, but you are running 4.0.2.
```

This warning is **benign**. It only means the parser recognizes syntax up to
Ruby 3.3. The gem itself runs fine on Ruby 3.4+/4.x, and files written in Ruby
3.3-and-earlier syntax are mutated normally.

The only real limitation is a source file that relies on syntax introduced
after Ruby 3.3. Such a file cannot be parsed, so it reports an explicit
`Failed to parse source file` and the run fails - it never fakes a passing
score. The warning is left in place on purpose as an honest signal; it is not
globally silenced.

## Development

Run `bundle install`, then run `rake spec` to run the tests.

The gem includes working examples for both RSpec and Minitest under the
`examples/` directory (a sample `Calculator` class with an RSpec spec and a
Minitest test). Run them directly with the CLI, or through the example rake tasks:

```bash
# Directly with the CLI
bundle exec mutation_test examples/calculator.rb examples/calculator_spec.rb
bundle exec mutation_test examples/calculator.rb examples/calculator_minitest.rb

# RSpec examples
rake example:rspec              # Serial execution
rake example:rspec_parallel     # Parallel execution

# Minitest examples
rake example:minitest           # Serial execution
rake example:minitest_parallel  # Parallel execution

# Default example (RSpec)
rake example
```

Each example will:

- Run mutation tests on a sample Calculator class
- Generate console, HTML, and JSON reports
- Show mutation score and quality metrics
- Demonstrate the difference between serial and parallel execution

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Oxyconit/mutation_tester.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
