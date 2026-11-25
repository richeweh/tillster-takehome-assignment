SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT session_id || '|' || CAST(event_index AS VARCHAR)) AS distinct_session_event_index, -- is there a repeat of session_id and event_index combined? 
    COUNT(*) - COUNT(DISTINCT session_id || '|' || CAST(event_index AS VARCHAR)) AS duplicate_pairs
FROM events;

-- Sessions that appear under more than one tenant / store / kiosk / date.
SELECT 'tenants_per_session' AS check_name, COUNT(*) AS sessions_with_multiple
FROM (
    SELECT session_id
    FROM events
    GROUP BY session_id
    HAVING COUNT(DISTINCT tenant) > 1
) t
UNION ALL
SELECT 'stores_per_session', COUNT(*)
FROM (
    SELECT session_id
    FROM events
    GROUP BY session_id
    HAVING COUNT(DISTINCT store_id_unified) > 1
) t
UNION ALL
SELECT 'kiosks_per_session', COUNT(*)
FROM (
    SELECT session_id
    FROM events
    GROUP BY session_id
    HAVING COUNT(DISTINCT kiosk_id_up) > 1
) t
UNION ALL
SELECT 'dates_per_session', COUNT(*)
FROM (
    SELECT session_id
    FROM events
    GROUP BY session_id
    HAVING COUNT(DISTINCT event_date) > 1
) t;