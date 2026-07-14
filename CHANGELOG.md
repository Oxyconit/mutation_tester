# Changelog

## [1.2.0] - 2026-07-14

- Fixed the in-memory runner reporting false survivors for mutations that only take effect at class-load time (constants consumed by macros, `validates`/`has_many`/`before_save`/`scope`/`attribute`, and anything inside an `included do` block). The mutator now classifies each mutation by AST context, and the in-memory run routes load-time mutations to the file-based path while keeping method-body mutations in memory, so the default (`auto`) score matches a full `fork` run on Rails concerns and models. Measured on a real Rails concern the default score went from a misleading 1.63% to the correct 35.77%.

## [1.1.0] - 2026-07-13

- Added `--worker-env NAME` (and the `MUTATION_TESTER_WORKER_ENV` environment variable) to set a distinct per-worker value of `NAME` before each parallel worker boots, following the `parallel_tests` `TEST_ENV_NUMBER` convention (worker 0 -> "", worker N -> N+1). This lets a Rails app with a `parallel_tests`-style `database.yml` run parallel mutation testing with a per-worker database instead of being forced to serial execution. Supported by the `fork` and `spawn` runners; the `in_memory` runner cannot isolate a per-worker database and falls back to `fork` with an announced notice.

## [1.0.0] - 2026-07-12

- Released first version.
