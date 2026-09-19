# Mutation Types

The full catalog of mutation families MutationTester generates. Ten families are
enabled by default; strict-equality is opt-in. See the
[Mutation types](../readme.md#mutation-types) section of the README for how to
enable or disable individual families via `config.mutation_types` or the
`--strict-equality` flag. The [Equivalent mutants](#equivalent-mutants) section
below covers how to interpret and suppress survivors.

## Arithmetic Mutations

- `+` → `-`, `*`, `/`
- `-` → `+`, `*`, `/`
- `*` → `+`, `-`, `/`
- `/` → `+`, `-`, `*`
- `%` → `+`, `-`, `*`
- `**` → `*`, `+` (only these two: `-`/`/` tend to produce hard-to-kill or `ZeroDivisionError` mutants)
- Compound assignment (`+=`, `-=`, `*=`, `/=`, `%=`, `**=`) mutates its operator the same way (e.g. `a **= b` →`a *= b`,
  `a += b`).

## Bitwise Compound-Assignment Mutations

- `|=` → `&=`
- `&=` → `|=`
- `^=` → `|=`, `&=`

Plain bitwise sends (`a | b`, `a & b`, `a ^ b`), and the shift assignments `<<=` / `>>=`, are intentionally left alone:
mutating them mostly yields always-killed `NoMethodError` garbage rather than a meaningful test gap.

## Comparison Mutations

- `>` → `<`, `>=`, `<=`, `==`
- `<` → `>`, `>=`, `<=`, `==`
- `>=` → `<`, `>`, `<=`, `==`
- `<=` → `>`, `>=`, `<`, `==`
- `==` → `!=`, `>`, `<`
- `!=` → `==`, `>`, `<`
- `<=>` → `==`
- Range boundary: `a..b` → `a...b` and `a...b` → `a..b`, the range form of `<=` versus `<` on the upper bound. Only
  a test that uses the upper bound itself (the last element, the last character kept by `text[0...limit]`) kills it.
  An endless range (`1..`, `1..nil`, `text[1..]`) and a range ending at `Float::INFINITY` are left alone, because both
  forms hold the same values there; beginless ranges (`..5`) are mutated, and flip-flops are not ranges and are
  untouched. Reported with `type: comparison`, `original` and `mutated` being the two operators (e.g.
  `Change .. to ...`). Numeric literal bounds still get their own `number` mutants.

## Strict Equality Mutations (opt-in)

- `==` → `eql?` (value equality without numeric type coercion: `1 == 1.0` is true, `1.eql?(1.0)` is false)
- `==` → `equal?` (object identity instead of value equality)
- **Off by default** and generated only when explicitly enabled via `config.mutation_types[:strict_equality] = true` or
  the CLI flag `--strict-equality`. The default mutation set generates none of these probes, preserving its
  zero-equivalent-mutant property.
- Purpose: code that is sensitive to numeric types or object identity (money amounts, identifiers, cache keys). A
  surviving `eql?` probe means no test distinguishes Integer from Float inputs (e.g. no `divide(10.0, 0.0)` case); a
  surviving `equal?` probe means no test distinguishes equal-value objects from the same object.
- **Warning: expect noise.** On code that intentionally does not distinguish numeric types or identity, these probes
  survive as equivalent-in-practice mutants even against a complete test suite, lowering the score without pointing at a
  real gap. Enable the mode deliberately for type-sensitive code, not in default CI runs; use the
  `# mutation_tester:disable` line annotation for individual false positives.
- Applies to `==` sends with an explicit receiver and one operand. Reported with `type: strict_equality` (e.g.
  `Change == to eql?`).

## Logical Mutations

- `&&` → `||`
- `||` → `&&`
- `||=` → `&&=`
- `&&=` → `||=`
- Operand removal: each `a && b` / `a || b` (and the keyword forms `a and b` / `a or b`) also yields two mutants
  replacing the whole expression with just `a` and with just `b`. A flag whose branch the suite never exercises (say
  `vip || total >= limit` with no VIP test) survives as an operand-removal mutant even when the `||` → `&&` swap is
  killed.
- Chains like `a || b || c` are mutated per logical node, removing each operand separately (`a || b`, `c`, `a || c`,
  `b || c`).
- Reported with `type: logical`; the description names the removed operand (e.g. `Remove operand @vip from ||`). A
  removal candidate whose code would no longer parse is dropped at generation time.

## Boolean Mutations

- `true` → `false`
- `false` → `true`

## Number Mutations

- Any number → `0`, `1`, `number + 1`, `number - 1`

## String Mutations

- Any string → empty string `""`

## Conditional Mutations

- Negate conditions in `if` statements (also `unless`, ternary `?:`, and `elsif` branches)
- Negate the condition of `while` and `until` loops, including the modifier forms (`x while cond`, `x until cond`) and
  post forms (`begin ... end while cond`)
- The whole condition is wrapped as `!(cond)`. A negated loop condition may never terminate; that infinite-loop mutant
  is caught by the per-mutant timeout and counted as killed.
- `case`/`when` branch deletion: for each `when` clause of a `case`, one mutant removes that clause so its values fall
  through to the next `when`/`else` (or return `nil`). A `case` with a single `when` is left alone (removing it would
  not parse), and Ruby `case/in` pattern matching is not mutated. Literals inside a `when` (numbers, strings, range
  bounds) are still mutated by their own types.

## Call Removal Mutations

- Removes a pure transforming call from a chain, replacing `recv.m` with `recv` (e.g. `items.uniq.sum` → `items.sum`). A
  test suite that never exercises the transformation (say, no input with duplicates for `uniq`) lets this mutant
  survive.
- Applies only to a curated whitelist of pure, no-argument transformations: `uniq`, `compact`, `sort`, `flatten`,
  `strip`, `chomp`, `downcase`, `upcase`, `capitalize`, `reverse`, `round`, `floor`, `ceil`, `abs`, `to_a`. `freeze` and
  `dup` are deliberately excluded: removing them is behaviorally equivalent under normal test observation (e.g. dropping
  `.freeze` on a constant is unkillable black-box), and the default set keeps the zero-equivalent-mutants property.
- Calls with arguments or a block, calls without an explicit receiver, and safe-navigation calls (`recv&.m`) are never
  removed. A removal candidate whose code would no longer parse is dropped at generation time.
- Reported with `type: call_removal`; `original` is the removed call expression (e.g. `items.uniq`) and `mutated` is the
  bare receiver (e.g. `items`).

## Nil Injection Mutations

- Replaces the last expression of a method body (`def` and `def self.`) with `nil`, unless it is already a literal`nil`.
  A single-expression method has its whole body replaced. The most common catch is a fluent API returning a final`self`:
  a spec that only checks side effects lets the `self` → `nil` mutant survive.
- Replaces the right-hand side of an instance variable assignment (`@x = expr` → `@x = nil`), unless the assigned value
  is already `nil`. Local variable assignments and `||=`/`&&=` memoization are intentionally left alone.
- Limitation: only the last expression of the method body is mutated. Expressions returned via an explicit `return` in
  the middle of the method are not mutated in this iteration, and methods whose body ends in a `rescue`/`ensure` clause
  are skipped.
- A candidate whose code would no longer parse is dropped at generation time.
- Reported with `type: nil_injection`; `original` is the replaced expression (e.g. `self`) and `mutated` is `nil`.

## Argument Mutations

- Removes the last argument of a regular method call: `m(a, b)` → `m(a)`, `m(a)` → `m()`, and the paren-free style is
  preserved (`raise ArgumentError, msg` → `raise ArgumentError`, `raise msg` → `raise`). Only the last argument is
  removed per mutant; a two-argument `raise` never degenerates to a bare `raise` in a single mutant.
- Substitutes `nil` for each argument separately (`Result.new(:ok, format_label(total))` → `Result.new(:ok, nil)`),
  unless the argument is already the `nil` literal. A test that never verifies the effect of an argument (say, an
  exception message asserted only by class, or a constructor field no spec reads) lets these mutants survive even when
  the argument is not a literal.
- Removes one pair of a hash passed as a call argument, each pair in its own mutant: keyword options
  (`validates :role, presence: true, inclusion: ROLES` → `validates :role, inclusion: ROLES` and
  `validates :role, presence: true`), braced hashes, and option hashes nested as a pair value
  (`uniqueness: { scope: :account_id, case_sensitive: false }` → `uniqueness: { case_sensitive: false }`). Unlike
  removing or nil-ing the whole argument, the call usually still loads and runs, so only a test that checks that one
  option kills the mutant. A braced hash with a single pair becomes `{}`; a lone brace-free keyword that ends the call
  (`m(a, k: 1)`) is left to the last-argument removal, which produces the same code, and is removed here only when a
  block pass follows it (`m(a, k: 1, &blk)` → `m(a, &blk)`). Hashes that carry a double splat (`**opts` or an anonymous
  `**`) and hash literals that are not call arguments (`PRICES = { ... }`) are not touched, and a pair is kept when
  removing it would cut into a heredoc (the pair opens one, or a heredoc body lies between the pair and its neighbor).
  Reported with the description `Remove pair <key> from <method>` on the line of the removed pair, so in a multi-line
  call each pair can be annotated on its own line; when the removed text spans a line break, `mutated_line` is the
  marker `(pair removed)` and `mutated` still holds the whole call after the mutation. As with last-argument removal, a
  pair that only repeats the callee's own default (`notify(user, async: false)` when `async` already defaults to
  `false`) yields a mutant no test can kill; annotate the line of that pair with `# mutation_tester:disable`.
- Exclusions: operator sends (`+`, `==`, `[]`, `[]=`, `<<`, setters, ...), require-like calls (`require`,
  `require_relative`, `load`, `autoload`), block-pass arguments (`&blk`), splats (`*args`), double splats (`**opts`),
  and safe-navigation calls are not mutated by this family. A candidate whose code would no longer parse is dropped at
  generation time.
- Mutates parameter defaults in method definitions structurally, for any default expression (not only literals): removes
  the default so the parameter becomes required (`def m(x, opts = {})` → `def m(x, opts)`, `def m(vip: false)` →
  `def m(vip:)`) and replaces the default with `nil` (`opts = nil`), unless the default is already the `nil` literal. A
  literal `false` default gets only the removal variant, never the `nil` variant: `false` and `nil` are
  indistinguishable in boolean context, so `vip: nil` would survive as an equivalent mutant against any truth-testing
  code. A surviving removal mutant means no test ever calls the method without that argument.
- Default-mutation exclusions: parameter names, splat/double-splat and block parameters are untouched. When an optional
  positional parameter precedes a required one (`def m(a = 1, b)`), removing the default would silently change argument
  binding, so only the `nil` variant is generated for those positional parameters; keyword defaults are unaffected by
  ordering.
- Reported with `type: argument`; `original` is the full original call (e.g. `raise ArgumentError, msg`) and `mutated`is
  the call after the mutation (e.g. `raise ArgumentError`). For a default-value mutant, `original` is the original
  parameter (e.g. `opts = {}`) and `mutated` is the parameter after the mutation (e.g. `opts` or `opts = nil`).

## Equivalent mutants

A mutation score of 100% is not always achievable, and a surviving mutation is
not always a gap in your tests. Some mutations produce code that behaves
**identically** to the original for every possible input. These are called
*equivalent mutants*, and no test can ever kill them because there is no input
that makes them behave differently.

For example, in a `max` implementation:

```ruby
a > b ? a : b # original
a >= b ? a : b # mutant
```

The two expressions only differ when `a == b`, and in that case both return the
same value (`a` equals `b`), so the observable result is the same for every
input. This mutant survives no matter how thorough your tests are.

Because equivalent mutants cannot be detected automatically in the general case
(it is an undecidable problem), treat surviving mutations as *candidates* to
review rather than guaranteed test gaps. When you determine a survivor is
equivalent, it is reasonable to accept a mutation score below 100%.

### Excluding a line with `# mutation_tester:disable`

Once you have confirmed that a survivor is equivalent, annotate its line so the
mutator stops generating mutants there. Add a trailing `# mutation_tester:disable`
comment (the same style as `# rubocop:disable`) to the line you want to skip:

```ruby
def max(a, b)
  a > b ? a : b # mutation_tester:disable
end
```

The mutator reads this marker from the source's comments and skips every mutation
whose location is on that line, across all mutation types (operator, number,
string, boolean, conditional, logical, call removal). Excluded lines never enter the mutation
score or the list of survived mutations, so an accepted equivalent mutant stops
deflating the score and cluttering the report on every run. The console summary
reports how many lines were excluded as a separate informational category:

```
  Excluded: 1 line(s) (mutation_tester:disable) 🚫
```

Notes and current limits:

- The annotation is honoured only inside a real comment, never inside a string
  literal.
- Exclusion is per line: the marker skips only the line it sits on. Placing it on
  its own line (above the code) is a no-op, because that line has nothing to
  mutate.
- Block ranges (`disable`/`enable`), per-type exclusion
  (`# mutation_tester:disable comparison`), and a global exclusion list in
  configuration are not supported yet.
