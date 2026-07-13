# Changelog

## [1.1.0] - 2026-07-13

- Added `--worker-env NAME` (and the `MUTATION_TESTER_WORKER_ENV` environment variable) to set a distinct per-worker value of `NAME` before each parallel worker boots, following the `parallel_tests` `TEST_ENV_NUMBER` convention (worker 0 -> "", worker N -> N+1). This lets a Rails app with a `parallel_tests`-style `database.yml` run parallel mutation testing with a per-worker database instead of being forced to serial execution. Supported by the `fork` and `spawn` runners; the `in_memory` runner cannot isolate a per-worker database and falls back to `fork` with an announced notice.

## [1.0.0] - 2026-07-12

- Released first version.
