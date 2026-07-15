# Changelog

## [1.3.0] - 2026-07-15

- Calibrated the per-mutant timeout against the measured baseline run: unless `config.timeout` is set explicitly, each mutant now gets `max(5s, timeout_factor * baseline duration)` (factor configurable via `config.timeout_factor` / `--timeout-factor N`, default 5) instead of a fixed 30 s, so a loaded machine no longer inflates the mutation score by killing healthy-but-slow runs as timeouts. An explicit `config.timeout` (including `nil` for no deadline) keeps today's fixed-budget behavior and disables calibration. Added the opt-in `config.timeout_policy = :separate` / `--timeout-policy separate`, which scores `killed / (killed + survived)` with timeouts excluded from the score and reported only as their own category; the default `:killed` policy and its output are unchanged.
- Runs that finish without a single scored mutant (every mutant errored or was stillborn) are now reported as an infrastructure/runner failure with the error/stillborn counts instead of a misleading "score 0.0% is below threshold" verdict. `Core` exposes `infrastructure_failure?` to distinguish such degraded runs (including the shadow-workspace abort) from a genuine threshold failure, and `mutation_test` maps them to the new exit code `3` in single-file mode (`0` pass, `1` threshold failure, `2` usage error, `130` interrupt). The batch summary names degraded files instead of blaming the threshold.

## [1.2.0] - 2026-07-14

- Fixed the in-memory runner reporting false survivors for mutations that only take effect at class-load time (constants consumed by macros, `validates`/`has_many`/`before_save`/`scope`/`attribute`, and anything inside an `included do` block). The mutator now classifies each mutation by AST context, and the in-memory run routes load-time mutations to the file-based path while keeping method-body mutations in memory, so the default (`auto`) score matches a full `fork` run on Rails concerns and models. Measured on a real Rails concern the default score went from a misleading 1.63% to the correct 35.77%.

## [1.1.0] - 2026-07-13

- Added `--worker-env NAME` (and the `MUTATION_TESTER_WORKER_ENV` environment variable) to set a distinct per-worker value of `NAME` before each parallel worker boots, following the `parallel_tests` `TEST_ENV_NUMBER` convention (worker 0 -> "", worker N -> N+1). This lets a Rails app with a `parallel_tests`-style `database.yml` run parallel mutation testing with a per-worker database instead of being forced to serial execution. Supported by the `fork` and `spawn` runners; the `in_memory` runner cannot isolate a per-worker database and falls back to `fork` with an announced notice.

## [1.0.0] - 2026-07-12

- Released first version.
