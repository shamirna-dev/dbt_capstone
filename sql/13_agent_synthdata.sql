-- =====================================================================
-- 13_agent_synthdata.sql -- Agent 4: synthetic test data
--
-- SDLC phase: TEST_DATA
--
-- PRD-AP-2025-001 states that no production PII may reach a non-production
-- environment and that lower environments must be populated with synthetic
-- data. Two consequences shape this agent:
--
--  1. Real vendor names are never placed in the prompt. The agent is given
--     the schema and the business rules, and told to invent vendors. You
--     cannot claim a synthetic-data capability protects PII if the PII was
--     sent to the model in order to produce it.
--
--  2. The output is checked, not trusted: a PII overlap scan asserts no
--     generated vendor name or invoice number collides with production, and
--     an edge-case coverage check asserts the batch actually contains the
--     awkward cases it was asked for.
--
-- The point of this data is to reach rules the production extract cannot
-- exercise - notably an unmapped payment-terms code, which must become NULL
-- rather than being defaulted, and a pre-2024-11-01 cost centre with no
-- prefix. Neither case exists in the real 50-row extract.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;

CREATE SCHEMA IF NOT EXISTS SYNTH
    COMMENT = 'Synthetic test data for lower environments. No production PII.';

USE SCHEMA AGENTS;

CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES
    LIKE CAPSTONE_AI_DLC.PIPELINE.BRONZE_BAAN_AP_INVOICES;

CREATE OR REPLACE PROCEDURE AGENT_SYNTHDATA(P_ROW_COUNT NUMBER, P_ORCHESTRATOR STRING)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Generates synthetic Baan bronze rows covering documented edge cases, then validates them.'
AS
$$
DECLARE
    v_run_id    STRING;
    v_started   TIMESTAMP_NTZ;
    v_ctx       OBJECT;
    v_context   STRING;
    v_citations ARRAY;
    v_srccols   STRING;
    v_prompt    STRING;
    v_llm       OBJECT;
    v_raw       STRING;
    v_json      VARIANT;
    v_rows      ARRAY;
    v_n         NUMBER DEFAULT 0;
    v_batch     STRING;
    v_pii       NUMBER;
    v_pii_txt   STRING;
    v_edge      ARRAY;
    v_unmapped  NUMBER;
    v_noprefix  NUMBER;
    v_ri        STRING;
    v_top_k     NUMBER;
BEGIN
    v_run_id  := UUID_STRING();
    v_started := CURRENT_TIMESTAMP();
    v_top_k   := CAPSTONE_AI_DLC.GOVERNANCE.CFG('RAG_TOP_K')::NUMBER;
    v_batch   := 'SYNTH-' || TO_CHAR(CURRENT_TIMESTAMP(),'YYYYMMDDHH24MISS');

    SELECT LISTAGG(COLUMN_NAME || ' ' || DATA_TYPE, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_srccols
    FROM CAPSTONE_AI_DLC.INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'PIPELINE' AND TABLE_NAME = 'BRONZE_BAAN_AP_INVOICES';

    CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_MULTI(ARRAY_CONSTRUCT(
        'BAAN payment terms source code mapping canonical NETnn unmapped code NULL',
        'BAAN approval status mapping canonical values',
        'cost centre prefix first hyphen pre-2024-11-01 extracts no prefix',
        'permitted currency codes quarantine rule',
        'boundary rules invoice amount positive due date not before invoice date',
        'no production PII in non-production environments synthetic data'
    ), :v_top_k) INTO :v_ctx;
    v_context   := GET(:v_ctx,'context_text')::STRING;
    v_citations := GET(:v_ctx,'citations')::ARRAY;

    v_prompt :=
'You are a test data engineer producing synthetic source-system records for a
non-production environment.

GOVERNING CONTEXT (authoritative; citation ids in square brackets):
' || :v_context || '

TARGET: synthetic rows shaped like the Infor Baan IV AP invoice extract.
COLUMNS: ' || :v_srccols || '

PRIVACY REQUIREMENT
You have deliberately NOT been given any real vendor names, invoice numbers or
identifiers. Invent entirely fictional ones. Vendor names must be obviously
synthetic and must not be real companies. Prefix every BAN_INVOICE_ID with
''SYN-'' so synthetic rows are always distinguishable from production.

TASK
Produce exactly ' || :P_ROW_COUNT::STRING || ' rows. The batch MUST between them cover
all of the following edge cases, because the production extract does not contain
them and the transformation rules for them are therefore untested:

  a) At least 2 rows with a BAN_PAY_TERMS code that is NOT in the mapping table.
     Use a plausible but unmapped code. These must end up with NULL payment terms
     downstream rather than a default.
  b) At least 2 rows with BAN_COST_CTR containing NO hyphen at all, representing a
     pre-2024-11-01 extract.
  c) At least 2 rows with BAN_COST_CTR carrying the normal prefixed form.
  d) At least 1 row for each approval status value in the mapping table for BAAN.
  e) At least 1 row where BAN_PAY_DATE is NULL.
  f) A spread of the permitted currency codes only.
  g) Amounts spanning small and large values, all strictly greater than zero. At
     least one row at or above the documented high-value threshold in USD terms.
  h) BAN_INV_DATE values within 2025. BAN_PAY_DATE, where present, on or after
     BAN_INV_DATE.

Dates as YYYY-MM-DD strings. Timestamps as YYYY-MM-DD HH:MI:SS strings.
Amounts as plain numbers, no currency symbols or thousands separators.

Return ONLY valid JSON, no markdown fence:
{"rows":[{"BAN_INVOICE_ID":"SYN-0001","BAN_INVOICE_REF":"...","BAN_VENDOR_CODE":"...","BAN_VENDOR_DESC":"...","BAN_INV_DATE":"2025-03-04","BAN_PAY_DATE":"2025-04-03","BAN_AMOUNT":12345.67,"BAN_CURR":"EUR","BAN_PAY_TERMS":"N30","BAN_PO_REF":"...","BAN_LINE_DESC":"...","BAN_GL_CODE":"...","BAN_COST_CTR":"BC-MFG","BAN_STATUS":"POSTED","BAN_CREATED":"2025-03-04 09:15:00","BAN_COMPANY":"..."}],
 "edge_cases_covered":["a","b","c","d","e","f","g","h"],
 "citations":["chunk-id"]}';

    CALL CAPSTONE_AI_DLC.AGENTS.LLM_COMPLETE(
             :v_prompt, CAPSTONE_AI_DLC.GOVERNANCE.CFG('DEFAULT_MODEL'), 8192) INTO :v_llm;
    v_raw  := GET(:v_llm,'text')::STRING;
    v_json := CAPSTONE_AI_DLC.AGENTS.PARSE_LLM_JSON(:v_raw);

    IF (v_json IS NULL) THEN
        CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
            'run_id', :v_run_id,'agent_name','AGENT_SYNTHDATA','sdlc_phase','TEST_DATA',
            'input_ref','BRONZE_BAAN_AP_INVOICES','retrieved_chunks', :v_citations,
            'prompt_text', :v_prompt,'model_name', GET(:v_llm,'model')::STRING,
            'response_raw', :v_raw,'status','FAILED',
            'error_message','model did not return parseable JSON',
            'prompt_tokens', GET(:v_llm,'prompt_tokens'),
            'completion_tokens', GET(:v_llm,'completion_tokens'),
            'total_tokens', GET(:v_llm,'total_tokens'),
            'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
            'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));
        RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'status','FAILED','error','unparseable model output');
    END IF;

    v_rows := :v_json:rows::ARRAY;
    v_edge := :v_json:edge_cases_covered::ARRAY;

    TRUNCATE TABLE CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES;

    INSERT INTO CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES
        (BAN_INVOICE_ID, BAN_INVOICE_REF, BAN_VENDOR_CODE, BAN_VENDOR_DESC,
         BAN_INV_DATE, BAN_PAY_DATE, BAN_AMOUNT, BAN_CURR, BAN_PAY_TERMS,
         BAN_PO_REF, BAN_LINE_DESC, BAN_GL_CODE, BAN_COST_CTR, BAN_STATUS,
         BAN_CREATED, BAN_COMPANY)
    SELECT
        r.VALUE:BAN_INVOICE_ID::STRING, r.VALUE:BAN_INVOICE_REF::STRING,
        r.VALUE:BAN_VENDOR_CODE::STRING, r.VALUE:BAN_VENDOR_DESC::STRING,
        TRY_TO_DATE(r.VALUE:BAN_INV_DATE::STRING),
        TRY_TO_DATE(r.VALUE:BAN_PAY_DATE::STRING),
        TRY_TO_NUMBER(r.VALUE:BAN_AMOUNT::STRING, 18, 2),
        r.VALUE:BAN_CURR::STRING, r.VALUE:BAN_PAY_TERMS::STRING,
        r.VALUE:BAN_PO_REF::STRING, r.VALUE:BAN_LINE_DESC::STRING,
        r.VALUE:BAN_GL_CODE::STRING, r.VALUE:BAN_COST_CTR::STRING,
        r.VALUE:BAN_STATUS::STRING,
        TRY_TO_TIMESTAMP_NTZ(r.VALUE:BAN_CREATED::STRING),
        r.VALUE:BAN_COMPANY::STRING
    FROM TABLE(FLATTEN(input => :v_rows)) r;

    v_n := SQLROWCOUNT;

    -- ---- Validation 1: PII overlap. No synthetic identifier or vendor name may
    -- collide with production. This is checked, not assumed.
    SELECT COUNT(*) INTO :v_pii
    FROM CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES s
    WHERE EXISTS (SELECT 1 FROM CAPSTONE_AI_DLC.PIPELINE.BRONZE_BAAN_AP_INVOICES p
                   WHERE UPPER(TRIM(p.BAN_VENDOR_DESC)) = UPPER(TRIM(s.BAN_VENDOR_DESC))
                      OR p.BAN_INVOICE_ID  = s.BAN_INVOICE_ID
                      OR p.BAN_INVOICE_REF = s.BAN_INVOICE_REF
                      OR p.BAN_VENDOR_CODE = s.BAN_VENDOR_CODE);
    v_pii_txt := CASE WHEN :v_pii = 0 THEN 'PASS: no overlap with production identifiers or vendor names'
                      ELSE 'FAIL: ' || :v_pii::STRING || ' synthetic row(s) collide with production' END;

    -- ---- Validation 2: did the batch actually reach the untested rules?
    SELECT COUNT(*) INTO :v_unmapped
    FROM CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES
    WHERE BAN_PAY_TERMS NOT IN ('N30','N60') OR BAN_PAY_TERMS IS NULL;

    SELECT COUNT(*) INTO :v_noprefix
    FROM CAPSTONE_AI_DLC.SYNTH.BRONZE_BAAN_AP_INVOICES
    WHERE POSITION('-' IN BAN_COST_CTR) = 0;

    v_ri := 'unmapped_terms_rows=' || :v_unmapped::STRING
         || ', no_prefix_cost_centre_rows=' || :v_noprefix::STRING
         || CASE WHEN :v_unmapped >= 2 AND :v_noprefix >= 2
                 THEN ' PASS: both previously untested rules are now exercised'
                 ELSE ' FAIL: batch does not cover the requested edge cases' END;

    INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.SYNTH_BATCHES
        (BATCH_ID, RUN_ID, TARGET_TABLE, ROW_COUNT, EDGE_CASES,
         PII_SCAN_RESULT, RI_CHECK_RESULT, STATUS)
    SELECT :v_batch, :v_run_id, 'SYNTH.BRONZE_BAAN_AP_INVOICES', :v_n, :v_edge,
           :v_pii_txt, :v_ri,
           CASE WHEN :v_pii = 0 AND :v_unmapped >= 2 AND :v_noprefix >= 2
                THEN 'VALIDATED' ELSE 'REJECTED' END;

    CALL CAPSTONE_AI_DLC.AGENTS.LOG_RUN(OBJECT_CONSTRUCT(
        'run_id', :v_run_id,'agent_name','AGENT_SYNTHDATA','sdlc_phase','TEST_DATA',
        'input_ref','BRONZE_BAAN_AP_INVOICES',
        'input_payload', OBJECT_CONSTRUCT('batch', :v_batch,'rows', :v_n),
        'retrieved_chunks', :v_citations,'prompt_text', :v_prompt,
        'model_name', GET(:v_llm,'model')::STRING,'response_raw', :v_raw,
        'output_ref', :v_batch,
        'status', CASE WHEN :v_pii = 0 AND :v_unmapped >= 2 AND :v_noprefix >= 2
                       THEN 'SUCCESS' ELSE 'FAILED' END,
        'error_message', CASE WHEN :v_pii > 0 THEN :v_pii_txt
                              WHEN :v_unmapped < 2 OR :v_noprefix < 2 THEN :v_ri
                              ELSE NULL END,
        'prompt_tokens', GET(:v_llm,'prompt_tokens'),
        'completion_tokens', GET(:v_llm,'completion_tokens'),
        'total_tokens', GET(:v_llm,'total_tokens'),
        'latency_ms', DATEDIFF('millisecond', :v_started, CURRENT_TIMESTAMP()),
        'orchestrator', :P_ORCHESTRATOR,'started_at', :v_started));

    RETURN OBJECT_CONSTRUCT('run_id', :v_run_id,'batch_id', :v_batch,
                            'rows_generated', :v_n,
                            'pii_scan', :v_pii_txt, 'edge_case_check', :v_ri);
END;
$$;
