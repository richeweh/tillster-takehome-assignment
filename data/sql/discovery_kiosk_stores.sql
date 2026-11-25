SELECT
    tenant,
    store_id_unified,
    kiosk_id_up
FROM events
GROUP BY tenant, store_id_unified, kiosk_id_up
ORDER BY tenant, store_id_unified, kiosk_id_up;

SELECT
    tenant,
    store_id_unified,
    COUNT(DISTINCT kiosk_id_up) AS kiosk_id_up_count,
    ROUND(AVG(item_revenue), 1) AS avg_item_revenue,
   ROUND(SUM(item_revenue), 1) AS total_item_revenue
FROM events
GROUP BY tenant, store_id_unified
ORDER BY tenant, total_item_revenue DESC, kiosk_id_up_count DESC,store_id_unified,  avg_item_revenue DESC;

SELECT 
   COUNT(DISTINCT kiosk_id_up) AS kiosk_id_up_count   -- count the number of unique kiosk_id_up
FROM events
GROUP BY kiosk_id_up
HAVING COUNT(DISTINCT store_id_unified) > 1 -- how many of the counted kiosk_id_up have more than one store_id_unified ... the result should be 0



/*
SELECT
    DISTINCT store_id_unified,
    kiosk_id_up,
    event_name,
    item_revenue
FROM events
GROUP BY store_id_unified, kiosk_id_up, event_name, item_revenue
ORDER BY store_id_unified, kiosk_id_up, event_name, item_revenue; */