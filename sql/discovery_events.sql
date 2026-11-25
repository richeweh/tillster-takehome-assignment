SELECT 
    DISTINCT session_id,
--  kiosk_id_up, -- this can be left out as it is not an event nor a 
    event_index,
    event_name,
    COUNT(event_name) AS event_count,
--  item_revenue, -- this can be left out as it is not an event nor a session identifier
    event_date
FROM events
GROUP BY session_id, event_index, event_name, event_date
ORDER BY session_id, event_index, event_count DESC;