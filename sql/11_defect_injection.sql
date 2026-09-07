-- =====================================================================
-- 11_defect_injection.sql -- validating the generated test suite
--
-- This is the part that turns "the AI wrote 28 tests" into evidence. The
-- taxonomy states that a test which cannot be made to fail by any injected
-- defect is a tautology. So the suite is validated by deliberately breaking
-- the data in known ways and confirming the right tests fail.
--
-- The Silver layer is a Dynamic Table and cannot be mutated, so injections
-- run against a sandbox schema holding table copies of Silver and Bronze.
-- Assertion SQL is re-pointed at the sandbox by qualified-name substitution,
-- which is why the test generator was required to fully qualify every table.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;

CREATE SCHEMA IF NOT EXISTS CAPSTONE_AI_DLC.PIPELINE_TEST
    COMMENT = 'Mutable sandbox for injected-defect validation of the test suite';

-- CREATE SCHEMA switches the current schema, so re-select AGENTS before
-- creating procedures or they land in PIPELINE_TEST.
USE SCHEMA AGENTS;

-- Rebuild the sandbox as an exact copy of the current pipeline state.
CREATE OR REPLACE PROCEDURE RESET_TEST_SANDBOX()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES AS
        SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES;
    CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.PIPELINE_TEST.BRONZE_SAP_AP_INVOICES AS
        SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.BRONZE_SAP_AP_INVOICES;
    CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.PIPELINE_TEST.BRONZE_ORACLE_AP_INVOICES AS
        SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.BRONZE_ORACLE_AP_INVOICES;
    CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.PIPELINE_TEST.BRONZE_BAAN_AP_INVOICES AS
        SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.BRONZE_BAAN_AP_INVOICES;
    RETURN 'sandbox reset: '
        || (SELECT COUNT(*)::STRING FROM CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES)
        || ' silver rows';
END;
$$;

-- ---------------------------------------------------------------------
-- Run the compiled suite against a nominated schema.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RUN_TEST_SUITE_IN(P_DATASET_LABEL STRING, P_SCHEMA STRING)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_id   STRING;
    v_sql  STRING;
    v_cnt  NUMBER;
    v_pass NUMBER DEFAULT 0;
    v_fail NUMBER DEFAULT 0;
    v_err  NUMBER DEFAULT 0;
    res    RESULTSET;
    c1 CURSOR FOR
        SELECT TEST_ID, ASSERTION_SQL FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES
        WHERE COMPILE_STATUS = 'PASS' AND STATUS <> 'ENV_EXCEPTION';
BEGIN
    FOR r IN c1 DO
        v_id  := r.TEST_ID;
        -- Re-point the assertion at the nominated schema.
        v_sql := REPLACE(r.ASSERTION_SQL,
                         'CAPSTONE_AI_DLC.PIPELINE.',
                         'CAPSTONE_AI_DLC.' || :P_SCHEMA || '.');
        BEGIN
            res := (EXECUTE IMMEDIATE 'SELECT COUNT(*) AS n FROM (' || :v_sql || ')');
            LET c2 CURSOR FOR res;
            OPEN c2; FETCH c2 INTO v_cnt; CLOSE c2;

            INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS
                (RESULT_ID, TEST_ID, DATASET_LABEL, OUTCOME, FAIL_ROW_COUNT)
            SELECT UUID_STRING(), :v_id, :P_DATASET_LABEL,
                   CASE WHEN :v_cnt = 0 THEN 'PASS' ELSE 'FAIL' END, :v_cnt;

            IF (v_cnt = 0) THEN v_pass := :v_pass + 1; ELSE v_fail := :v_fail + 1; END IF;
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS
                    (RESULT_ID, TEST_ID, DATASET_LABEL, OUTCOME, ERROR_MESSAGE)
                SELECT UUID_STRING(), :v_id, :P_DATASET_LABEL, 'ERROR', SQLERRM;
                v_err := :v_err + 1;
        END;
    END FOR;
    RETURN OBJECT_CONSTRUCT('dataset', :P_DATASET_LABEL, 'schema', :P_SCHEMA,
                            'passed', :v_pass, 'failed', :v_fail, 'errored', :v_err);
END;
$$;

-- ---------------------------------------------------------------------
-- The defect catalogue. Each entry states the mutation and the test
-- category that must detect it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.GOVERNANCE.DEFECT_CATALOGUE (
    DEFECT_NAME       STRING NOT NULL PRIMARY KEY,
    DESCRIPTION       STRING,
    EXPECTED_CATEGORY STRING NOT NULL,
    MUTATION_SQL      STRING NOT NULL,
    ORDINAL           NUMBER
);

INSERT INTO CAPSTONE_AI_DLC.GOVERNANCE.DEFECT_CATALOGUE
    (DEFECT_NAME, DESCRIPTION, EXPECTED_CATEGORY, MUTATION_SQL, ORDINAL)
SELECT v.a, v.b, v.c, v.d, v.e FROM VALUES
('NULL_REQUIRED_COLUMN',
 'A required contract column is NULLed, as happens when a source status value falls outside the mapping',
 'NOT_NULL',
 'UPDATE CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SET APPROVAL_STATUS = NULL WHERE SOURCE_SYSTEM = ''BAAN'' AND SOURCE_INVOICE_ID IN (''BAN-001'',''BAN-002'')', 1),
('DUPLICATE_GRAIN_KEY',
 'The grain is violated by a duplicate INVOICE_KEY, as happens when a join fans out',
 'UNIQUENESS',
 'INSERT INTO CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SELECT * FROM CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES WHERE SOURCE_INVOICE_ID = ''BAN-003''', 2),
('UNPERMITTED_CURRENCY',
 'A currency outside the permitted set reaches Silver instead of being quarantined',
 'ACCEPTED_VALUES',
 'UPDATE CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SET CURRENCY_CODE = ''JPY'' WHERE SOURCE_INVOICE_ID = ''BAN-004''', 3),
('NON_POSITIVE_AMOUNT',
 'A zero or negative invoice amount passes through, breaching the contract boundary rule',
 'BOUNDARY',
 'UPDATE CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SET INVOICE_AMOUNT = -250.00 WHERE SOURCE_INVOICE_ID = ''BAN-005''', 4),
('DUE_DATE_BEFORE_INVOICE_DATE',
 'DUE_DATE precedes INVOICE_DATE, an impossible payment term',
 'BOUNDARY',
 'UPDATE CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SET DUE_DATE = DATEADD(''day'', -5, INVOICE_DATE) WHERE SOURCE_INVOICE_ID = ''BAN-006''', 5),
('SILENT_ROW_LOSS',
 'Rows vanish between Bronze and Silver - the UNION instead of UNION ALL defect class',
 'RECONCILIATION',
 'DELETE FROM CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES WHERE SOURCE_SYSTEM = ''BAAN'' AND SOURCE_INVOICE_ID IN (''BAN-007'',''BAN-008'',''BAN-009'')', 6),
('ORPHANED_SILVER_ROW',
 'A Silver row exists with no corresponding Bronze record, indicating a join or filter defect',
 'REFERENTIAL',
 'INSERT INTO CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES SELECT ''BAAN-GHOST-001'', ''BAAN'', ''GHOST-001'', INVOICE_NUMBER, VENDOR_ID, VENDOR_NAME, INVOICE_DATE, DUE_DATE, INVOICE_AMOUNT, CURRENCY_CODE, PAYMENT_TERMS, PO_NUMBER, LINE_DESCRIPTION, GL_ACCOUNT, COST_CENTER_OR_DEPT, APPROVAL_STATUS, CREATED_AT, SOURCE_ORG_CODE, SOURCE_DOCUMENT_TYPE, SOURCE_ENTRY_METHOD FROM CAPSTONE_AI_DLC.PIPELINE_TEST.SILVER_AP_INVOICES WHERE SOURCE_INVOICE_ID = ''BAN-010''', 7)
AS v(a,b,c,d,e);

-- ---------------------------------------------------------------------
-- Run the full validation: for each catalogued defect, reset the sandbox,
-- inject, run the suite, and record whether a test of the expected category
-- caught it. A defect nothing catches is a coverage gap in the suite.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CAPSTONE_AI_DLC.METRICS.MUTATION_RESULTS (
    DEFECT_NAME       STRING NOT NULL,
    EXPECTED_CATEGORY STRING,
    CAUGHT            BOOLEAN,
    CAUGHT_BY         ARRAY,
    CAUGHT_BY_EXPECTED_CATEGORY BOOLEAN,
    TOTAL_FAILING     NUMBER,
    RUN_AT            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE VALIDATE_TEST_SUITE()
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_name    STRING;
    v_cat     STRING;
    v_mut     STRING;
    v_label   STRING;
    v_dummy   OBJECT;
    v_caught  NUMBER;
    v_expect  NUMBER;
    v_names   ARRAY;
    v_total   NUMBER DEFAULT 0;
    v_hits    NUMBER DEFAULT 0;
    c1 CURSOR FOR
        SELECT DEFECT_NAME, EXPECTED_CATEGORY, MUTATION_SQL
        FROM CAPSTONE_AI_DLC.GOVERNANCE.DEFECT_CATALOGUE ORDER BY ORDINAL;
BEGIN
    DELETE FROM CAPSTONE_AI_DLC.METRICS.MUTATION_RESULTS;

    FOR r IN c1 DO
        v_name  := r.DEFECT_NAME;
        v_cat   := r.EXPECTED_CATEGORY;
        v_mut   := r.MUTATION_SQL;
        v_label := 'CORRUPTED:' || :v_name;

        CALL CAPSTONE_AI_DLC.AGENTS.RESET_TEST_SANDBOX();
        EXECUTE IMMEDIATE :v_mut;
        CALL CAPSTONE_AI_DLC.AGENTS.RUN_TEST_SUITE_IN(:v_label, 'PIPELINE_TEST') INTO :v_dummy;

        SELECT COUNT(*),
               COUNT_IF(t.TEST_CATEGORY = :v_cat),
               ARRAY_AGG(t.TEST_NAME)
          INTO :v_caught, :v_expect, :v_names
        FROM CAPSTONE_AI_DLC.ARTIFACTS.TEST_RESULTS res
        JOIN CAPSTONE_AI_DLC.ARTIFACTS.TEST_CASES t ON t.TEST_ID = res.TEST_ID
        WHERE res.DATASET_LABEL = :v_label AND res.OUTCOME = 'FAIL';

        INSERT INTO CAPSTONE_AI_DLC.METRICS.MUTATION_RESULTS
            (DEFECT_NAME, EXPECTED_CATEGORY, CAUGHT, CAUGHT_BY,
             CAUGHT_BY_EXPECTED_CATEGORY, TOTAL_FAILING)
        SELECT :v_name, :v_cat, :v_caught > 0, :v_names, :v_expect > 0, :v_caught;

        v_total := :v_total + 1;
        IF (v_caught > 0) THEN v_hits := :v_hits + 1; END IF;
    END FOR;

    -- Leave the sandbox in a clean state so a later manual run is not misled.
    CALL CAPSTONE_AI_DLC.AGENTS.RESET_TEST_SANDBOX();

    RETURN OBJECT_CONSTRUCT('defects_injected', :v_total, 'defects_caught', :v_hits,
                            'catch_rate', ROUND(:v_hits / NULLIF(:v_total,0), 4));
END;
$$;
