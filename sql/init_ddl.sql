CREATE OR REPLACE VIEW events AS
SELECT
    tenant::VARCHAR AS tenant,
    session_id::VARCHAR AS session_id,
    event_date::TIMESTAMP AS event_date,
    event_index::INTEGER AS event_index,
    event_name::VARCHAR AS event_name,
    store_id_unified::VARCHAR AS store_id_unified,
    kiosk_id_up::VARCHAR AS kiosk_id_up,
    item_id_masked::VARCHAR AS item_id_masked,
    item_revenue::DOUBLE AS item_revenue
FROM read_csv_auto('data/dataset.csv.gz', header = true);
