# Execution Runners and Test Selection

Deep reference for how MutationTester executes each mutant and how two-phase test
selection speeds up kills. See the [Execution model](../readme.md#execution-model)
section of the README for the overview, the parallel/serial guidance, and how to
force a runner.

## Execution runners (fork, spawn, in-memory)

Every mutant is executed by one of three runners:

- **fork**: a helper process preloads the environment
  once (RubyGems, Bundler and the test framework: `rspec-core` for RSpec,
  `minitest` for Minitest, without loading the mutated file or the tests), and
  each mutant runs in a fresh fork of that process. The fork loads the test file
  only after the mutated source has been written, so every mutant is visible and
  no state leaks between mutants. For Minitest the worker disables the
  `minitest/autorun` at-exit hook and drives `Minitest.run` itself, so the file
  runs exactly once per mutant. This removes most of
  the fixed per-mutant boot cost, which matters on large suites and in CI.
- **spawn**: each mutant starts a full new process (`bundle exec rspec ...` or
  `bundle exec ruby test_file.rb`). Slower per mutant, but works everywhere.
- **in_memory** (default where supported): the helper process additionally preloads the test
  file and, through it, the original source, once per run. Each mutant then
  runs in a fresh fork that re-evaluates the mutated source in memory
  (redefining the loaded methods and class constants, with the
  "already initialized constant" warning silenced only inside that child) and
  runs the already-loaded examples. Nothing is written to disk on the mutation
  hot path: the source file and the project directory stay untouched for the
  whole run and no shadow workspaces are created. With `-p N` the preloaded
  process is forked into a pool of clones and each parallel worker runs its
  mutants in memory against its own clone. This brings the cost per mutation
  below the fork runner and close to in-process mutation tools, at the price
  of requiring loadable, re-evaluable code (see the limitations below).

Selection is automatic (`auto`): the fastest safe path is tried first and every
step down to a slower one prints a single stderr warning with its reason, so a
fallback is never silent. The order is `in_memory` (RSpec with `Process.fork`
available and a passing unmutated-source probe), then `fork`, then `spawn`.
Both RSpec and Minitest suites use the same three runners.
All runners produce identical scores and per-mutant statuses, and all enforce
the same hard per-mutant timeout (monotonic deadline plus a process-group
kill).

| Mode        | Picked by `auto` when                                                                                                                                                   | Falls back to                                                                                                                              |
|-------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `in_memory` | the platform has `Process.fork`, the file has no load-time `defined?` guard, and re-applying the unmutated source in a probe child passes the suite | `fork`/`spawn` (whole run) with a stderr warning naming the reason; a single worker dying mid-run falls back only for its share of mutants; a mutant that raises while being applied falls back alone |
| `fork`      | `Process.fork` is available, but in-memory is unavailable (each reason is printed)                                                                                      | `spawn`, with a stderr warning, when the helper process fails to preload the environment                                                   |
| `spawn`     | the platform has no `Process.fork`                                                                                                                                      | nothing; it works everywhere                                                                                                               |

Forcing a mode with `--runner fork|spawn|in_memory` skips the auto attempts and
uses that mode directly (`in_memory` keeps its own documented safety fallbacks;
`fork` still degrades to `spawn` where `Process.fork` does not exist).

### When to force --runner fork or spawn

- **`--runner fork`**: your source file is not cleanly re-evaluable in memory
  (heavy load-time side effects, code that must never be redefined) and you do
  not want to rely on the automatic probe, but you still want the preloaded
  environment speed.
- **`--runner spawn`**: you want maximum isolation (one full pristine process
  per mutant), you are debugging a suspicious result from a preloaded runner,
  or your environment misbehaves with forked workers (for example C extensions
  that do not survive `fork`).
- Stay on the default `auto` everywhere else: it always announces on stderr
  which path it took, so CI logs show exactly how the mutants were executed.

Override the automatic choice with any of:

```bash
# CLI flag
mutation_test --runner spawn lib/calculator.rb spec/calculator_spec.rb

# Environment variable
MUTATION_TESTER_RUNNER=spawn mutation_test lib/calculator.rb spec/calculator_spec.rb
```

```ruby
MutationTester.configure do |config|
  config.runner = :spawn
end
```

### Stopping a mutant at its first failing test

Every mutant run stops as soon as one test fails, on all three runners:

- RSpec mutant runs are given `--fail-fast` (as a CLI argument on `spawn`, in the
  runner arguments on `fork`, and in the preloaded configuration on `in_memory`).
- Minitest mutant runs load `lib/mutation_tester/minitest_fail_fast.rb`, which
  registers a Minitest plugin whose reporter raises `Interrupt` on the first
  non-passing result. On `spawn` the file is preloaded with `ruby -r`, on the
  preloaded runners the worker enables the same reporter per job.

This cannot change a verdict. A run that stops early has already recorded a
failure, which is exactly what makes a mutant killed, and a run without a failure
is untouched and executes every test. Only the mutant runs opt in: the baseline
run and the shadow-workspace sanity check are expected to pass and always run the
whole file, so a failing baseline still reports every failure it finds.

The pathological case it removes is a mutant that breaks something every test
touches (a class body that no longer loads, a constant every test reads). Such a
mutant used to re-raise the same error once per test, which on a large test file
can cross the per-mutant deadline and be reported as a `timeout` instead of a
`killed`, and which gets worse as tests are added to the file.

### Limitations of the fork runner

- Platforms without `Process.fork` (for example Windows or JRuby) always use
  `spawn`, even when `--runner fork` is requested.
- If the helper process fails to preload the environment, the run warns once
  and falls back to `spawn`.
- The helper process is started once in the real project root, so Ruby has
  already absolutized every `-I` / `RUBYLIB` entry against that directory before
  any mutant runs. Changing directory into a shadow workspace cannot undo that,
  so each job additionally rewrites the `$LOAD_PATH` entries that point into the
  mirrored project root so they point into the workspace. Without it a Minitest
  file reaching its source through `require "test_helper"` would load the
  original, unmutated tree and every mutant would falsely survive. RSpec re-adds
  `lib` and its default path at run time, after the child has changed directory,
  so it resolves the workspace copy either way.

### Limitations of the in-memory runner

The in-memory runner never fails silently: each case below falls back to
file-based execution with a warning, and a mutant is marked `error` only when
no fallback is possible.

- The file must be classic loadable code (classes/modules) that survives being
  evaluated a second time.
- With `-p N` (N > 1) the run stays fully in memory: the environment, the
  original source and the specs are preloaded once, the preloaded process is
  forked into N pooled clones, and every parallel worker applies each mutant
  in a fresh fork of its own clone. If a pooled worker dies mid-run, that
  worker finishes its share of mutants through the file-based path with a
  warning; the other workers stay in memory.
- Before any mutant runs, the runner re-applies the **unmutated** source in a
  probe child and runs the suite. If that probe fails (for example the file has
  top-level side effects that break on a second execution, or the class is
  frozen so it cannot be reopened), the whole run falls back to file-based
  execution with a warning instead of reporting false kills. In a parallel run
  this fallback lands on the regular parallel file-based path, after the same
  shadow-workspace sanity check that path always performs.
- Files that use `defined?` at load time (for example
  `X = 1 unless defined?(X)`) are rejected up front with a fallback warning:
  the guard would silently skip the redefinition and mutants could falsely
  survive. `defined?` inside method bodies is fine.
- A mutant that raises while being applied in memory (for example a top-level
  `raise`, a mutation that makes the file unloadable, or a `FrozenError` on
  redefinition) falls back to file-based execution for that single mutant with
  a warning: the mutant is decided from disk in a shadow workspace and that
  result is final. An objectively unloadable mutant therefore counts as
  `killed`, exactly as under the fork and spawn runners, while a failure
  specific to the in-memory mechanics still gets an honest file-based verdict
  instead of a false kill. Such a mutant is reported as `error` only when the
  fallback is impossible because no project root (a `Gemfile` or a `.git`
  directory) is discoverable above the source file.
- `require_relative` in the mutated file is safe: it is idempotent on the
  second evaluation because the file is already in `$LOADED_FEATURES`.
- Two-phase test selection does not apply in this mode (serial or parallel);
  every mutant runs the full preloaded example set (the examples are already
  in memory, so the per-mutant cost stays low). Because no selection happens,
  the `Selection:` summary line is omitted for in-memory runs; it reappears
  only when a fallback actually executed mutants through the file-based path.

## Test selection (fast kill with full-file confirmation)

For RSpec suites, MutationTester runs each mutant in two phases instead of
always paying for the whole spec file:

1. **Fast kill (subset)**: for a mutant inside method `foo`, it first runs only
   the examples whose group description matches the method
   (`rspec spec_file -e '#foo' -e '.foo'`, following the common
   `describe '#foo'` / `describe '.foo'` convention). If any of these examples
   fail or time out, the mutant is finished right there: killed (or timeout)
   without ever running the rest of the file.
2. **Full-file confirmation**: if the subset passes, the full spec file is run
   and only that result decides the status. A mutant can never be reported as
   survived from the subset alone, so selection cannot introduce false
   survivors.

The heuristic degrades safely: when the mutant is not inside a method, when the
spec file contains no `'#foo'` / `".foo"` group description, or when the suite
is Minitest, the full file runs directly. Scores and per-mutant statuses are
identical with and without selection on both file-based execution runners (fork
and spawn); selection only changes how fast killed mutants die. The in-memory
runner (the default path) performs no selection at all: every mutant runs the
full preloaded example set, which is why its report omits the `Selection:`
summary line (see the in-memory limitations above).

Disable it with the `--no-test-selection` CLI flag or in Ruby:

```ruby
MutationTester.configure do |config|
  config.test_selection = false
end
```
