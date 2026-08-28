# sqlite-audit-log

An append-only audit log for SQLite, enforced by the database rather than by the
application writing to it.

```
sqlite3 audit.db ".read schema.sql"
```

The point of an audit log is that it cannot be quietly rewritten. Application
code promising not to issue `UPDATE` is not an enforcement mechanism, so the
rules live in the schema.

## Writing

```sql
INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
VALUES ('ada', 'create', 'invoice', 'INV-1', '{"total":100}');

INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json, after_json)
VALUES ('bob', 'update', 'invoice', 'INV-1', '{"total":100}', '{"total":150}');
```

`recorded_at` defaults to the current UTC time in ISO-8601. `context_json` is
free-form room for a request id, source IP or ticket reference.

## Reading

| View | Shows |
| --- | --- |
| `audit_entity_current` | newest mutation per entity, with the state it left |
| `audit_entity_live` | entities whose last mutation was not a delete |
| `audit_actor_activity` | per-actor counts, first/last seen, entities touched |
| `audit_entity_history` | every event for an entity, newest first |

```sql
SELECT current_json FROM audit_entity_live
WHERE entity_type = 'invoice' AND entity_id = 'INV-1';
```

`current_json` is NULL when an entity's last mutation was a delete, which is why
`last_action` sits beside it — NULL alone cannot tell "deleted" from "this
action carries no payload".

## What the database refuses

- **`UPDATE` and `DELETE` on `audit_log`**, via `BEFORE` triggers.
- **Rows that contradict themselves**: an `update` with no before state, a
  `create` that claims one, a `read` carrying a payload. A log you cannot trust
  to be self-consistent is not evidence of anything.
- **Unknown actions**, via a foreign key to `audit_action`.
- **Malformed JSON** in any of the three JSON columns, via `json_valid()`.
- **Timestamps that are not UTC ISO-8601.** The constraint uses `GLOB`, not
  `LIKE`: `LIKE` is case-insensitive for ASCII in SQLite and would accept
  `2026-01-01t10:00:00z`.
- **Deleting a row from `audit_action`**, which would orphan history.

## Worked queries

`queries.sql` holds the questions an incident actually starts with — an entity's
full history, a field-level diff of each update, an actor's deletes measured
against their own daily average, entities nobody has touched in 90 days, and two
integrity checks (gaps in the id sequence, and rows whose `recorded_at` runs
backwards against their id).

```
sqlite3 audit.db ".read queries.sql"
```

They are parameterised with `:named` placeholders; set them with `.parameter set`
or edit the literals in. The test suite runs the whole file against the seeded
database, so a query that stops being valid as the schema changes fails CI
rather than failing the first person who needs it at 3am.

## Two design notes

**Payload shape is a trigger, not a CHECK.** A `CHECK` constraint cannot
reference another table, so encoding the rules inline would mean hard-coding the
action names — and then adding a fifth action to `audit_action` would be
rejected by a constraint that had never heard of it. Instead `audit_action`
carries `has_before` and `has_after`, and one trigger compares each insert
against them. A new action type is added as data:

```sql
INSERT INTO audit_action (action, description, has_before, has_after)
VALUES ('archive', 'Entity moved to cold storage', 1, 1);
```

and its payload rules are enforced from that moment, with no schema change.
Both halves of that are tested.

**`AUTOINCREMENT`, not a bare rowid alias.** A plain `INTEGER PRIMARY KEY`
reuses the largest freed value, so ids could repeat after rows are removed. Rows
here are never removed, but the guarantee should not rest on that, and monotonic
ids are what makes "everything after id N" a meaningful query.

## Limitations, stated plainly

A connection that can run DDL can `DROP` the triggers, and nothing inside SQLite
prevents that. This schema stops application bugs and casual tampering — not an
attacker holding schema rights. Real tamper-evidence needs something outside the
database: append-only storage, off-host replication, or a signed hash chain.

A no-op `UPDATE` (one matching no rows) is not an error, because a `BEFORE
UPDATE` trigger fires per matching row and there are none. Nothing is modified.
The guarantee is that no existing row can change, not that the verb is unusable.

## Tests

```
bash tests/run.sh
```

49 checks: 23 positive assertions over the seeded views, 25 statements that must
be rejected with the right error, and one run of every query in `queries.sql`. Rejection cases each need their own
`sqlite3` invocation, since a raised error aborts the enclosing script.

## License

MIT
