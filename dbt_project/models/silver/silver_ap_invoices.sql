{{
    config(
        materialized = 'dynamic_table',
        snowflake_warehouse = 'COMPUTE_WH',
        target_lag = '60 minutes',
        refresh_mode = 'INCREMENTAL',
        on_configuration_change = 'apply'
    )
}}

-- Conformed AP invoice fact. UNION ALL is mandatory: PRD-AP-2025-001 BR-002 and
-- STD-SQL-001 both record that a distinct-based union silently dropped 4% of
-- rows when two sources legitimately shared an invoice number.
--
-- Workday is deliberately absent. It is blocked pending a Data Processing
-- Agreement and must not be scheduled or materialised.

SELECT * FROM {{ ref('stg_sap_ap_invoices') }}
UNION ALL
SELECT * FROM {{ ref('stg_oracle_ap_invoices') }}
UNION ALL
SELECT * FROM {{ ref('stg_baan_ap_invoices') }}
