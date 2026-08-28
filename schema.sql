-- An append-only audit log for SQLite, enforced by the database rather than by
-- the application writing to it.
--
--   sqlite3 audit.db ".read schema.sql"
--
-- The point of an audit log is that it cannot be quietly rewritten. Application
-- code promising not to issue UPDATE is not an enforcement mechanism, so the
-- constraints below live in the schema: triggers reject UPDATE and DELETE
-- outright, and CHECK constraints reject rows that are internally inconsistent
-- at insert time rather than leaving them to be discovered during an incident.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Vocabulary
-- ---------------------------------------------------------------------------

-- A lookup table rather than a CHECK list, because a CHECK constraint cannot be
-- extended without rewriting the table, and new action types are a normal
-- evolution. WITHOUT ROWID: the table is its primary key and nothing else.
CREATE TABLE audit_action (
    action      TEXT PRIMARY KEY,
    description TEXT NOT NULL,

    -- Whether this action is expected to carry a before/after payload. The
    -- payload_matches_action constraint on audit_log reads the same rules, but
    -- stated here they are documentation rather than a wall of boolean logic.
    has_before  INTEGER NOT NULL CHECK (has_before IN (0, 1)),
    has_after   INTEGER NOT NULL CHECK (has_after  IN (0, 1))
) WITHOUT ROWID;

INSERT INTO audit_action (action, description, has_before, has_after) VALUES
    ('create', 'Entity came into existence',        0, 1),
    ('update', 'Entity changed',                    1, 1),
    ('delete', 'Entity was removed',                1, 0),
    ('read',   'Entity was accessed, no mutation',  0, 0);

-- ---------------------------------------------------------------------------
-- The log
-- ---------------------------------------------------------------------------

CREATE TABLE audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,

    -- AUTOINCREMENT rather than a plain INTEGER PRIMARY KEY: a bare rowid
    -- alias reuses the largest freed value, so ids could repeat after rows are
    -- removed. Rows here are never removed, but the guarantee should not rest
    -- on that, and monotonic ids are what makes "everything after id N" a
    -- meaningful query.

    recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ')),
    actor       TEXT NOT NULL,
    action      TEXT NOT NULL REFERENCES audit_action (action),
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,

    -- The state either side of the change, as JSON. NULL means "not applicable
    -- to this action", never "unknown".
    before_json TEXT,
    after_json  TEXT,

    -- Free-form context: request id, source IP, ticket reference.
    context_json TEXT,

    CONSTRAINT actor_not_blank
        CHECK (length(trim(actor)) > 0),
    CONSTRAINT entity_type_not_blank
        CHECK (length(trim(entity_type)) > 0),
    CONSTRAINT entity_id_not_blank
        CHECK (length(trim(entity_id)) > 0),

    -- GLOB, not LIKE: LIKE is case-insensitive for ASCII by default in SQLite,
    -- which would accept a lowercase 't' separator and a lowercase 'z' suffix.
    CONSTRAINT recorded_at_is_utc_iso8601
        CHECK (recorded_at GLOB
            '[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]*Z'),

    CONSTRAINT before_json_is_json
        CHECK (before_json IS NULL OR json_valid(before_json)),
    CONSTRAINT after_json_is_json
        CHECK (after_json IS NULL OR json_valid(after_json)),
    CONSTRAINT context_json_is_json
        CHECK (context_json IS NULL OR json_valid(context_json))

    -- Payload shape is validated by the audit_log_payload_matches_action
    -- trigger below, not by a CHECK constraint here. A CHECK cannot reference
    -- another table, so stating the rules inline would mean hard-coding the
    -- four action names - and then adding a fifth action to audit_action would
    -- be rejected by a constraint that had never heard of it, which defeats the
    -- point of having a lookup table at all.
);

-- ---------------------------------------------------------------------------
-- Payload consistency
-- ---------------------------------------------------------------------------

-- An 'update' with no before state, or a 'create' that claims a previous state,
-- is a bug in the caller. Rejecting it at insert time is much of the value of
-- the table: a log that contradicts itself is not evidence of anything.
--
-- The expected shape comes from audit_action, so a new action type is described
-- once, in data, and enforced without touching this trigger.
--
-- `NEW.before_json IS NOT NULL` evaluates to 1 or 0, which compares directly
-- against the 0/1 has_before column. When the action is unknown the subquery
-- yields NULL, the WHERE does not fire, and the foreign key rejects the row
-- instead - with a message about the actual problem.
CREATE TRIGGER audit_log_payload_matches_action
BEFORE INSERT ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'payload does not match action: see audit_action.has_before/has_after')
    WHERE (
        SELECT (a.has_before <> (NEW.before_json IS NOT NULL))
            OR (a.has_after  <> (NEW.after_json  IS NOT NULL))
        FROM audit_action AS a
        WHERE a.action = NEW.action
    );
END;

-- ---------------------------------------------------------------------------
-- Append-only enforcement
-- ---------------------------------------------------------------------------

-- BEFORE triggers, so the abort happens before any page is dirtied.
--
-- Honest limitation: a connection able to run DDL can DROP these triggers, and
-- nothing inside SQLite prevents that. They stop application bugs and casual
-- tampering, not an attacker with schema rights. Real tamper-evidence needs
-- something outside the database - append-only storage, off-host replication,
-- or a signed hash chain.

CREATE TRIGGER audit_log_no_update
BEFORE UPDATE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log is append-only: UPDATE is not permitted');
END;

CREATE TRIGGER audit_log_no_delete
BEFORE DELETE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log is append-only: DELETE is not permitted');
END;

-- The vocabulary is referenced by every log row, so retiring an action would
-- orphan history. Adding rows stays allowed.
CREATE TRIGGER audit_action_no_delete
BEFORE DELETE ON audit_action
BEGIN
    SELECT RAISE(ABORT, 'audit_action rows are referenced by history: DELETE is not permitted');
END;

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- "What happened to this entity, newest first" is the query an incident starts
-- with, so it gets a covering order rather than a sort.
CREATE INDEX audit_log_by_entity
    ON audit_log (entity_type, entity_id, id DESC);

-- "What did this actor do" is the second question.
CREATE INDEX audit_log_by_actor
    ON audit_log (actor, id DESC);

-- Time-range scans for reporting.
CREATE INDEX audit_log_by_time
    ON audit_log (recorded_at);

-- Mutations are the minority of rows in a log that records reads, and the
-- current-state view only looks at those. A partial index keeps it small.
CREATE INDEX audit_log_mutations
    ON audit_log (entity_type, entity_id, id DESC)
    WHERE action IN ('create', 'update', 'delete');

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- The newest mutation per entity, with the state it left behind. current_json
-- is NULL for an entity whose last mutation was a delete, which is why
-- last_action is exposed alongside it - NULL alone cannot distinguish "deleted"
-- from "never had a payload".
CREATE VIEW audit_entity_current AS
SELECT
    l.entity_type,
    l.entity_id,
    l.action      AS last_action,
    l.recorded_at AS last_changed_at,
    l.actor       AS last_actor,
    l.after_json  AS current_json,
    l.id          AS last_log_id
FROM audit_log AS l
JOIN (
    SELECT entity_type, entity_id, MAX(id) AS id
    FROM audit_log
    WHERE action IN ('create', 'update', 'delete')
    GROUP BY entity_type, entity_id
) AS newest
  ON newest.id = l.id;

-- Entities that currently exist, i.e. whose last mutation was not a delete.
CREATE VIEW audit_entity_live AS
SELECT * FROM audit_entity_current WHERE last_action <> 'delete';

-- Per-actor activity summary, for spotting the account that suddenly started
-- deleting things.
CREATE VIEW audit_actor_activity AS
SELECT
    actor,
    COUNT(*)                                            AS events,
    SUM(action = 'create')                              AS creates,
    SUM(action = 'update')                              AS updates,
    SUM(action = 'delete')                              AS deletes,
    SUM(action = 'read')                                AS reads,
    MIN(recorded_at)                                    AS first_seen,
    MAX(recorded_at)                                    AS last_seen,
    COUNT(DISTINCT entity_type || char(31) || entity_id) AS entities_touched
FROM audit_log
GROUP BY actor;

-- Every recorded change to one entity, newest first. Parameterise by binding
-- :entity_type and :entity_id, or filter the view.
CREATE VIEW audit_entity_history AS
SELECT
    entity_type,
    entity_id,
    id,
    recorded_at,
    actor,
    action,
    before_json,
    after_json,
    context_json
FROM audit_log
ORDER BY entity_type, entity_id, id DESC;
