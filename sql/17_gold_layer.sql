-- =====================================================================
-- 17_gold_layer.sql -- the CFO review layer (REQ-103, BR-006)
--
-- Built deterministically, not by an agent, and the reason matters: the
-- first evaluation run exposed that BR-006 demanded a high-value flag while
-- the Silver data contract had no column for it and never named a layer.
-- The agent resolved that contradiction by inventing a HIGH_VALUE_FLAG
-- column on Silver, which would have breached the contract.
--
-- The fix was to the documentation, not the agent: BR-006 now states the
-- flag lives in Gold and that Silver is not extended with derived reporting
-- attributes. This file is that decision expressed as code.
--
-- Rates come from BR-NORM-001 and are frozen for the reporting year, so the
-- classification is reproducible and does not drift with live FX. They are
-- held in a table rather than inlined in a CASE so a rate change is a data
-- change with an audit trail.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA PIPELINE;

CREATE OR REPLACE TABLE FX_REFERENCE_RATES (
    CURRENCY_CODE  STRING NOT NULL PRIMARY KEY,
    RATE_TO_USD    NUMBER(12,6) NOT NULL,
    REPORTING_YEAR NUMBER NOT NULL,
    SOURCE_DOC     STRING
)
COMMENT = 'Frozen USD reference rates per BR-NORM-001. Not a live FX feed.';

INSERT INTO FX_REFERENCE_RATES (CURRENCY_CODE, RATE_TO_USD, REPORTING_YEAR, SOURCE_DOC)
SELECT v.c, v.r, 2025, 'BR-NORM-001'
FROM VALUES ('USD', 1.000000), ('EUR', 1.090000), ('GBP', 1.270000) AS v(c, r);

CREATE OR REPLACE TABLE GOLD_THRESHOLDS (
    THRESHOLD_NAME STRING NOT NULL PRIMARY KEY,
    THRESHOLD_VALUE NUMBER(18,2) NOT NULL,
    SOURCE_DOC STRING
);

INSERT INTO GOLD_THRESHOLDS (THRESHOLD_NAME, THRESHOLD_VALUE, SOURCE_DOC)
SELECT 'HIGH_VALUE_USD', 75000.00, 'PRD-AP-2025-001 BR-006';

-- ---------------------------------------------------------------------
-- Gold review layer. TARGET_LAG = DOWNSTREAM per STD-DT-002 so the chain is
-- pulled by demand rather than each layer polling on its own timer.
--
-- The join to FX_REFERENCE_RATES is an inner join on purpose: a currency with
-- no published rate must not silently produce an unflagged row. Silver already
-- restricts CURRENCY_CODE to the permitted set, and the ACCEPTED_VALUES test
-- covers that, so an unmatched currency here means the upstream control failed
-- and the row should be conspicuous by its absence rather than wrong.
-- ---------------------------------------------------------------------
CREATE OR REPLACE DYNAMIC TABLE GOLD_AP_INVOICE_REVIEW
    TARGET_LAG   = DOWNSTREAM
    WAREHOUSE    = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    INITIALIZE   = ON_CREATE
    COMMENT      = 'CFO review layer. HIGH_VALUE_FLAG per BR-006 using frozen BR-NORM-001 rates.'
AS
SELECT
    s.INVOICE_KEY,
    s.SOURCE_SYSTEM,
    s.SOURCE_INVOICE_ID,
    s.INVOICE_NUMBER,
    s.VENDOR_ID,
    s.VENDOR_NAME,
    s.INVOICE_DATE,
    s.DUE_DATE,
    s.INVOICE_AMOUNT,
    s.CURRENCY_CODE,
    (s.INVOICE_AMOUNT * f.RATE_TO_USD)::NUMBER(18,2) AS INVOICE_AMOUNT_USD,
    f.RATE_TO_USD                                    AS FX_RATE_APPLIED,
    (s.INVOICE_AMOUNT * f.RATE_TO_USD) >= t.THRESHOLD_VALUE AS HIGH_VALUE_FLAG,
    t.THRESHOLD_VALUE                                AS HIGH_VALUE_THRESHOLD_USD,
    s.PAYMENT_TERMS,
    s.APPROVAL_STATUS,
    s.COST_CENTER_OR_DEPT,
    s.GL_ACCOUNT,
    s.CREATED_AT
FROM CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES s
JOIN CAPSTONE_AI_DLC.PIPELINE.FX_REFERENCE_RATES f
  ON f.CURRENCY_CODE = s.CURRENCY_CODE
CROSS JOIN CAPSTONE_AI_DLC.PIPELINE.GOLD_THRESHOLDS t
WHERE t.THRESHOLD_NAME = 'HIGH_VALUE_USD';

-- Verify the achieved refresh mode. STD-DT-002 treats an unrequested FULL as a
-- defect rather than a warning.
SHOW DYNAMIC TABLES LIKE 'GOLD_AP_INVOICE_REVIEW' IN SCHEMA CAPSTONE_AI_DLC.PIPELINE;

SELECT SOURCE_SYSTEM,
       COUNT(*)                        AS invoices,
       COUNT_IF(HIGH_VALUE_FLAG)       AS high_value,
       MAX(INVOICE_AMOUNT_USD)         AS max_usd
FROM CAPSTONE_AI_DLC.PIPELINE.GOLD_AP_INVOICE_REVIEW
GROUP BY 1 ORDER BY 1;
