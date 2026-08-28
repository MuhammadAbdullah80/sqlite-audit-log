-- Queries you actually reach for during an incident.
--
-- Not loaded by schema.sql. Read one out when you need it:
--
--     sqlite3 audit.db ".read queries.sql"     -- runs them all against your data
--
-- or copy the one you want. Each is parameterised with :named placeholders
-- where a real investigation would substitute a value; run through .parameter
-- set, or edit the literal in.

.mode column
.headers on

-- ---------------------------------------------------------------------------
-- What happened to this thing?
-- ---------------------------------------------------------------------------

-- The full story of one entity, newest first. The first question, every time.
SELECT recorded_at, actor, action,
       json_extract(context_json, '$.request_id') AS request_id
FROM audit_log
WHERE entity_type = :entity_type
  AND entity_id   = :entity_id
ORDER BY id DESC;

-- What actually changed in each update, rather than the whole before/after
-- blob. json_each over the after state, filtered to keys whose value differs.
SELECT l.id, l.recorded_at, l.actor,
       a.key,
       json_extract(l.before_json, '$.' || a.key) AS was,
       a.value                                    AS now
FROM audit_log AS l
JOIN json_each(l.after_json) AS a
WHERE l.action = 'update'
  AND l.entity_type = :entity_type
  AND l.entity_id   = :entity_id
  AND json_extract(l.before_json, '$.' || a.key) IS NOT a.value
ORDER BY l.id DESC;

-- ---------------------------------------------------------------------------
-- Who did it?
-- ---------------------------------------------------------------------------

-- Everything one actor touched in a window.
SELECT recorded_at, action, entity_type, entity_id
FROM audit_log
WHERE actor = :actor
  AND recorded_at >= :since
ORDER BY id DESC;

-- Actors who deleted anything in the last day, busiest first. `recorded_at` is
-- ISO-8601 with a Z suffix, which sorts lexicographically, so a string
-- comparison against a computed timestamp is correct and stays index-friendly.
SELECT actor, COUNT(*) AS deletes, MIN(recorded_at) AS first, MAX(recorded_at) AS last
FROM audit_log
WHERE action = 'delete'
  AND recorded_at >= strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')
GROUP BY actor
ORDER BY deletes DESC;

-- An actor's deletes compared to their own normal rate. A number without a
-- baseline is not a signal - "40 deletes" only means something next to "they
-- average 2 a day".
WITH daily AS (
    SELECT actor,
           substr(recorded_at, 1, 10) AS day,
           SUM(action = 'delete')     AS deletes
    FROM audit_log
    GROUP BY actor, day
)
SELECT actor,
       day,
       deletes,
       ROUND(AVG(deletes) OVER (PARTITION BY actor), 2) AS actor_daily_avg
FROM daily
WHERE deletes > 0
ORDER BY deletes DESC;

-- ---------------------------------------------------------------------------
-- What state is everything in?
-- ---------------------------------------------------------------------------

-- Entities that exist right now, with their current state.
SELECT entity_type, entity_id, last_changed_at, last_actor, current_json
FROM audit_entity_live
ORDER BY last_changed_at DESC;

-- Entities that were deleted, and by whom. The row survives the entity.
SELECT entity_type, entity_id, last_changed_at AS deleted_at, last_actor AS deleted_by
FROM audit_entity_current
WHERE last_action = 'delete'
ORDER BY last_changed_at DESC;

-- Entities nobody has touched in 90 days.
SELECT entity_type, entity_id, last_changed_at, last_actor
FROM audit_entity_live
WHERE last_changed_at < strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-90 days')
ORDER BY last_changed_at;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Who has looked at an entity without changing it. For the "who saw this
-- record" question that access reviews ask.
SELECT actor, COUNT(*) AS reads, MAX(recorded_at) AS last_read
FROM audit_log
WHERE action = 'read'
  AND entity_type = :entity_type
  AND entity_id   = :entity_id
GROUP BY actor
ORDER BY reads DESC;

-- Actors who only ever read, never wrote. Useful for spotting service accounts
-- that were granted more than they use.
SELECT actor, events AS reads, first_seen, last_seen
FROM audit_actor_activity
WHERE creates = 0 AND updates = 0 AND deletes = 0 AND reads > 0
ORDER BY reads DESC;

-- ---------------------------------------------------------------------------
-- Volume
-- ---------------------------------------------------------------------------

-- Events per day per action, for a chart or a sanity check that logging is
-- still happening at all. A day that suddenly drops to zero usually means the
-- writer broke, not that everyone stopped working.
SELECT substr(recorded_at, 1, 10) AS day,
       COUNT(*)               AS events,
       SUM(action = 'create') AS creates,
       SUM(action = 'update') AS updates,
       SUM(action = 'delete') AS deletes,
       SUM(action = 'read')   AS reads
FROM audit_log
GROUP BY day
ORDER BY day DESC;

-- Busiest entity types.
SELECT entity_type,
       COUNT(*)                        AS events,
       COUNT(DISTINCT entity_id)       AS entities,
       COUNT(DISTINCT actor)           AS actors
FROM audit_log
GROUP BY entity_type
ORDER BY events DESC;

-- ---------------------------------------------------------------------------
-- Integrity
-- ---------------------------------------------------------------------------

-- Gaps in the id sequence. AUTOINCREMENT never reuses a value, and the triggers
-- refuse DELETE, so a gap means either a rolled-back transaction (benign, and
-- common) or that someone dropped the triggers and removed rows. It does not
-- prove tampering on its own - it is a prompt to go and look.
SELECT prev_id + 1 AS gap_starts, id - 1 AS gap_ends, id - prev_id - 1 AS missing
FROM (SELECT id, LAG(id) OVER (ORDER BY id) AS prev_id FROM audit_log)
WHERE prev_id IS NOT NULL
  AND id - prev_id > 1;

-- Rows whose recorded_at runs backwards against their id. Ids are monotonic, so
-- a later row with an earlier timestamp means someone passed an explicit
-- recorded_at - worth knowing, since the default is the one you can trust.
SELECT id, recorded_at, actor, action,
       prev_at AS previous_recorded_at
FROM (
    SELECT id, recorded_at, actor, action,
           LAG(recorded_at) OVER (ORDER BY id) AS prev_at
    FROM audit_log
)
WHERE prev_at IS NOT NULL
  AND recorded_at < prev_at;
