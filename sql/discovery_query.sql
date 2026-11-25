SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT tenant) AS unique_tenants_count, 
    COUNT(DISTINCT session_id) AS unique_sessions_count,
    COUNT(DISTINCT event_name) AS unique_event_names_count,
    COUNT(DISTINCT event_index) AS unique_event_indexes_count,
    COUNT(DISTINCT store_id_unified) AS unique_stores_count,
    COUNT(DISTINCT kiosk_id_up) AS unique_kiosks_count,
    COUNT(DISTINCT item_id_masked) AS unique_items_count, -- unique items count by id
    COALESCE(COUNT(item_revenue), 0) AS non_null_rows_revenue_count, -- count the rows where item_revenue is not null
    SUM(CASE WHEN item_revenue IS NOT NULL THEN item_revenue ELSE 0 END) AS non_null_revenue_sum
FROM events;


SELECT
    tenant,
    COUNT(*) AS rows,
    COUNT(DISTINCT session_id) AS sessions,
    COUNT(DISTINCT store_id_unified) AS unique_stores_count,
    COUNT(DISTINCT kiosk_id_up) AS unique_kiosks_count,
    COUNT(DISTINCT item_id_masked) AS unique_items_count, -- unique items count by id
    COALESCE(COUNT(item_revenue), 0) AS non_null_rows_revenue_count, -- count the rows where item_revenue is not null
    SUM(CASE WHEN item_revenue IS NOT NULL THEN item_revenue ELSE 0 END) AS non_null_revenue_sum, 
    MIN(event_date) AS min_date,
    MAX(event_date) AS max_date
FROM events
GROUP BY tenant
ORDER BY rows DESC;

/*
SELECT 
    DISTINCT event_name
    FROM events
    WHERE event_name IS NOT NULL; */