#!/usr/bin/env bash
# Test runner: bash tests/run.sh
#
# Two halves. tests/assertions.sql seeds a history and checks what the views
# report, printing "ok" or "FAIL" per line. The rejection cases live here
# instead, because a raised error aborts the enclosing SQL script - each one
# needs its own sqlite3 invocation.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0

# --- positive assertions ---------------------------------------------------

out="$(cd "$ROOT" && sqlite3 "$TMP/assert.db" ".read tests/assertions.sql" 2>&1)"
status=$?

if [ "$status" -ne 0 ]; then
	failed=$((failed + 1))
	printf 'FAIL assertions.sql exited %d\n%s\n' "$status" "$out"
else
	ok_count="$(printf '%s\n' "$out" | grep -c '^ok' || true)"
	bad_count="$(printf '%s\n' "$out" | grep -c '^FAIL' || true)"
	passed=$((passed + ok_count))
	if [ "$bad_count" -gt 0 ]; then
		failed=$((failed + bad_count))
		printf '%s\n' "$out" | grep '^FAIL'
	fi
fi

# --- rejection cases ------------------------------------------------------

# reject NAME EXPECTED_MESSAGE_SUBSTRING SQL
#
# Loads the schema into a fresh database, runs SQL, and requires sqlite3 to fail
# with a message containing EXPECTED_MESSAGE_SUBSTRING. A case that *succeeds*
# is a failure: the constraint it was probing is not doing its job.
reject() {
	local name="$1" want="$2" sql="$3" db out status
	db="$TMP/$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_').db"

	out="$(cd "$ROOT" && printf '.read schema.sql\n%s\n' "$sql" | sqlite3 "$db" 2>&1)"
	status=$?

	if [ "$status" -eq 0 ]; then
		failed=$((failed + 1))
		printf 'FAIL %s\n      statement was accepted but should have been rejected\n' "$name"
	elif printf '%s' "$out" | grep -qF -- "$want"; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n      want message containing: [%s]\n      got: %s\n' \
			"$name" "$want" "$out"
	fi
}

VALID_CREATE="INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
              VALUES ('ada', 'create', 'invoice', 'INV-1', '{\"total\":1}');"

# Append-only enforcement - the whole reason the table exists.
reject 'update is refused' 'append-only' \
	"$VALID_CREATE UPDATE audit_log SET actor = 'mallory' WHERE id = 1;"

reject 'delete is refused' 'append-only' \
	"$VALID_CREATE DELETE FROM audit_log WHERE id = 1;"

reject 'vocabulary rows cannot be deleted' 'referenced by history' \
	"DELETE FROM audit_action WHERE action = 'read';"

# Required fields.
reject 'a blank actor is refused' 'actor_not_blank' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('   ', 'create', 'invoice', 'INV-1', '{}');"

reject 'a blank entity_id is refused' 'entity_id_not_blank' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'create', 'invoice', '', '{}');"

reject 'a blank entity_type is refused' 'entity_type_not_blank' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'create', ' ', 'INV-1', '{}');"

reject 'a NULL actor is refused' 'NOT NULL' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES (NULL, 'create', 'invoice', 'INV-1', '{}');"

# Vocabulary.
reject 'an unknown action is refused' 'FOREIGN KEY' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'purge', 'invoice', 'INV-1', '{}');"

# Payload consistency - a log that contradicts itself is not evidence.
reject 'create with a before state is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json, after_json)
	 VALUES ('ada', 'create', 'invoice', 'INV-1', '{}', '{}');"

reject 'update without a before state is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'update', 'invoice', 'INV-1', '{}');"

reject 'update without an after state is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json)
	 VALUES ('ada', 'update', 'invoice', 'INV-1', '{}');"

reject 'delete with an after state is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json, after_json)
	 VALUES ('ada', 'delete', 'invoice', 'INV-1', '{}', '{}');"

reject 'delete without a before state is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id)
	 VALUES ('ada', 'delete', 'invoice', 'INV-1');"

reject 'read carrying a payload is refused' 'payload does not match action' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'read', 'invoice', 'INV-1', '{}');"

# JSON columns.
reject 'malformed after_json is refused' 'after_json_is_json' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'create', 'invoice', 'INV-1', '{not json');"

reject 'malformed before_json is refused' 'before_json_is_json' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json, after_json)
	 VALUES ('ada', 'update', 'invoice', 'INV-1', 'nope', '{}');"

reject 'malformed context_json is refused' 'context_json_is_json' \
	"INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json, context_json)
	 VALUES ('ada', 'create', 'invoice', 'INV-1', '{}', '[1,');"

# Timestamp format.
reject 'a non-ISO timestamp is refused' 'recorded_at_is_utc_iso8601' \
	"INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
	 VALUES ('01/02/2026', 'ada', 'create', 'invoice', 'INV-1', '{}');"

reject 'a timestamp without the Z suffix is refused' 'recorded_at_is_utc_iso8601' \
	"INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
	 VALUES ('2026-01-01T10:00:00', 'ada', 'create', 'invoice', 'INV-1', '{}');"

# This is why the constraint uses GLOB rather than LIKE: LIKE is
# case-insensitive for ASCII in SQLite and would accept both of these.
reject 'a lowercase date/time separator is refused' 'recorded_at_is_utc_iso8601' \
	"INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
	 VALUES ('2026-01-01t10:00:00.000Z', 'ada', 'create', 'invoice', 'INV-1', '{}');"

reject 'a lowercase zone suffix is refused' 'recorded_at_is_utc_iso8601' \
	"INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
	 VALUES ('2026-01-01T10:00:00.000z', 'ada', 'create', 'invoice', 'INV-1', '{}');"

reject 'an impossible month is refused' 'recorded_at_is_utc_iso8601' \
	"INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
	 VALUES ('2026-99-01T10:00:00.000Z', 'ada', 'create', 'invoice', 'INV-1', '{}');"

# --- documented behaviours -------------------------------------------------

# accept NAME EXPECTED_OUTPUT SQL - the statement must succeed and print
# EXPECTED_OUTPUT.
accept() {
	local name="$1" want="$2" sql="$3" db out status
	db="$TMP/ok_$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_').db"

	out="$(cd "$ROOT" && printf '.read schema.sql\n%s\n' "$sql" | sqlite3 "$db" 2>&1)"
	status=$?

	if [ "$status" -ne 0 ]; then
		failed=$((failed + 1))
		printf 'FAIL %s\n      statement was rejected: %s\n' "$name" "$out"
	elif [ "$out" = "$want" ]; then
		passed=$((passed + 1))
	else
		failed=$((failed + 1))
		printf 'FAIL %s\n      want output: [%s]\n      got:        [%s]\n' "$name" "$want" "$out"
	fi
}

# A BEFORE UPDATE trigger fires once per matching row, so an UPDATE that matches
# nothing never reaches it and is not an error. Nothing is modified either, so
# this is behaviour to know about rather than a hole: the guarantee is that no
# existing row can change, not that the verb is unusable.
accept 'a no-op UPDATE is permitted but changes nothing' 'ada' \
	"$VALID_CREATE
	 UPDATE audit_log SET actor = 'mallory' WHERE id = 999;
	 SELECT actor FROM audit_log;"

# The reason payload shape is a trigger reading audit_action rather than a CHECK
# constraint: a new action type is added as data and enforced immediately, with
# no schema change. A hard-coded CHECK would reject this insert.
accept 'a new action type can be added and used' 'archive|1' \
	"INSERT INTO audit_action (action, description, has_before, has_after)
	 VALUES ('archive', 'Entity moved to cold storage', 1, 1);
	 INSERT INTO audit_log (actor, action, entity_type, entity_id, before_json, after_json)
	 VALUES ('ada', 'archive', 'invoice', 'INV-1', '{\"hot\":1}', '{\"cold\":1}');
	 SELECT action, COUNT(*) FROM audit_log GROUP BY action;"

# ...and the new action's shape rules are enforced too.
reject 'a new action type has its payload rules enforced' 'payload does not match action' \
	"INSERT INTO audit_action (action, description, has_before, has_after)
	 VALUES ('archive', 'Entity moved to cold storage', 1, 1);
	 INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
	 VALUES ('ada', 'archive', 'invoice', 'INV-1', '{}');"

# --- the example queries all run -------------------------------------------

# queries.sql is documentation, and documentation that does not run rots. This
# executes every query in it against the seeded database and fails on any SQL
# error. It asserts nothing about the rows - the point is that the file stays
# valid as the schema changes.
qdb="$TMP/queries.db"
( cd "$ROOT" && sqlite3 "$qdb" ".read tests/assertions.sql" ) >/dev/null 2>&1

qout="$(cd "$ROOT" && sqlite3 "$qdb" 2>&1 <<'SQL'
.parameter set :entity_type 'invoice'
.parameter set :entity_id 'INV-1'
.parameter set :actor 'ada'
.parameter set :since '2026-01-01T00:00:00.000Z'
.bail on
.read queries.sql
SQL
)"
qstatus=$?

if [ "$qstatus" -eq 0 ] && ! printf '%s' "$qout" | grep -qiE '^(Parse error|Error|Runtime error)'; then
	passed=$((passed + 1))
else
	failed=$((failed + 1))
	printf 'FAIL queries.sql did not run cleanly
%s
' "$qout"
fi

# --- report ---------------------------------------------------------------

total=$((passed + failed))
if [ "$failed" -eq 0 ]; then
	printf 'all %d checks passed (sqlite %s)\n' "$total" "$(sqlite3 --version | cut -d' ' -f1)"
	exit 0
fi
printf '%d of %d checks FAILED\n' "$failed" "$total"
exit 1
