WITH session_identity AS (
    SELECT 
        session_id, 
        COUNT(DISTINCT event_date) AS date_count, 
        DATE_DIFF('day', MIN(event_date), MAX(event_date)) AS day_span
    FROM events
    GROUP BY session_id
)

SELECT
    COUNT(*) AS sessions,
    COUNT(CASE WHEN date_count > 1 THEN 1 ELSE NULL END) AS sessions_spanning_multiple_dates,
    MAX(day_span) AS max_day_span
FROM session_identity;

SELECT 
    DISTINCT event_date,
    tenant,
    COUNT(*) event_rows,
    COUNT(DISTINCT session_id) AS unique_sessions,
    COUNT(DISTINCT item_revenue) AS unique_item_revenues,
    SUM(item_revenue) AS total_item_revenue
FROM events
GROUP BY event_date, tenant
ORDER BY event_date, tenant;