# CI/CD Integration

Ready-to-copy recipes for running MutationTester as a CI quality gate. See the
[CI/CD integration](../readme.md#cicd-integration) section of the README for the
overview and the shipped templates under
[`examples/github_actions/`](../examples/github_actions).

## Mutation testing in CI in 5 minutes

The gem ships a ready-to-copy GitHub Actions workflow at
[`examples/github_actions/mutation_test.yml`](../examples/github_actions/mutation_test.yml)
(installed alongside the gem, so you also have it offline). Three steps:

1. Add the gem to your bundle: `bundle add mutation_tester --group development,test`.
2. Copy the template to `.github/workflows/mutation_test.yml`.
3. Edit the lines marked `EDIT:` to point at your Ruby version and your source/test files.

The workflow checks out your code, sets up Ruby with `bundler-cache`, runs
`bundle exec mutation_test SOURCE TEST`, uploads the HTML/JSON reports from
`tmp/mutation_reports/` as a build artifact (even on failure), and fails the job
when the mutation score is below your threshold (the CLI exit code is the gate).
It also carries commented variants for parallel execution
(`MUTATION_TESTER_PARALLEL_PROCESSES`), for testing several file pairs, and for
an incremental pull-request gate (`--since`/`--fail-fast`).

## GitHub Actions (minimal inline workflow)

The same thing, condensed to a copy-pasteable minimal workflow. It matches the
maintained template above; reach for the template when you want the parallel and
multi-file variants. The quality gate needs no extra configuration: the CLI exits
non-zero when the mutation score is below the threshold, which fails the step (and
the job).

```yaml
name: Mutation Testing

on:
  push:
  pull_request:

jobs:
  mutation_test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'   # EDIT: match your project's Ruby (floor is 3.0)
          bundler-cache: true

      - name: Run mutation tests
        # EDIT: point at your own source file and its test file.
        run: bundle exec mutation_test app/models/user.rb spec/models/user_spec.rb

      - name: Upload mutation reports
        if: always()   # keep the reports even when the gate failed the job
        uses: actions/upload-artifact@v4
        with:
          name: mutation-reports
          # Default output_dir; change it if you pass a custom --output-dir.
          path: tmp/mutation_reports/
```

## GitHub Actions on pull requests (incremental gate)

On a pull request you rarely want to mutate the whole project. Combine
`--since` and `--fail-fast` to mutate only the files the PR changed and stop at
the first surviving mutant. The maintained template
[`examples/github_actions/mutation_test.yml`](../examples/github_actions/mutation_test.yml)
carries this variant too; the condensed version:

```yaml
name: Mutation Testing (PR)

on:
  pull_request:

jobs:
  mutation_test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # full history so git can diff against the base branch

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'   # EDIT: match your project's Ruby
          bundler-cache: true

      - name: Run mutation tests on changed files only
        # EDIT: point the glob at your own sources.
        run: |
          bundle exec mutation_test --glob 'lib/**/*.rb' \
            --since "origin/${{ github.base_ref }}" --fail-fast

      - name: Upload mutation reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: mutation-reports
          path: tmp/mutation_reports/
```

A PR that touches nothing under `lib/` exits `0` with a "Nothing to mutate"
message, so the gate never blocks unrelated changes.

## Machine mode as a CI gate and artifact

`--json` makes the CLI double as the gate (its exit code follows the threshold)
and the artifact producer. Capture stdout to a file, upload it, and the run
fails the job automatically when the score drops below the threshold:

```yaml
    - name: Run mutation tests (JSON report on stdout)
      run: |
        bundle exec mutation_test --json \
          app/models/user.rb spec/models/user_spec.rb > mutation_report.json

    - name: Upload JSON report
      if: always()   # keep the report even when the gate failed the job
      uses: actions/upload-artifact@v4
      with:
        name: mutation-report-json
        path: mutation_report.json
```

## AI workflow (mutation gate)

`--json` turns the report into a worklist for an AI agent (or a script): every
**surviving** mutant carries `file_path`, `line`, `original` and `mutated`, which
is a concrete, located test gap. A CI job can run the gate, publish those
survivors, and hand them to an agent that proposes the missing tests.

The gem ships a ready-to-copy workflow at
[`examples/github_actions/ai_mutation_gate.yml`](../examples/github_actions/ai_mutation_gate.yml)
(installed with the gem, so you have it offline). Copy it to
`.github/workflows/ai_mutation_gate.yml`, add the gem to your bundle, and edit
the `EDIT:` lines. It:

1. runs `mutation_test --json` and captures the report,
2. writes the score and a table of surviving mutants to the GitHub job summary
   (`$GITHUB_STEP_SUMMARY`),
3. extracts the survivors into a machine-readable `survivors.json` and uploads it
   (with the full report) as an artifact even on a failing run,
4. re-fails the job when the score is below the threshold, so it stays a gate.

The survivor extraction is the same `jq` filter documented under
[Extracting the score and the survived mutants](json-schema.md#extracting-the-score-and-the-survived-mutants),
written to `survivors.json`. That file is what you feed the agent ("here are
located test gaps; for each, write a focused test that would kill the mutant");
the template carries a commented step showing where to wire your agent CLI. Use
it alongside the plain [5-minute CI template](#mutation-testing-in-ci-in-5-minutes):
the AI gate adds the surviving-mutant worklist, the plain template is just the
pass/fail gate.
