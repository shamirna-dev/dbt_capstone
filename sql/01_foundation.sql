-- =====================================================================
-- CAPSTONE: AI-Accelerated Data SDLC/STLC Platform on Snowflake
-- 01_foundation.sql  -- database, schemas, domain seed, run log
--
-- Idempotent: safe to re-run.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS CAPSTONE_AI_DLC
  COMMENT = 'AI-Accelerated Data SDLC/STLC platform - L2 AI-Augmented SDLC capstone';

USE DATABASE CAPSTONE_AI_DLC;

CREATE SCHEMA IF NOT EXISTS GOVERNANCE COMMENT = 'RAG knowledge base: governing docs, chunks, search service';
CREATE SCHEMA IF NOT EXISTS AGENTS     COMMENT = 'Agent stored procedures and the shared run harness';
CREATE SCHEMA IF NOT EXISTS ARTIFACTS  COMMENT = 'Agent outputs: user stories, generated code, test cases, defects';
CREATE SCHEMA IF NOT EXISTS METRICS    COMMENT = 'Run log, evaluation results, SDLC metric views';
CREATE SCHEMA IF NOT EXISTS PIPELINE   COMMENT = 'The data pipeline under construction (AP invoices)';
CREATE SCHEMA IF NOT EXISTS APP        COMMENT = 'Streamlit dashboard';

DROP SCHEMA IF EXISTS PUBLIC;

-- ---------------------------------------------------------------------
-- Platform configuration. Single source of truth for model choice so the
-- whole platform can be repointed at a different LLM in one UPDATE.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS GOVERNANCE.PLATFORM_CONFIG (
    CONFIG_KEY    STRING NOT NULL PRIMARY KEY,
    CONFIG_VALUE  STRING NOT NULL,
    DESCRIPTION   STRING,
    UPDATED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

MERGE INTO GOVERNANCE.PLATFORM_CONFIG t
USING (
    SELECT * FROM VALUES
      ('DEFAULT_MODEL',       'claude-sonnet-4-5',            'LLM used by all generation agents'),
      ('JUDGE_MODEL',         'claude-sonnet-4-5',            'LLM used as judge in the eval harness'),
      ('EMBED_MODEL',         'snowflake-arctic-embed-l-v2.0','Embedding model for the knowledge base'),
      ('RAG_TOP_K',           '5',                            'Chunks retrieved per agent call'),
      ('CREDITS_PER_M_TOKEN', '1.7',                          'Approx credits per 1M tokens - used for cost attribution only'),
      ('CREDIT_USD',          '3.00',                         'USD per credit - adjust to your contract rate')
    AS v(CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
) s ON t.CONFIG_KEY = s.CONFIG_KEY
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION)
     VALUES (s.CONFIG_KEY, s.CONFIG_VALUE, s.DESCRIPTION);

CREATE OR REPLACE FUNCTION GOVERNANCE.CFG(P_KEY STRING)
RETURNS STRING
COMMENT = 'Reads a platform config value. Errors loudly (NULL) if the key is absent.'
AS $$ SELECT CONFIG_VALUE FROM CAPSTONE_AI_DLC.GOVERNANCE.PLATFORM_CONFIG WHERE CONFIG_KEY = P_KEY $$;

-- ---------------------------------------------------------------------
-- Agent run log. Every agent invocation lands here regardless of outcome.
-- This is the audit trail that makes generated artifacts defensible:
-- prompt, retrieved citations, model, tokens, cost, latency, status.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS METRICS.AGENT_RUN_LOG (
    RUN_ID            STRING        NOT NULL PRIMARY KEY,
    AGENT_NAME        STRING        NOT NULL,
    SDLC_PHASE        STRING,                    -- REQUIREMENTS | DESIGN | BUILD | TEST_DATA | QA | OPERATIONS
    INPUT_REF         STRING,                    -- what it was asked about
    INPUT_PAYLOAD     VARIANT,
    RETRIEVED_CHUNKS  ARRAY,                     -- chunk ids used for grounding (RAG citation trail)
    PROMPT_TEXT       STRING,
    MODEL_NAME        STRING,
    RESPONSE_RAW      STRING,
    OUTPUT_REF        STRING,                    -- artifact id produced
    STATUS            STRING        NOT NULL,    -- SUCCESS | FAILED | REJECTED
    ERROR_MESSAGE     STRING,
    PROMPT_TOKENS     NUMBER,
    COMPLETION_TOKENS NUMBER,
    TOTAL_TOKENS      NUMBER,
    EST_CREDITS       FLOAT,
    EST_USD           FLOAT,
    LATENCY_MS        NUMBER,
    ORCHESTRATOR      STRING,                    -- N8N | SNOWFLAKE_TASK | MANUAL
    STARTED_AT        TIMESTAMP_NTZ NOT NULL,
    ENDED_AT          TIMESTAMP_NTZ
);

-- ---------------------------------------------------------------------
-- Domain seed. Copy the AP invoice bronze tables from COCO_WORKSHOP so
-- the capstone is self-contained and the source of truth is not mutated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE PIPELINE.BRONZE_SAP_AP_INVOICES     AS SELECT * FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_SAP_AP_INVOICES;
CREATE OR REPLACE TABLE PIPELINE.BRONZE_ORACLE_AP_INVOICES  AS SELECT * FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_ORACLE_AP_INVOICES;
CREATE OR REPLACE TABLE PIPELINE.BRONZE_BAAN_AP_INVOICES    AS SELECT * FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_BAAN_AP_INVOICES;
CREATE OR REPLACE TABLE PIPELINE.BRONZE_WORKDAY_AP_INVOICES AS SELECT * FROM COCO_WORKSHOP.SOURCE_DATA.BRONZE_WORKDAY_AP_INVOICES;

-- Target contract for the Silver layer. The scaffolding and test agents read
-- this table rather than being told the shape in a prompt - metadata-driven,
-- which is the whole point of the accelerator.
CREATE OR REPLACE TABLE GOVERNANCE.TARGET_CONTRACT (
    TARGET_TABLE   STRING  NOT NULL,
    COLUMN_NAME    STRING  NOT NULL,
    DATA_TYPE      STRING  NOT NULL,
    IS_REQUIRED    BOOLEAN NOT NULL,
    IS_BUSINESS_KEY BOOLEAN DEFAULT FALSE,
    DESCRIPTION    STRING,
    ALLOWED_VALUES ARRAY,
    ORDINAL        NUMBER  NOT NULL,
    PRIMARY KEY (TARGET_TABLE, COLUMN_NAME)
);

-- Note: ALLOWED_VALUES is built with a CASE over a delimited string rather than
-- inline ARRAY_CONSTRUCT/NULL mixing, which Snowflake cannot type-infer inside
-- a VALUES clause.
INSERT INTO GOVERNANCE.TARGET_CONTRACT
  (TARGET_TABLE, COLUMN_NAME, DATA_TYPE, IS_REQUIRED, IS_BUSINESS_KEY, DESCRIPTION, ALLOWED_VALUES, ORDINAL)
SELECT
    v.tbl, v.col, v.dtype, v.req, v.bkey, v.descr,
    CASE WHEN v.allowed IS NULL THEN NULL ELSE SPLIT(v.allowed, ',') END,
    v.ord
FROM VALUES
  ('SILVER_AP_INVOICES','INVOICE_KEY','STRING',TRUE,TRUE,'Deterministic surrogate key: SOURCE_SYSTEM || source invoice id',NULL,1),
  ('SILVER_AP_INVOICES','SOURCE_SYSTEM','STRING',TRUE,FALSE,'Originating ERP','SAP,ORACLE,BAAN,WORKDAY',2),
  ('SILVER_AP_INVOICES','SOURCE_INVOICE_ID','STRING',TRUE,TRUE,'Natural key in the source system',NULL,3),
  ('SILVER_AP_INVOICES','INVOICE_NUMBER','STRING',TRUE,FALSE,'Human-readable invoice number',NULL,4),
  ('SILVER_AP_INVOICES','VENDOR_ID','STRING',TRUE,FALSE,'Vendor identifier as held in the source',NULL,5),
  ('SILVER_AP_INVOICES','VENDOR_NAME','STRING',TRUE,FALSE,'Vendor display name',NULL,6),
  ('SILVER_AP_INVOICES','INVOICE_DATE','DATE',TRUE,FALSE,'Date the invoice was issued',NULL,7),
  ('SILVER_AP_INVOICES','DUE_DATE','DATE',FALSE,FALSE,'Payment due date. Must be >= INVOICE_DATE when present',NULL,8),
  ('SILVER_AP_INVOICES','INVOICE_AMOUNT','NUMBER(18,2)',TRUE,FALSE,'Gross invoice amount in CURRENCY_CODE. Must be > 0',NULL,9),
  ('SILVER_AP_INVOICES','CURRENCY_CODE','STRING',TRUE,FALSE,'ISO 4217 three-letter code','USD,EUR,GBP,JPY,CHF,SEK',10),
  ('SILVER_AP_INVOICES','PAYMENT_TERMS','STRING',FALSE,FALSE,'Normalised payment terms, e.g. NET30',NULL,11),
  ('SILVER_AP_INVOICES','PO_NUMBER','STRING',FALSE,FALSE,'Purchase order reference where matched',NULL,12),
  ('SILVER_AP_INVOICES','LINE_DESCRIPTION','STRING',FALSE,FALSE,'Free-text line description',NULL,13),
  ('SILVER_AP_INVOICES','GL_ACCOUNT','STRING',FALSE,FALSE,'General ledger account code',NULL,14),
  ('SILVER_AP_INVOICES','COST_CENTER_OR_DEPT','STRING',FALSE,FALSE,'Cost centre or department, source-dependent',NULL,15),
  ('SILVER_AP_INVOICES','APPROVAL_STATUS','STRING',TRUE,FALSE,'Normalised approval state','APPROVED,PENDING,REJECTED,PAID',16),
  ('SILVER_AP_INVOICES','CREATED_AT','TIMESTAMP_NTZ',TRUE,FALSE,'Source record creation timestamp',NULL,17),
  ('SILVER_AP_INVOICES','SOURCE_ORG_CODE','STRING',FALSE,FALSE,'Company code / org id / tenant id from source',NULL,18),
  ('SILVER_AP_INVOICES','SOURCE_DOCUMENT_TYPE','STRING',FALSE,FALSE,'Source document type where the source provides one',NULL,19),
  ('SILVER_AP_INVOICES','SOURCE_ENTRY_METHOD','STRING',FALSE,FALSE,'How the record entered the source system',NULL,20)
  AS v(tbl, col, dtype, req, bkey, descr, allowed, ord);

-- ---------------------------------------------------------------------
-- Artifact tables. Generated code is data first: it carries a status so the
-- human approval gate is real, and a run_id so it is traceable to its prompt.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ARTIFACTS.USER_STORIES (
    STORY_ID          STRING NOT NULL PRIMARY KEY,
    RUN_ID            STRING NOT NULL,
    SOURCE_DOC_ID     STRING,
    EPIC              STRING,
    TITLE             STRING NOT NULL,
    AS_A              STRING,
    I_WANT            STRING,
    SO_THAT           STRING,
    ACCEPTANCE_CRITERIA ARRAY,
    SOURCE_TO_TARGET  VARIANT,
    STORY_POINTS      NUMBER,
    PRIORITY          STRING,
    DEPENDENCIES      ARRAY,
    OPEN_QUESTIONS    ARRAY,
    CITATIONS         ARRAY,
    STATUS            STRING DEFAULT 'DRAFT',
    CREATED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS ARTIFACTS.GENERATED_CODE (
    CODE_ID        STRING NOT NULL PRIMARY KEY,
    RUN_ID         STRING NOT NULL,
    STORY_ID       STRING,
    ARTIFACT_KIND  STRING NOT NULL,   -- DBT_MODEL | DYNAMIC_TABLE | DMF | DBT_TEST
    LAYER          STRING,            -- BRONZE | SILVER | GOLD
    OBJECT_NAME    STRING NOT NULL,
    SOURCE_SYSTEM  STRING,
    CODE_TEXT      STRING NOT NULL,
    COMPILE_STATUS STRING,            -- PASS | FAIL | NOT_CHECKED
    COMPILE_ERROR  STRING,
    STATUS         STRING DEFAULT 'DRAFT',  -- DRAFT | APPROVED | MATERIALIZED | REJECTED
    CITATIONS      ARRAY,
    CREATED_AT     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS ARTIFACTS.TEST_CASES (
    TEST_ID         STRING NOT NULL PRIMARY KEY,
    RUN_ID          STRING NOT NULL,
    STORY_ID        STRING,
    TARGET_TABLE    STRING NOT NULL,
    TARGET_COLUMN   STRING,
    TEST_CATEGORY   STRING NOT NULL,  -- NOT_NULL | UNIQUENESS | ACCEPTED_VALUES | BOUNDARY | REFERENTIAL | TYPE_VIOLATION | VOLUME | FRESHNESS | RECONCILIATION
    TEST_NAME       STRING NOT NULL,
    DESCRIPTION     STRING,
    SEVERITY        STRING,           -- CRITICAL | HIGH | MEDIUM | LOW
    ASSERTION_SQL   STRING NOT NULL,  -- returns 0 rows when the test passes
    DBT_TEST_YAML   STRING,
    EXPECT_FAIL_ON  STRING,           -- which injected defect this should catch
    COMPILE_STATUS  STRING,
    COMPILE_ERROR   STRING,
    STATUS          STRING DEFAULT 'DRAFT',
    CITATIONS       ARRAY,
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS ARTIFACTS.TEST_RESULTS (
    RESULT_ID     STRING NOT NULL PRIMARY KEY,
    TEST_ID       STRING NOT NULL,
    EXECUTED_AT   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    DATASET_LABEL STRING,          -- CLEAN | CORRUPTED:<defect>
    OUTCOME       STRING NOT NULL, -- PASS | FAIL | ERROR
    FAIL_ROW_COUNT NUMBER,
    ERROR_MESSAGE STRING
);

CREATE TABLE IF NOT EXISTS ARTIFACTS.DEFECTS (
    DEFECT_ID       STRING NOT NULL PRIMARY KEY,
    RUN_ID          STRING,
    RAISED_FROM     STRING,        -- TEST_RESULT | PIPELINE_ERROR
    SOURCE_REF      STRING,
    RAW_SIGNAL      STRING,        -- the failure text the agent was given
    CATEGORY        STRING,        -- SCHEMA_DRIFT | DATA_QUALITY | LOGIC_ERROR | REFERENTIAL | PERFORMANCE | CONFIG | UNKNOWN
    SEVERITY        STRING,
    ROOT_CAUSE      STRING,
    REMEDIATION     STRING,
    CONFIDENCE      FLOAT,
    OWNER_HINT      STRING,
    CITATIONS       ARRAY,
    STATUS          STRING DEFAULT 'OPEN',
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS ARTIFACTS.SYNTH_BATCHES (
    BATCH_ID      STRING NOT NULL PRIMARY KEY,
    RUN_ID        STRING NOT NULL,
    TARGET_TABLE  STRING NOT NULL,
    ROW_COUNT     NUMBER,
    EDGE_CASES    ARRAY,
    PII_SCAN_RESULT STRING,
    RI_CHECK_RESULT STRING,
    STATUS        STRING DEFAULT 'GENERATED',
    CREATED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

SELECT 'foundation ready' AS status,
       (SELECT COUNT(*) FROM GOVERNANCE.TARGET_CONTRACT) AS contract_cols,
       (SELECT COUNT(*) FROM PIPELINE.BRONZE_SAP_AP_INVOICES)
     + (SELECT COUNT(*) FROM PIPELINE.BRONZE_ORACLE_AP_INVOICES)
     + (SELECT COUNT(*) FROM PIPELINE.BRONZE_BAAN_AP_INVOICES)
     + (SELECT COUNT(*) FROM PIPELINE.BRONZE_WORKDAY_AP_INVOICES) AS bronze_rows;
