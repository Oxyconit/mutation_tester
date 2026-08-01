# Changelog

## [1.4.0] - 2026-08-01

- Minitest suites now use the same execution runners as RSpec instead of being pinned to `spawn`. The fork worker preloads `minitest` (disabling the `minitest/autorun` at-exit hook and driving `Minitest.run` itself, so the file still runs exactly once per mutant) and the in-memory runner preloads the test file once and re-evaluates each mutant in a fresh fork, so a Minitest project no longer pays a full interpreter, Bundler and framework boot per mutant. Preloaded workers are now keyed by framework, so a mixed-framework `--glob` run never hands a Minitest file to an RSpec-preloaded worker.
- Every mutant run now stops at its first failing test: RSpec runs get `--fail-fast` and Minitest runs get a preloaded reporter that aborts on the first non-passing result, on all three runners. This cannot change a verdict (a run that stops early has already failed, which is what makes a mutant killed), and only mutant runs opt in: the baseline run and the shadow sanity check still run the whole file. It removes the pathology where a mutant that breaks something every test touches (a class body that no longer loads, a constant every test reads) re-raised the same error once per test, crossed the calibrated deadline, and was reported as a `timeout` instead of a `killed` - a failure mode that got worse as tests were added to the file. Measured on a 15-mutant fixture with a 0.6 s boot and 12 tests: 22.2 s -> 6.5 s by default and 22.7 s -> 13.2 s with `--runner spawn`, with an unchanged score.
- The console summary now names the deadline that timed-out mutants were measured against and where it came from (`deadline: 6.50s (5x baseline 1.30s)`, or `(explicitly configured)`), so a genuine hang and a deadline calibrated from a slow test file are no longer indistinguishable.
- `--fail-fast` now stops a batch at the first file with a surviving mutant even when that file's own run completed. `Core#stopped_on_survivor?` reports the fail-fast stop, while `Core#interrupted?` keeps its narrower meaning (mutants were left unprocessed) for the reports and the interruption banner.

## [1.3.0] - 2026-07-15

- Calibrated the per-mutant timeout against the measured baseline run: unless `config.timeout` is set explicitly, each mutant now gets `max(5s, timeout_factor * baseline duration)` (factor configurable via `config.timeout_factor` / `--timeout-factor N`, default 5) instead of a fixed 30 s, so a loaded machine no longer inflates the mutation score by killing healthy-but-slow runs as timeouts. An explicit `config.timeout` (including `nil` for no deadline) keeps today's fixed-budget behavior and disables calibration. Added the opt-in `config.timeout_policy = :separate` / `--timeout-policy separate`, which scores `killed / (killed + survived)` with timeouts excluded from the score and reported only as their own category; the default `:killed` policy and its output are unchanged.
- Runs that finish without a single scored mutant (every mutant errored or was stillborn) are now reported as an infrastructure/runner failure with the error/stillborn counts instead of a misleading "score 0.0% is below threshold" verdict. `Core` exposes `infrastructure_failure?` to distinguish such degraded runs (including the shadow-workspace abort) from a genuine threshold failure, and `mutation_test` maps them to the new exit code `3` in single-file mode (`0` pass, `1` threshold failure, `2` usage error, `130` interrupt). The batch summary names degraded files instead of blaming the threshold.

## [1.2.0] - 2026-07-14

- Fixed the in-memory runner reporting false survivors for mutations that only take effect at class-load time (constants consumed by macros, `validates`/`has_many`/`before_save`/`scope`/`attribute`, and anything inside an `included do` block). The mutator now classifies each mutation by AST context, and the in-memory run routes load-time mutations to the file-based path while keeping method-body mutations in memory, so the default (`auto`) score matches a full `fork` run on Rails concerns and models. Measured on a real Rails concern the default score went from a misleading 1.63% to the correct 35.77%.

## [1.1.0] - 2026-07-13

- Added `--worker-env NAME` (and the `MUTATION_TESTER_WORKER_ENV` environment variable) to set a distinct per-worker value of `NAME` before each parallel worker boots, following the `parallel_tests` `TEST_ENV_NUMBER` convention (worker 0 -> "", worker N -> N+1). This lets a Rails app with a `parallel_tests`-style `database.yml` run parallel mutation testing with a per-worker database instead of being forced to serial execution. Supported by the `fork` and `spawn` runners; the `in_memory` runner cannot isolate a per-worker database and falls back to `fork` with an announced notice.

## [1.0.0] - 2026-07-12

- Released first version.
