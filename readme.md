# MutationTester 🧬

[![CI](https://github.com/Oxyconit/mutation_tester/actions/workflows/ci.yml/badge.svg)](https://github.com/Oxyconit/mutation_tester/actions/workflows/ci.yml)

Simple mutation testing framework for Ruby applications with RSpec or Minitest. It mutates your code, runs your tests
against each mutant, and reports every change your tests failed to detect, so you (or your AI agent) know exactly which
test gaps to close.

## Quick Start

```bash
# Install
bundle add mutation_tester

# Test a file: its spec is found by convention (lib/X.rb -> spec/X_spec.rb)
bundle exec mutation_test lib/calculator.rb

# Test several files in one aggregated run
bundle exec mutation_test lib/calculator.rb lib/parser.rb

# Test exactly what you have staged in git (the "test what I changed" flow)
bundle exec mutation_test --staged

# Minitest layout under test/
bundle exec mutation_test --spec-glob 'test/{name}_test.rb' lib/calculator.rb

# Or point at the test file explicitly
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

The gem will:

- ✅ Run your original tests to make sure they pass
- ✅ Generate mutations of your code
- ✅ Run tests against each mutation
- ✅ Generate reports showing which mutations survived

Press Ctrl+C at any time to stop early: the run cleans up its worker processes and temporary workspaces, prints a single
interruption line (no backtrace), and exits with status 130.

## Table of Contents

- [Features](#features)
- [Requirements and Compatibility](#requirements-and-compatibility)
- [Installation](#installation)
- [Usage](#usage)
  - [Choosing what to test](#choosing-what-to-test)
  - [Mapping sources to specs](#mapping-sources-to-specs)
  - [CLI options](#cli-options)
  - [Exit codes](#exit-codes)
  - [Running with rake](#running-with-rake)
  - [Programmatic usage](#programmatic-usage)
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
[mutation catalog](docs/mutation-types.md), the [execution runner internals](docs/execution-runners.md),
the [JSON report schema](docs/json-schema.md), and the [CI/CD recipes](docs/ci.md).

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

### In your project's bundle (recommended)

Add it to your application's `Gemfile` and install in one step:

```bash
bundle add mutation_tester
```

Then run it through Bundler so it uses your project's locked dependency versions:

```bash
bundle exec mutation_test lib/calculator.rb
```

### As a global gem

Install it once, system-wide, and run `mutation_test` directly (no `bundle exec`):

```bash
gem install mutation_tester
mutation_test lib/calculator.rb
```

This is convenient for a project that does not list the gem in its `Gemfile`. The CLI then cannot load itself from that
project bundle, so it loads the globally installed gem *outside* the bundle and prints one line to stderr:

```
mutation_tester loaded outside the project bundle
```

In this fallback the gem and its own dependencies (parser, unparser, parallel, rainbow) come from the global install, so
their versions may differ from your project's `Gemfile.lock`. Your own tests are unaffected: when your project has a
`Gemfile`, each mutant still runs through `bundle exec`, in your project's environment. Running in a directory with no
`Gemfile` at all works too and prints no notice. If your project *does* list `mutation_tester`, prefer
`bundle exec mutation_test ...`, which runs fully inside your bundle with no notice.

## Usage

```bash
# One or more source files, specs mapped by convention (the main interface)
mutation_test [OPTIONS] FILE...

# The files currently staged in git
mutation_test [OPTIONS] --staged

# Explicit pair: exactly two arguments where the second is a test file
mutation_test [OPTIONS] SOURCE_FILE TEST_FILE

# Many files in one run: select sources with a glob
mutation_test [OPTIONS] --glob 'lib/**/*.rb'
```

### Choosing what to test

**File list (`FILE...`)** is the main interface. Each source file is mapped to its spec by convention (`lib/X.rb` ->
`spec/X_spec.rb`; see [Mapping sources to specs](#mapping-sources-to-specs) to override), and the whole list runs as one
aggregated batch: every file is processed, the summary shows one `PASS`/`FAIL` line per file, reports land in per-file
subdirectories under `--output-dir`, and the exit code reflects the whole run.

**`--staged`** reads the file list from the git staging area (`git diff --cached --name-only`), so it is the natural
"test what I changed" flow:

```bash
bundle exec mutation_test --staged
# equivalent, from the repository root:
bundle exec mutation_test $(git diff --cached --name-only)
```

Files staged as deleted are ignored. Outside a git repository, or when nothing is staged, the CLI prints a readable
error instead of running. `--staged` cannot be combined with positional arguments or `--glob`.

**Explicit pair (`SOURCE_FILE TEST_FILE`)**: with exactly two arguments where the second is recognized as a test file
(`*_spec.rb`, `*.spec.rb`, `*_test.rb`, `test_*.rb`, or a file requiring minitest), the second is used as the test file
directly. Two source files enter list mode instead. An RSpec test file with an unconventional name (no `_spec.rb`
suffix) is not recognized, so that pair is treated as a file list; rename the test or use the conventional layout to get
the explicit pair.

**`--glob PATTERN`** mutation-tests every source file the pattern matches in a single run, so you do not need to script
a loop around `mutation_test`:

```bash
# Minitest project, JSON report per file, custom output directory
bundle exec mutation_test --glob 'lib/**/*.rb' --spec-glob 'test/{name}_test.rb' \
  --reporters json --output-dir build/mutation
```

**`--since REV`** narrows a `--glob` batch to the files that changed since a git revision, which is how you keep
mutation testing affordable on pull requests:

```bash
bundle exec mutation_test --glob 'lib/**/*.rb' --since origin/main
```

A matched file counts as changed when `git diff --name-only REV` lists it; new files the revision does not know about
(committed or still untracked) also count as changed. Unchanged matched files are reported as
`SKIPPED (unchanged since REV)` and never mutated. When nothing changed, the run succeeds with a "Nothing to mutate"
message and exit code `0`, so a PR that does not touch your sources does not fail the gate.

**`--fail-fast`** turns the run into a cheap gate: the run stops as soon as one mutant survives, the reports contain the
results obtained up to that point with a clear interruption notice, and the process finishes with exit code `1`. It
works in single-file mode, with `--glob` (the batch stops and remaining files are not run), and in parallel mode.

#### Batch behaviour and skipped files

All multi-file modes (`FILE...` lists, `--staged`, `--glob`) behave the same way:

- **Every file is processed.** A file whose score is below the threshold does not abort the batch (unless
  `--fail-fast`); the run continues to the next file.
- **Reports never overwrite each other.** Each processed file writes its reporter output to its own subdirectory under
  `--output-dir` (a slug derived from the source path).
- **A console aggregate summary** is printed at the end: one line per processed file with its score and `PASS`/`FAIL`,
  followed by a clearly separated `SKIPPED` list. When any mutant survives, the summary ends with a survivors section:
  one `file:line original -> mutated` line per surviving mutant, each a concrete test gap to close.
- **Unmutable entries are `SKIPPED` with an explicit reason** and never count as a success:
  - **file not found** - the path does not exist.
  - **not a Ruby source file** - e.g. a staged `.md` or config file.
  - **a test file, not a mutable source** - a test file passed directly.
  - **no matching spec file** - the convention (or `--spec-glob` / `--spec-map`) points at a spec that does not exist;
    the expected path is printed.
- **A run that skipped every file fails** (exit code `1`): a typo in `--spec-glob`/`--spec-map`, or a refactor that
  moves the test directory, would otherwise leave a green CI step that measured nothing.

### Mapping sources to specs

Every mode except the explicit `SOURCE_FILE TEST_FILE` pair derives the test path from the source path. Two mechanisms
do that, checked in this order:

1. `--spec-map 'PATTERN=>REPLACEMENT'` - regular-expression rules.
2. `--spec-glob TEMPLATE` - a `{name}` template (default `spec/{name}_spec.rb`).

**`--spec-glob TEMPLATE`** substitutes `{name}`, which is the source path with a leading `lib/` segment removed and the
`.rb` extension stripped, subdirectories preserved (`lib/foo/bar.rb` -> `spec/foo/bar_spec.rb`). Because `{name}` is one
value, a template can only add a prefix and a suffix around the source path. For a Minitest project laid out under
`test/` that is enough:

```bash
bundle exec mutation_test --glob 'lib/**/*.rb' --spec-glob 'test/{name}_test.rb'
```

**`--spec-map 'PATTERN=>REPLACEMENT'`** covers the layouts a template cannot express: those that substitute *inside*
the path, after a variable-length prefix. `PATTERN` is a Ruby regular expression matched against the whole source path
(a leading `./` removed); the first `=>` separates it from `REPLACEMENT`, which may use `\1`, `\2`, ... backreferences
and produces the whole spec path. Only the first match in the path is replaced.

- The flag is repeatable and the first matching rule wins.
- A source that matches no rule falls back to `--spec-glob` (or the default convention), so one command can cover
  `app/` and `lib/` at once.
- Quote the rule in single quotes so the shell leaves the backslashes alone.

Rails and Rails-shaped layouts, where the rule is "replace the `app/` segment with `test/`, keep whatever prefix comes
before it":

```bash
# Plain Rails, Minitest: app/models/current.rb -> test/models/current_test.rb
bundle exec mutation_test --glob 'app/**/*.rb' \
  --spec-map '\Aapp/(.+)\.rb\z=>test/\1_test.rb'

# Plain Rails, RSpec: app/models/user.rb -> spec/models/user_spec.rb
bundle exec mutation_test --glob 'app/**/*.rb' \
  --spec-map '\Aapp/(.+)\.rb\z=>spec/\1_spec.rb'

# Packwerk / packs-rails and engines, with the app root as an optional prefix:
#   app/models/current.rb                -> test/models/current_test.rb
#   packs/identity/app/models/party.rb   -> packs/identity/test/models/party_test.rb
#   engines/billing/app/jobs/send_job.rb -> engines/billing/test/jobs/send_job_test.rb
bundle exec mutation_test --glob '{app,packs/*/app,engines/*/app}/**/*.rb' \
  --spec-map '\A((?:(?:packs|engines)/[^/]+/)?)app/(.+)\.rb\z=>\1test/\2_test.rb'

# app/ through the rule, lib/ through the template, in one run
bundle exec mutation_test --glob '{app,lib}/**/*.rb' \
  --spec-map '\Aapp/(.+)\.rb\z=>test/\1_test.rb' \
  --spec-glob 'test/{name}_test.rb'
```

When a rule produces a path that does not exist, the file is reported as `SKIPPED (no matching spec file)` with the
expected path printed.

### CLI options

| Flag | Description |
|---|---|
| `-p, --parallel N` | Run with N parallel processes (default: auto from CPU cores, capped at 8; `-p 1` forces serial). See [Parallel execution](#parallel-execution-on-by-default). |
| `--runner MODE` | Mutant execution runner: `auto` (default), `in_memory`, `fork`, or `spawn`. See [Execution runners](#execution-runners-fork-spawn-in-memory). |
| `--staged` | Mutation-test the files staged in git. See [Choosing what to test](#choosing-what-to-test). |
| `--glob PATTERN` | Mutation-test every source file matching `PATTERN`. See [Choosing what to test](#choosing-what-to-test). |
| `--since REV` | With `--glob`: mutate only the files that changed since git revision `REV`. See [Choosing what to test](#choosing-what-to-test). |
| `--spec-glob TEMPLATE` | Spec-mapping template with a `{name}` placeholder (default: `spec/{name}_spec.rb`). See [Mapping sources to specs](#mapping-sources-to-specs). |
| `--spec-map RULE` | Spec-mapping regex rule `'PATTERN=>REPLACEMENT'`; repeatable, first match wins. See [Mapping sources to specs](#mapping-sources-to-specs). |
| `--minimum-score N` | Mutation score percentage a file must reach to pass (default: 80). Drives the `PASS`/`FAIL` verdict and the exit code. |
| `--fail-fast` | Stop the run at the first surviving mutant and finish with a failing status. |
| `--timeout-factor N` | Per-mutant timeout budget as `N` times the measured baseline test run, never below 5 s (default: 5, must be > 0). Ignored when `config.timeout` is set explicitly. |
| `--timeout-policy MODE` | Scoring policy for timed-out mutants: `killed` (default) counts a timeout as a kill; `separate` keeps timeouts out of the score and reports them as their own category. |
| `--worker-env NAME` | Per-worker database isolation via the `parallel_tests` `TEST_ENV_NUMBER` convention. See [Making parallelism work with Rails](#making-parallelism-work-with-rails). |
| `--after-fork FILE` | Ruby file loaded inside each in-memory clone right after it forks, to re-establish per-worker state. See [Making parallelism work with Rails](#making-parallelism-work-with-rails). |
| `--strict-equality` | Enable the opt-in strict-equality probes (`==` to `eql?`/`equal?`). Default off; expect noise on code that does not distinguish numeric types or object identity. See [Strict Equality Mutations](docs/mutation-types.md#strict-equality-mutations-opt-in). |
| `--no-test-selection` | Disable two-phase test selection and always run the full test file for every mutant. See [Test selection](#test-selection-fast-kill-with-full-file-confirmation). |
| `--json` | Machine mode: print ONLY the JSON report to stdout (everything else goes to stderr). See [JSON report](#json-report-and-machine-readable-output). |
| `--reporters LIST` | Comma-separated reporters to run: `console`, `html`, `json` (default: all three). An unknown name errors and exits 1. |
| `--output-dir PATH` | Directory for the generated report files (default: `tmp/mutation_reports`). In batch mode each file writes to its own subdirectory. |
| `--verbose` | Show a per-mutation warning for every skipped mutation (quiet by default; the "Generated N mutations, skipped M" summary always prints when mutants are dropped). |
| `--no-progress` | Disable the live progress line (percentage, processed count, elapsed time, estimated remaining time, survived and timed out tallies, and an errored tally once a mutant errors). |
| `-h, --help` | Show help message. |
| `-v, --version` | Show version. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | The run passed: every processed file met the threshold (or `fail_on_threshold` is disabled). A `--since` run where nothing changed also exits `0`. |
| `1` | Below threshold, unusable input (missing file, unknown reporter, source with a syntax error), a glob that matched nothing, a batch where every file was skipped, or a `--fail-fast` stop. |
| `2` | A usage error: conflicting flags (`--spec-glob`/`--spec-map` with an explicit pair, `--staged` with positional arguments or `--glob`, `--since` without `--glob`), a malformed `--spec-map` rule, or `--since`/`--staged` outside a git repository (for `--since` also an unknown revision). |
| `3` | Single-file mode only: the run aborted or degraded before reaching a verdict. The shadow workspace was unreliable (the unmutated source failed there, or the workspace copy of the source turned out not to be the code the tests execute), or every mutant ended as `error`/`stillborn` so nothing was scored. This signals an infrastructure or runner problem, not a test-quality gap, so CI hooks can distinguish it from a genuine threshold failure. In batch modes a degraded file is named explicitly in the batch summary instead. |
| `130` | Interrupted with Ctrl+C. |

### Running with rake

In a **non-Rails** project, require the tasks from your `Rakefile`:

```ruby
# Rakefile
require 'mutation_tester/rake_task'
```

In a **Rails** app the tasks load automatically through the gem's railtie, so no Rakefile change is needed.

Then run either task. Rake takes the file arguments inside brackets (not space-separated), so quote the invocation for
your shell:

```bash
# Top-level task
bundle exec rake "mutation_test[app/models/user.rb,spec/models/user_spec.rb]"

# Namespaced task
bundle exec rake "mutation:test[app/models/user.rb,spec/models/user_spec.rb]"
```

### Programmatic usage

Run the gem directly from Ruby with `MutationTester.run(source, test)`:

```ruby
# RSpec
MutationTester.run('examples/calculator.rb', 'examples/calculator_spec.rb')

# Minitest
MutationTester.run('examples/calculator.rb', 'examples/calculator_minitest.rb')
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

  # Per-worker database isolation (parallel_tests TEST_ENV_NUMBER convention).
  # Set to an environment variable name to give each parallel worker a distinct
  # value before it boots its test environment. Equivalent to the --worker-env
  # CLI flag. See Making parallelism work with Rails below.
  # config.worker_env_var = "TEST_ENV_NUMBER"

  # Ruby file loaded inside each preloaded in-memory clone right after it forks
  # and receives its per-worker environment, so the app can re-establish
  # per-worker state such as its database connection. Keeps the in_memory
  # runner available in parallel worker-env runs. Equivalent to the
  # --after-fork CLI flag.
  # config.after_fork_file = "db/mutation_after_fork.rb"

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

  # Quality thresholds. The CLI flag --minimum-score overrides this per run.
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

MutationTester runs in parallel by default and picks the fastest safe execution runner automatically. This section
covers when to override those defaults, how the runners differ, and how the gem speeds up kills.

### Parallel execution (on by default)

By default the process count is derived from the number of CPU cores (`Etc.nprocessors`), capped at 8 and never below 1.
Force a specific count, or serial execution, when your tests need it:

```bash
# Using CLI flag
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb --parallel 4

# Force serial execution (recommended for Rails apps sharing one test database)
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb -p 1

# Using environment variable
MUTATION_TESTER_PARALLEL_PROCESSES=4 bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb
```

Precedence: an explicit `--parallel/-p` flag overrides `MUTATION_TESTER_PARALLEL_PROCESSES`, which overrides the
auto-derived core count; an explicit `config.parallel_processes` assignment in Ruby also replaces the auto default. An
invalid value (less than 1, or non-numeric) falls back to 1 with a warning on stderr.

**When to force serial execution with `-p 1`**: Rails apps whose tests share one test database, tests that share any
other state, the first time you try mutation testing (easier to debug), or machines with limited memory/CPU. Pure Ruby
classes, unit tests with mocks, and CI machines with many cores all benefit from the parallel default. To keep
parallelism on a Rails app instead of dropping to serial, see
[Making parallelism work with Rails](#making-parallelism-work-with-rails).

In parallel mode each mutant runs in an isolated shadow workspace. Every `.rb` file is a physical copy (non-Ruby files
stay symlinks for speed), so mutations apply correctly even when a spec loads the source indirectly (e.g. via
`spec_helper`), and `$LOAD_PATH` entries pointing into the project resolve inside the workspace, so a test file that
reaches its source through `require "test_helper"` gets the mutated copy too. The parallel mutation score therefore
matches serial.

Before the first mutant, the run proves this in the workspace itself: the unmutated source must pass there, and the
same suite must fail once that copy of the source is replaced by a `raise`. A run whose tests pass even then is aborted
as an infrastructure failure (exit code `3`) rather than reported as a 0.0% score, because the mutated file is
demonstrably not the code being executed.

### Making parallelism work with Rails

Parallel workers get an isolated filesystem, but they share one **database** unless you give each worker its own. If
your app is already set up for `parallel_tests` (a `database.yml` keyed on `TEST_ENV_NUMBER` and per-worker databases
created with `rake parallel:prepare`), `--worker-env` bridges the gem to that setup so you can run parallel instead of
serial.

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
bundle exec mutation_test --glob 'app/models/**/*.rb' \
  --spec-map '\Aapp/(.+)\.rb\z=>spec/\1_spec.rb' \
  -p 4 --worker-env TEST_ENV_NUMBER
```

`MUTATION_TESTER_WORKER_ENV=TEST_ENV_NUMBER` is equivalent to passing the flag.

**Runner support.** `--worker-env` works with the `fork` and `spawn` runners out of the box, because each mutant boots
its test environment freshly and picks up the variable. The `in_memory` runner clones a single preloaded worker that
has already connected to one database, so setting the variable alone cannot re-point an existing connection; in a
parallel run without `--after-fork` the runner selection therefore skips `in_memory` and uses `fork`, announcing the
reason on stderr. A serial run (`-p 1`) has only one worker and stays in memory.

**Keeping the in-memory runner with `--after-fork`.** Pass `--after-fork FILE` (or
`MUTATION_TESTER_AFTER_FORK=FILE`) to keep the `in_memory` runner in parallel worker-env runs. Each preloaded clone
then receives its per-worker value of the `--worker-env` variable and loads `FILE` right after forking, and that file
is where your app re-establishes its per-worker state. For a Rails app with a `TEST_ENV_NUMBER`-keyed `database.yml`
that usually means reconnecting ActiveRecord:

```ruby
# db/mutation_after_fork.rb
ActiveRecord::Base.establish_connection(
  ActiveRecord::Base.configurations
    .configs_for(env_name: 'test', name: 'primary')
    .configuration_hash
    .merge(database: "myapp_test#{ENV['TEST_ENV_NUMBER']}")
)
```

```bash
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb \
  -p 4 --worker-env TEST_ENV_NUMBER --after-fork db/mutation_after_fork.rb
```

The file runs once per clone, inside the clone only (never in the primary preloaded worker or in your shell process).
If it raises, the clone reports the error on stderr and is dropped, and its worker decides its share of mutants through
the file-based path; if the file does not exist, the whole run falls back to file-based execution with a warning.

**Serial runs never mutate your checkout.** With `--worker-env` set, a `-p 1` run on the file-based runners decides
each mutant in a shadow workspace instead of writing mutants into the real source file, so a killed process cannot
leave a mutated file behind. (Without `--worker-env`, a serial file-based run still uses in-place mutation with a
`.mutation_backup` file that the next run restores automatically.)

**Still simplest without a parallel database setup:** if you have not provisioned per-worker databases, keep Rails
model runs on serial `-p 1`. `--worker-env` is only useful once the databases exist.

**Other strategies** if you are not using `parallel_tests`:

1. **In-Memory SQLite**: For unit tests that don't need advanced DB features, switch to SQLite in memory.
2. **Transactional Cleanup**: Ensure `DatabaseCleaner` or Rails transactional fixtures are working correctly across
   processes (though this is often insufficient for parallel processes).

### Execution runners (fork, spawn, in-memory)

Every mutant is executed by one of three runners, and `auto` (the default) picks the fastest safe one, announcing every
fallback on stderr:

- **in_memory** (default where supported): re-evaluates the mutated source in the memory of a fresh fork of a preloaded
  process, with zero file writes per mutant and no shadow workspaces. RSpec and Minitest; the fastest path.
- **fork**: preloads the environment once (RubyGems, Bundler, the test framework) and forks a fresh child per mutant.
  RSpec and Minitest on platforms with `Process.fork`; removes most of the fixed per-mutant boot cost.
- **spawn**: starts one full process per mutant (`bundle exec rspec ...` or `bundle exec ruby test_file.rb`). Slower
  per mutant, but works everywhere (the only runner on platforms without `Process.fork`).

| Mode        | Picked by `auto` when                                                                                                                                                   | Falls back to                                                                                                                              |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `in_memory` | the platform has `Process.fork`, the file has no load-time `defined?` guard, and re-applying the unmutated source in a probe child passes the suite | `fork`/`spawn` (whole run) with a stderr warning naming the reason; a single worker dying mid-run falls back only for its share of mutants; a mutant that raises while being applied falls back alone |
| `fork`      | `Process.fork` is available, but in-memory is unavailable (each reason is printed)                                                                                      | `spawn`, with a stderr warning, when the helper process fails to preload the environment                                                   |
| `spawn`     | the platform has no `Process.fork`                                                                                                                                      | nothing; it works everywhere                                                                                                               |

All runners produce identical scores and per-mutant statuses and enforce the same hard per-mutant timeout (monotonic
deadline plus a process-group kill).

**Load-time mutants under in-memory (Rails).** The in-memory runner classifies each mutation by its AST context. A
mutation inside a method body defined directly in a class/module is re-appliable in memory and runs there (fast). A
mutation on a class/module-body statement (a constant, a `validates`/`has_many`/`before_save`/`scope`/`attribute`
macro, or anything inside `included do ... end`) cannot be observed by re-evaluating source in a preloaded process, so
it is decided file-based within the same run. This keeps in-memory speed for the common case while matching a full
`fork` score on Rails concerns and models. When at least one mutant is routed this way, the run prints one stderr
notice. It is automatic; you do not need to pick `--runner fork` for correctness on load-time code.

Force a specific runner (skipping the auto attempts) with the `--runner fork|spawn|in_memory` flag, the
`MUTATION_TESTER_RUNNER` environment variable, or `config.runner`:

```bash
mutation_test --runner spawn lib/calculator.rb spec/calculator_spec.rb
```

Reach for `--runner spawn` when you want maximum isolation or are debugging a suspicious result from a preloaded
runner, and `--runner fork` when your source is not cleanly re-evaluable in memory but you still want the
preloaded-environment speed. For the full per-runner mechanics and the complete fork and in-memory limitation lists
(frozen classes, load-time `defined?` guards, worker-death fallback, `require_relative` idempotency), see
[docs/execution-runners.md](docs/execution-runners.md#execution-runners-fork-spawn-in-memory).

### Stopping a mutant at its first failing test

A mutant only needs one failing test to be killed, so every mutant run stops at its first failure: RSpec mutant runs
get `--fail-fast`, and Minitest mutant runs get a preloaded reporter that aborts the run the same way (both on the
file-based runners and inside the preloaded fork worker). This never changes a verdict, only the work done to reach it:
a run that stops early had already failed, and a run with no failure is unaffected and still executes every test.

It matters most for a mutant that breaks something every test touches (a broken class body, a constant every example
reads). Such a mutant used to pay the full test file once per mutant, which on a large test file can exceed the
per-mutant deadline and turn a decided kill into a reported timeout. The baseline run and the shadow sanity check are
unaffected: they are expected to pass, and a passing run runs every test.

### Test selection (fast kill with full-file confirmation)

For RSpec suites on the file-based runners, MutationTester runs each mutant in two phases: it first runs only the
examples whose group matches the mutated method (`rspec spec_file -e '#foo' -e '.foo'`) to kill it fast, then confirms
a passing subset against the full spec file before a mutant can be reported as survived, so selection never introduces
false survivors. It degrades to the full file when the mutant is not inside a method, the spec has no matching group,
or the suite is Minitest; the in-memory runner skips selection entirely (its examples are already loaded). Disable it
with `--no-test-selection` or `config.test_selection = false`. See
[docs/execution-runners.md](docs/execution-runners.md#test-selection-fast-kill-with-full-file-confirmation) for the
full behavior.

## Mutation types

MutationTester generates several families of mutations, enabled by default: arithmetic, bitwise compound-assignment,
comparison, logical, boolean, number, string, conditional, call-removal, nil-injection and argument mutations. A
strict-equality family is opt-in. Enable or disable individual families through `config.mutation_types`
(see [Configuration](#configuration)) or turn strict-equality on with `--strict-equality`.

See [docs/mutation-types.md](docs/mutation-types.md) for the full catalog: every operator swap and structural mutation
each family generates, its reported `type`, and the constructs each family intentionally leaves alone.

## Equivalent mutants

A mutation score of 100% is not always achievable, and a surviving mutation is not always a gap in your tests. Some
mutations produce code that behaves **identically** to the original for every possible input, an *equivalent mutant*,
and no test can ever kill it. For example, in a `max` implementation the original `a > b ? a : b` and the mutant
`a >= b ? a : b` differ only when `a == b`, and both return the same value there, so the mutant survives no matter how
thorough your tests are. Because equivalence is undecidable in the general case, treat survivors as *candidates* to
review rather than guaranteed test gaps; once you confirm a survivor is equivalent, it is reasonable to accept a score
below 100%.

### Excluding a line with `# mutation_tester:disable`

Once you have confirmed that a survivor is equivalent, annotate its line with a trailing `# mutation_tester:disable`
comment (the same style as `# rubocop:disable`) so the mutator skips every mutation on that line and the excluded line
drops out of the score and the report:

```ruby
def max(a, b)
  a > b ? a : b # mutation_tester:disable
end
```

The marker is honoured only inside a real comment (never inside a string literal), and only on the line it sits on. See
[docs/mutation-types.md](docs/mutation-types.md#excluding-a-line-with--mutation_testerdisable) for the console output
and the current limits (no block ranges or per-type exclusion yet).

## Reports and output

Three reporters are available (`console`, `html`, `json`; all on by default). Choose which run with `--reporters` and
where their files land with `--output-dir`:

```bash
bundle exec mutation_test --reporters json,html --output-dir build/mutation \
  app/models/user.rb spec/models/user_spec.rb
```

### Console report

Surviving mutants are grouped by file and line (one header per location, all mutation variants listed under it) and
each group shows a unified diff with a few lines of surrounding context:

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

When at least one mutant timed out, the summary also names the deadline those mutants were measured against and where
it came from, so a genuine hang and a deadline calibrated from a slow test file are distinguishable at a glance:

```
  Timeout: 3 ⏱️
    deadline: 6.50s (5x baseline 1.30s)
```

With an explicit `config.timeout` / `--timeout` the same line reads `deadline: 30.00s (explicitly configured)`.

### HTML report

Interactive HTML report with summary statistics, mutation score visualization, a filterable mutation list, survivors
grouped by file and line (all mutation variants under one card), unified diffs with surrounding context for survived
and timeout mutants, and detailed suggestions for improvements.

### JSON report and machine-readable output

Machine-readable report for CI/CD integration and AI agents. Run with `--json` to get a single, clean JSON document on
**stdout** and nothing else: the banner, progress spinner, colours and the "report saved" notice all go to **stderr**,
so the stream is safe to pipe straight into `jq` or a parser. The exit code remains the pass/fail signal
(see [Exit codes](#exit-codes)).

```bash
bundle exec mutation_test --json examples/calculator.rb examples/calculator_spec.rb | jq .

# A single listed file works too; its spec is mapped by convention
bundle exec mutation_test --json lib/calculator.rb | jq .
```

The same report is also written to `tmp/mutation_reports/mutation_report.json` (see `--output-dir`). A run that
resolves exactly one source file, or an explicit `SOURCE_FILE TEST_FILE` pair, prints the plain per-file report; a
multi-file run (a `FILE` list with more than one file, `--staged`, or `--glob`) prints one aggregate envelope with a
condensed `survivors` array.

Every **surviving** mutant carries `file_path`, `line`, `original` and `mutated`, which is a concrete, located test
gap: the worklist you can hand to an AI agent or a CI gate (see [CI/CD integration](#cicd-integration)).

Full field-by-field documentation of both shapes (the single-file report and the multi-file envelope), the
`schema_version` policy, and ready-to-use `jq` recipes live in [docs/json-schema.md](docs/json-schema.md).

## Pre-push hook

Gate your pushes locally: run mutation testing on the file(s) you touched and block the push when the score is under
your bar, the fast-feedback sibling of the CI gate below.

The gem ships a ready-to-copy hook at [`examples/hooks/pre-push`](examples/hooks/pre-push) (installed with the gem, so
you have it offline). It runs `mutation_test --json`, reads the score with [`jq`](https://jqlang.github.io/jq/), and on
a below-threshold run lists the surviving mutants (file, line, what changed) so you see which gaps to close. Install it
with:

```bash
cp examples/hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

Then edit the `THRESHOLD` and the `SOURCE TEST` pair(s) at the top of the copied hook.

Prefer to gate on your project's configured threshold rather than one written into the hook? `mutation_test` already
exits non-zero when the score is below `config.minimum_score` (default 80), so you can drop the `jq` comparison and let
the exit code be the gate:

```sh
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb || exit 1
```

`--minimum-score N` sets that threshold for a single run, which is how you start below 80 in an existing codebase and
ratchet the number up over time:

```sh
bundle exec mutation_test --glob 'app/**/*.rb' \
  --spec-map '\Aapp/(.+)\.rb\z=>spec/\1_spec.rb' --minimum-score 60 || exit 1
```

lefthook or overcommit users: call the shipped hook from your `pre-push` step instead of writing to `.git/hooks/`.

## CI/CD integration

Run MutationTester as a CI quality gate: the CLI exits non-zero when the mutation score is below the threshold, so it
fails the job with no extra configuration.

The gem ships ready-to-copy GitHub Actions workflows (installed alongside the gem, so you have them offline too):

- [`examples/github_actions/mutation_test.yml`](examples/github_actions/mutation_test.yml) is the maintained template.
  Add the gem to your bundle, copy it to `.github/workflows/`, edit the `EDIT:` lines, and it runs the gate, uploads
  the HTML/JSON reports from `tmp/mutation_reports/` as an artifact (even on failure), and fails the job below
  threshold. It also carries commented variants for parallel execution, several file pairs, and an incremental
  pull-request gate.
- [`examples/github_actions/ai_mutation_gate.yml`](examples/github_actions/ai_mutation_gate.yml) is the AI gate: the
  same pass/fail gate, plus it writes the surviving-mutant worklist to the GitHub job summary and uploads
  `survivors.json` for an agent to turn into missing tests.

See [docs/ci.md](docs/ci.md) for the full recipes: a 5-minute setup, minimal inline and pull-request workflows, machine
mode as a gate and artifact, and the AI workflow.

## Troubleshooting

### Tests Pass Normally but Fail During Mutation Testing

This usually means:

- Your tests depend on execution order
- Your tests share state between runs
- Database transactions aren't being properly cleaned up

**Solution**: Ensure each test is independent and can run in isolation.

### Database Conflicts in Parallel Mode

If you see errors like "database is locked" or "record not found", your parallel workers are sharing one test database.

**Solution**: Force serial execution with `-p 1` (or `MUTATION_TESTER_PARALLEL_PROCESSES=1`), or keep parallelism by
giving each worker its own database with `--worker-env`
(see [Making parallelism work with Rails](#making-parallelism-work-with-rails)):

```bash
bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb -p 1
```

### Slow Execution

Mutation testing generates many mutations and runs your tests repeatedly, so it's naturally slower than a regular test
run.

**Tips for faster execution**:

- Test only critical files (don't test everything), or only changed files (`--staged`, `--since`)
- Focus on high-value code (models, services, core logic)
- Keep the parallel and in-memory defaults working (fix the issues that force a fallback; every fallback is announced
  on stderr with its reason)
- Consider using faster test databases (SQLite in-memory for unit tests)

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

MutationTester parses your source with the `parser` gem. The newest published `parser` line recognizes **Ruby 3.3
syntax**; there is not yet a release that understands Ruby 3.4+/4.x syntax. So when you run on Ruby 3.4 or newer you
may see one line on stderr per run:

```
warning: parser/current is loading parser/ruby33, which recognizes 3.3.x-compliant syntax, but you are running 4.0.2.
```

This warning is **benign**. It only means the parser recognizes syntax up to Ruby 3.3. The gem itself runs fine on
Ruby 3.4+/4.x, and files written in Ruby 3.3-and-earlier syntax are mutated normally.

The only real limitation is a source file that relies on syntax introduced after Ruby 3.3. Such a file cannot be
parsed, so it reports an explicit `Failed to parse source file` and the run fails - it never fakes a passing score. The
warning is left in place on purpose as an honest signal; it is not globally silenced.

## Development

Run `bundle install`, then run `rake spec` to run the tests.

The gem includes working examples for both RSpec and Minitest under the `examples/` directory (a sample `Calculator`
class with an RSpec spec and a Minitest test). Run them directly with the CLI, or through the example rake tasks:

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

Each example runs mutation tests on the sample Calculator class, generates console, HTML, and JSON reports, and shows
the difference between serial and parallel execution.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Oxyconit/mutation_tester.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE.txt).
