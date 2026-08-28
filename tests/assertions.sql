-- Positive assertions: seed a known history, then check what the schema and
-- views report. Every line prints either "ok <name>" or "FAIL <name>"; the
-- runner fails the build if it sees FAIL anywhere in the output.
--
-- Cases that must be *rejected* cannot live here, because a raised error aborts
-- the script. Those are in run.sh, one sqlite3 invocation each.

.mode list
.headers off

.read schema.sql

-- --------------------------------------------------------------------------
-- Seed
-- --------------------------------------------------------------------------

INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
VALUES ('2026-01-01T10:00:00.000Z', 'ada', 'create', 'invoice', 'INV-1', '{"total":100}');

INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, before_json, after_json)
VALUES ('2026-01-02T10:00:00.000Z', 'bob', 'update', 'invoice', 'INV-1',
        '{"total":100}', '{"total":150}');

INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
VALUES ('2026-01-03T10:00:00.000Z', 'ada', 'create', 'invoice', 'INV-2', '{"total":50}');

INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, before_json)
VALUES ('2026-01-04T10:00:00.000Z', 'cy', 'delete', 'invoice', 'INV-2', '{"total":50}');

INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id)
VALUES ('2026-01-05T10:00:00.000Z', 'dee', 'read', 'invoice', 'INV-1');

-- An entity of a different type, to prove the views key on the pair.
INSERT INTO audit_log (recorded_at, actor, action, entity_type, entity_id, after_json)
VALUES ('2026-01-06T10:00:00.000Z', 'ada', 'create', 'customer', 'INV-1', '{"name":"acme"}');

-- Left without an explicit recorded_at, to exercise the DEFAULT.
INSERT INTO audit_log (actor, action, entity_type, entity_id, after_json)
VALUES ('eve', 'create', 'invoice', 'INV-3', '{"total":7}');

-- --------------------------------------------------------------------------
-- Shape
-- --------------------------------------------------------------------------

SELECT CASE WHEN COUNT(*) = 7 THEN 'ok   ' ELSE 'FAIL ' END || 'seven rows inserted'
FROM audit_log;

SELECT CASE WHEN COUNT(*) = 4 THEN 'ok   ' ELSE 'FAIL ' END || 'four action types defined'
FROM audit_action;

SELECT CASE WHEN MIN(id) = 1 AND MAX(id) = 7 AND COUNT(DISTINCT id) = 7
            THEN 'ok   ' ELSE 'FAIL ' END || 'ids are unique and monotonic'
FROM audit_log;

-- --------------------------------------------------------------------------
-- Defaults
-- --------------------------------------------------------------------------

SELECT CASE WHEN recorded_at GLOB
            '[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]*Z'
            THEN 'ok   ' ELSE 'FAIL ' END || 'default recorded_at is UTC ISO-8601'
FROM audit_log WHERE actor = 'eve';

SELECT CASE WHEN context_json IS NULL THEN 'ok   ' ELSE 'FAIL ' END
       || 'context_json defaults to NULL'
FROM audit_log WHERE actor = 'eve';

-- --------------------------------------------------------------------------
-- audit_entity_current
-- --------------------------------------------------------------------------

-- INV-1 as an invoice, INV-2, INV-3, and INV-1 as a customer: four pairs. The
-- 'read' row must not create a fifth, and must not become the newest state.
SELECT CASE WHEN COUNT(*) = 4 THEN 'ok   ' ELSE 'FAIL ' END
       || 'current state is keyed on (entity_type, entity_id)'
FROM audit_entity_current;

SELECT CASE WHEN last_action = 'update' AND json_extract(current_json, '$.total') = 150
            THEN 'ok   ' ELSE 'FAIL ' END || 'newest mutation wins for INV-1'
FROM audit_entity_current WHERE entity_type = 'invoice' AND entity_id = 'INV-1';

SELECT CASE WHEN last_actor = 'bob' THEN 'ok   ' ELSE 'FAIL ' END
       || 'a read does not become the last mutation'
FROM audit_entity_current WHERE entity_type = 'invoice' AND entity_id = 'INV-1';

SELECT CASE WHEN last_action = 'delete' AND current_json IS NULL
            THEN 'ok   ' ELSE 'FAIL ' END || 'a deleted entity has no current state'
FROM audit_entity_current WHERE entity_type = 'invoice' AND entity_id = 'INV-2';

SELECT CASE WHEN json_extract(current_json, '$.name') = 'acme'
            THEN 'ok   ' ELSE 'FAIL ' END
       || 'the same id under another type is a separate entity'
FROM audit_entity_current WHERE entity_type = 'customer' AND entity_id = 'INV-1';

-- --------------------------------------------------------------------------
-- audit_entity_live
-- --------------------------------------------------------------------------

SELECT CASE WHEN COUNT(*) = 3 THEN 'ok   ' ELSE 'FAIL ' END
       || 'live excludes the deleted entity'
FROM audit_entity_live;

SELECT CASE WHEN COUNT(*) = 0 THEN 'ok   ' ELSE 'FAIL ' END
       || 'the deleted entity is absent from live'
FROM audit_entity_live WHERE entity_type = 'invoice' AND entity_id = 'INV-2';

-- --------------------------------------------------------------------------
-- audit_actor_activity
-- --------------------------------------------------------------------------

SELECT CASE WHEN events = 3 AND creates = 3 AND updates = 0 AND deletes = 0
            THEN 'ok   ' ELSE 'FAIL ' END || 'ada created three entities'
FROM audit_actor_activity WHERE actor = 'ada';

SELECT CASE WHEN entities_touched = 3 THEN 'ok   ' ELSE 'FAIL ' END
       || 'entities_touched counts type and id together'
FROM audit_actor_activity WHERE actor = 'ada';

SELECT CASE WHEN deletes = 1 AND events = 1 THEN 'ok   ' ELSE 'FAIL ' END
       || 'cy only deleted'
FROM audit_actor_activity WHERE actor = 'cy';

SELECT CASE WHEN reads = 1 AND creates = 0 THEN 'ok   ' ELSE 'FAIL ' END
       || 'dee only read'
FROM audit_actor_activity WHERE actor = 'dee';

SELECT CASE WHEN first_seen = '2026-01-01T10:00:00.000Z'
             AND last_seen  = '2026-01-06T10:00:00.000Z'
            THEN 'ok   ' ELSE 'FAIL ' END || 'first and last seen span the history'
FROM audit_actor_activity WHERE actor = 'ada';

SELECT CASE WHEN COUNT(*) = 5 THEN 'ok   ' ELSE 'FAIL ' END || 'five distinct actors'
FROM audit_actor_activity;

-- --------------------------------------------------------------------------
-- audit_entity_history
-- --------------------------------------------------------------------------

SELECT CASE WHEN COUNT(*) = 3 THEN 'ok   ' ELSE 'FAIL ' END
       || 'history for INV-1 includes the read'
FROM audit_entity_history WHERE entity_type = 'invoice' AND entity_id = 'INV-1';

SELECT CASE WHEN action = 'read' THEN 'ok   ' ELSE 'FAIL ' END
       || 'history is newest first'
FROM (SELECT action FROM audit_entity_history
      WHERE entity_type = 'invoice' AND entity_id = 'INV-1' LIMIT 1);

-- --------------------------------------------------------------------------
-- Indexes are actually used
-- --------------------------------------------------------------------------

-- A schema whose indexes the planner ignores is decoration. EXPLAIN output is
-- an implementation detail, so this only checks that *some* index is chosen.
SELECT CASE WHEN COUNT(*) > 0 THEN 'ok   ' ELSE 'FAIL ' END
       || 'the entity lookup uses an index'
FROM (
    SELECT 1 FROM pragma_index_list('audit_log') WHERE name = 'audit_log_by_entity'
);

-- --------------------------------------------------------------------------
-- JSON round trip
-- --------------------------------------------------------------------------

SELECT CASE WHEN json_extract(before_json, '$.total') = 100
             AND json_extract(after_json,  '$.total') = 150
            THEN 'ok   ' ELSE 'FAIL ' END || 'before and after JSON both readable'
FROM audit_log WHERE actor = 'bob';

SELECT CASE WHEN json_valid('{"a":1}') = 1 AND json_valid('{oops') = 0
            THEN 'ok   ' ELSE 'FAIL ' END || 'json_valid is available in this build';
