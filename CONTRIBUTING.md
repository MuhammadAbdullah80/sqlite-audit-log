# Contributing

## Running the tests

```
bash tests/run.sh
```

49 checks: assertions over the seeded views, statements that must be rejected
with the right error, and one run of every query in `queries.sql`.

Nothing outside `sqlite3` is required.

## How the tests are split, and why

**`tests/assertions.sql`** seeds a history and checks what the schema and views
report. Each line prints `ok` or `FAIL`.

**`tests/run.sh`** holds every case that must be *rejected*. These cannot live in
the SQL file: a raised error aborts the enclosing script, so each rejection needs
its own `sqlite3` invocation.

A change to a constraint needs a case in the second half. "It is rejected" is the
whole product here — a constraint with no test asserting the rejection is a
constraint that can be silently removed.

## Adding a constraint

Prefer a `CHECK` when the rule involves only the row being inserted. Use a
trigger when it needs another table — a `CHECK` cannot reference one, and
hard-coding what should be a lookup is how `audit_action` nearly became
decoration. See `audit_log_payload_matches_action` for the pattern.

State the rejection message in the test, not just the fact of rejection. An error
that says `CHECK constraint failed: audit_log` tells an operator nothing;
`payload does not match action` tells them where to look.

## Adding an action type

Insert into `audit_action` with the right `has_before` / `has_after`. No schema
change is needed and no trigger has to learn about it — that is the whole point
of the lookup table, and there is a test asserting a new type is both usable and
enforced.

## Things that are deliberate

- **A no-op `UPDATE` is not an error.** `BEFORE UPDATE` fires per matching row,
  and one matching nothing never reaches the trigger. Nothing is modified. The
  guarantee is that no existing row can change, not that the verb is unusable.
- **`GLOB`, not `LIKE`, on `recorded_at`.** `LIKE` is case-insensitive for ASCII
  in SQLite and would accept `2026-01-01t10:00:00z`.
- **`AUTOINCREMENT`, not a bare rowid alias.** A plain `INTEGER PRIMARY KEY`
  reuses freed values, and monotonic ids are what make "everything after id N"
  meaningful.
- **`.sql` is force-detected via `.gitattributes`.** Linguist types SQL as
  `data` and would otherwise report this repo as Shell.

## What this schema does not claim

A connection with DDL rights can `DROP` the triggers. This stops application bugs
and casual tampering, not an attacker holding schema access. Please do not open
issues describing that as a vulnerability — it is documented in the README, and a
fix needs something outside the database: append-only storage, off-host
replication, or a signed hash chain.
