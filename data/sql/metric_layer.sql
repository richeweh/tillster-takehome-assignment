-- Metric tables for the question app.
-- Definitions match the notebook: a session is one session_id inside one tenant,
-- a funnel step is presence of that event_name, and item_revenue stays inside one tenant.
-- Run data/sql/init_ddl.sql first. These drops let that pair be run again
-- in the same session. The raw events view is dropped at the end.
-- The app allows SELECT against these tables only.

DROP TABLE IF EXISTS conversion_by_tenant;
DROP TABLE IF EXISTS session_segments;
DROP TABLE IF EXISTS basket_by_tenant;
DROP TABLE IF EXISTS store_metrics;
DROP TABLE IF EXISTS step_loss;
DROP TABLE IF EXISTS funnel_by_tenant;
DROP TABLE IF EXISTS daily_metrics;
DROP TABLE IF EXISTS tenant_summary;
DROP TABLE IF EXISTS file_inventory;
DROP TABLE IF EXISTS metric_notes;
DROP TABLE IF EXISTS session_flags;

CREATE TABLE session_flags AS
SELECT
    tenant,
    session_id,
    MIN(store_id_unified) AS store_id,
    MIN(kiosk_id_up) AS kiosk_id,
    MIN(CAST(event_date AS DATE)) AS first_date,
    MAX(event_name = 'view_item_list') AS viewed,
    MAX(event_name = 'select_item') AS selected,
    MAX(event_name = 'add_to_cart') AS carted,
    MAX(event_name = 'purchase') AS purchased,
    COUNT(*) FILTER (WHERE event_name = 'purchase') AS purchase_rows,
    COALESCE(SUM(item_revenue) FILTER (WHERE event_name = 'purchase'), 0) AS purchase_revenue
FROM events
GROUP BY tenant, session_id;

CREATE TABLE file_inventory AS
SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT session_id) AS sessions,
    COUNT(DISTINCT tenant) AS tenants,
    COUNT(DISTINCT store_id_unified) AS stores,
    COUNT(DISTINCT kiosk_id_up) AS kiosks,
    COUNT(DISTINCT item_id_masked) AS items,
    COUNT(DISTINCT event_name) AS event_names,
    MIN(CAST(event_date AS DATE)) AS min_date,
    MAX(CAST(event_date AS DATE)) AS max_date,
    COUNT(item_revenue) AS revenue_rows
FROM events;

CREATE TABLE tenant_summary AS
WITH sess AS (
    SELECT
        tenant,
        COUNT(*) AS sessions,
        COUNT(*) FILTER (WHERE viewed) AS sessions_viewed,
        COUNT(*) FILTER (WHERE selected) AS sessions_selected,
        COUNT(*) FILTER (WHERE carted) AS sessions_carted,
        COUNT(*) FILTER (WHERE purchased) AS sessions_purchased,
        COUNT(*) FILTER (WHERE purchased) * 1.0 / NULLIF(COUNT(*), 0) AS purchase_rate
    FROM session_flags
    GROUP BY tenant
),
rev AS (
    SELECT
        tenant,
        SUM(item_revenue) AS item_revenue_all_rows,
        MIN(CAST(event_date AS DATE)) AS min_date,
        MAX(CAST(event_date AS DATE)) AS max_date
    FROM events
    GROUP BY tenant
)
SELECT
    s.tenant,
    s.sessions,
    s.sessions_viewed,
    s.sessions_selected,
    s.sessions_carted,
    s.sessions_purchased,
    s.purchase_rate,
    r.min_date,
    r.max_date,
    r.item_revenue_all_rows,
    'tenant-specific, not comparable across tenants' AS revenue_unit
FROM sess s
JOIN rev r USING (tenant)
ORDER BY s.tenant;

CREATE TABLE daily_metrics AS
SELECT
    CAST(event_date AS DATE) AS event_date,
    tenant,
    COUNT(DISTINCT session_id) AS sessions,
    SUM(item_revenue) AS item_revenue_all_rows,
    'tenant-specific, not comparable across tenants' AS revenue_unit
FROM events
GROUP BY 1, 2
ORDER BY 1, 2;

CREATE TABLE funnel_by_tenant AS
WITH counts AS (
    SELECT
        tenant,
        COUNT(*) AS sessions,
        COUNT(*) FILTER (WHERE viewed) AS viewed,
        COUNT(*) FILTER (WHERE selected) AS selected,
        COUNT(*) FILTER (WHERE carted) AS carted,
        COUNT(*) FILTER (WHERE purchased) AS purchased
    FROM session_flags
    GROUP BY tenant
)
SELECT
    tenant,
    0 AS step_order,
    'all_sessions' AS step_name,
    sessions AS sessions_reached,
    1.0 AS share_of_sessions
FROM counts
UNION ALL
SELECT tenant, 1, 'view_item_list', viewed, viewed * 1.0 / NULLIF(sessions, 0) FROM counts
UNION ALL
SELECT tenant, 2, 'select_item', selected, selected * 1.0 / NULLIF(sessions, 0) FROM counts
UNION ALL
SELECT tenant, 3, 'add_to_cart', carted, carted * 1.0 / NULLIF(sessions, 0) FROM counts
UNION ALL
SELECT tenant, 4, 'purchase', purchased, purchased * 1.0 / NULLIF(sessions, 0) FROM counts
ORDER BY 1, 2;

CREATE TABLE step_loss AS
WITH counts AS (
    SELECT
        tenant,
        COUNT(*) FILTER (WHERE viewed) AS viewed,
        COUNT(*) FILTER (WHERE selected) AS selected,
        COUNT(*) FILTER (WHERE carted) AS carted,
        COUNT(*) FILTER (WHERE purchased) AS purchased
    FROM session_flags
    GROUP BY tenant
)
SELECT
    tenant,
    'view_to_select' AS handoff,
    viewed AS sessions_at_prior_step,
    selected AS sessions_at_next_step,
    selected * 1.0 / NULLIF(viewed, 0) AS retained_rate,
    1 - selected * 1.0 / NULLIF(viewed, 0) AS lost_rate
FROM counts
UNION ALL
SELECT
    tenant,
    'select_to_cart',
    selected,
    carted,
    carted * 1.0 / NULLIF(selected, 0),
    1 - carted * 1.0 / NULLIF(selected, 0)
FROM counts
UNION ALL
SELECT
    tenant,
    'cart_to_purchase',
    carted,
    purchased,
    purchased * 1.0 / NULLIF(carted, 0),
    1 - purchased * 1.0 / NULLIF(carted, 0)
FROM counts
ORDER BY 1, 2;

CREATE TABLE store_metrics AS
WITH sess AS (
    SELECT
        tenant,
        store_id,
        COUNT(DISTINCT kiosk_id) AS kiosk_count,
        COUNT(*) AS sessions,
        COUNT(*) FILTER (WHERE purchased) AS purchased_sessions,
        COUNT(*) FILTER (WHERE purchased) * 1.0 / NULLIF(COUNT(*), 0) AS purchase_rate
    FROM session_flags
    GROUP BY tenant, store_id
),
rev AS (
    SELECT
        tenant,
        store_id_unified AS store_id,
        SUM(item_revenue) AS item_revenue_all_rows
    FROM events
    GROUP BY 1, 2
)
SELECT
    s.tenant,
    s.store_id,
    s.kiosk_count,
    s.sessions,
    s.purchased_sessions,
    s.purchase_rate,
    r.item_revenue_all_rows,
    'tenant-specific, not comparable across tenants' AS revenue_unit
FROM sess s
LEFT JOIN rev r USING (tenant, store_id)
ORDER BY s.tenant, s.purchase_rate;

CREATE TABLE basket_by_tenant AS
WITH buyers AS (
    SELECT
        tenant,
        COUNT(*) FILTER (WHERE purchased) AS buying_sessions,
        SUM(purchase_rows) * 1.0 / NULLIF(COUNT(*) FILTER (WHERE purchased), 0) AS items_per_buying_session,
        SUM(purchase_revenue) * 1.0 / NULLIF(COUNT(*) FILTER (WHERE purchased), 0) AS revenue_per_buying_session
    FROM session_flags
    GROUP BY tenant
),
prices AS (
    SELECT
        tenant,
        MEDIAN(item_revenue) AS median_purchase_item_revenue
    FROM events
    WHERE event_name = 'purchase' AND item_revenue IS NOT NULL
    GROUP BY tenant
)
SELECT
    b.tenant,
    b.buying_sessions,
    b.items_per_buying_session,
    b.revenue_per_buying_session,
    p.median_purchase_item_revenue,
    'median price and revenue-per-session use a tenant-specific unit' AS revenue_unit
FROM buyers b
JOIN prices p USING (tenant)
ORDER BY b.tenant;

-- Primary conversion metric. Denominator is written once: all sessions for that tenant
-- (or all sessions at that store / kiosk). Numerator is sessions with at least one purchase.
CREATE TABLE conversion_by_tenant AS
SELECT
    tenant,
    sessions,
    sessions_purchased AS purchased_sessions,
    purchase_rate AS purchase_conversion,
    'purchased_sessions / all sessions for that tenant' AS denominator
FROM tenant_summary
ORDER BY tenant;

CREATE TABLE session_segments AS
SELECT
    tenant,
    COUNT(*) AS sessions,
    COUNT(*) FILTER (WHERE purchased) AS purchased,
    COUNT(*) FILTER (WHERE purchased) * 1.0 / NULLIF(COUNT(*), 0) AS purchased_share,
    COUNT(*) FILTER (WHERE carted AND NOT purchased) AS cart_no_buy,
    COUNT(*) FILTER (WHERE carted AND NOT purchased) * 1.0 / NULLIF(COUNT(*), 0) AS cart_no_buy_share,
    COUNT(*) FILTER (WHERE NOT carted AND NOT purchased) AS browse,
    COUNT(*) FILTER (WHERE NOT carted AND NOT purchased) * 1.0 / NULLIF(COUNT(*), 0) AS browse_share,
    COUNT(*) FILTER (WHERE carted) AS reached_cart,
    COUNT(*) FILTER (WHERE carted AND NOT purchased) * 1.0 / NULLIF(COUNT(*) FILTER (WHERE carted), 0) AS cart_abandon_rate
FROM session_flags
GROUP BY tenant
ORDER BY tenant;

CREATE TABLE metric_notes (
    topic VARCHAR,
    definition VARCHAR
);

INSERT INTO metric_notes VALUES
(
    'session',
    'One session_id inside one tenant. A session does not cross a tenant, a store, or a kiosk. There is no guest id, so a session is one visit, not a customer who comes back.'
),
(
    'purchase_conversion',
    'Primary conversion. Numerator: sessions with at least one purchase. Denominator: all sessions for that tenant (or all sessions at that store / kiosk). Same formula for both tenants. companion rates live in funnel_by_tenant and step_loss.'
),
(
    'funnel_step',
    'A session reaches a step when that event_name appears at least once. The steps, in order, are view_item_list, select_item, add_to_cart, and purchase. share_of_sessions is sessions that reached the step divided by all sessions for that tenant. The check is presence, not event_index order.'
),
(
    'step_loss',
    'lost_rate is sessions that reached the prior step but not the next, divided by sessions at the prior step. The handoffs are view_to_select, select_to_cart, and cart_to_purchase.'
),
(
    'purchase_rate',
    'Alias of purchase_conversion. Sessions with a purchase divided by all sessions. For a store, the denominator is sessions at that store. More kiosks are not a higher rate.'
),
(
    'in_session_abandonment',
    'Substitute for customer churn. cart_abandon_rate is sessions that carted and did not purchase, divided by sessions that carted. Refuse guest churn, retention, RFM, and LTV.'
),
(
    'session_segments',
    'browse = never carted and never purchased. cart_no_buy = carted and never purchased. purchased = at least one purchase. Act on store_id and kiosk_id, not on a person. RFM and LTV need a guest id.'
),
(
    'item_revenue',
    'item_revenue_all_rows is SUM(item_revenue) on every event row, which is the daily-chart revenue. median_purchase_item_revenue is the median item_revenue on purchase rows only. Both use a tenant-specific price unit. Do not rank tenants, or a store in one tenant against a store in the other, by either column.'
),
(
    'basket',
    'items_per_buying_session is purchase rows in sessions that purchased, divided by those sessions. revenue_per_buying_session is purchase_revenue in those sessions, divided by those sessions.'
),
(
    'out_of_scope',
    'Customer churn, repeat visits, guest retention, subscriptions, RFM, and lifetime value are not in this file. Refuse those questions.'
);

DROP VIEW events;
DROP TABLE session_flags;
