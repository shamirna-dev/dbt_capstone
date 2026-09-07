-- =====================================================================
-- 09_materialize.sql -- the human approval gate and materialisation
--
-- Generated code is data first and files second. Nothing an agent writes
-- reaches the pipeline until a human moves it from DRAFT to APPROVED, and
-- only APPROVED code can be materialised. That is what makes the approval
-- gate real rather than a slide.
--
-- The Silver union is assembled deterministically rather than by an agent.
-- The hard, judgement-heavy part is the per-source conformance mapping, and
-- that is what the agent generates. Unioning verified staging models to a
-- documented Dynamic Table template is boilerplate, and boilerplate should
-- be produced by code, not by a language model.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA PIPELINE;

-- ---------------------------------------------------------------------
-- Approval gate. Refuses to approve code that failed compile check.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE APPROVE_CODE(P_CODE_ID STRING, P_APPROVER STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_compile STRING;
    v_status  STRING;
BEGIN
    SELECT COMPILE_STATUS, STATUS INTO :v_compile, :v_status
    FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE WHERE CODE_ID = :P_CODE_ID;

    IF (v_compile IS NULL) THEN
        RETURN 'no such code id: ' || :P_CODE_ID;
    END IF;
    IF (v_compile <> 'PASS') THEN
        RETURN 'refused: code has COMPILE_STATUS=' || :v_compile || ', fix before approving';
    END IF;

    UPDATE CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
       SET STATUS = 'APPROVED'
     WHERE CODE_ID = :P_CODE_ID;
    RETURN 'approved by ' || :P_APPROVER || ': ' || :P_CODE_ID;
END;
$$;

-- Approve every staging select that compiled. In a real engagement this is a
-- reviewer clicking through a diff; here it is one call, but the gate still
-- refuses anything that did not compile.
CREATE OR REPLACE PROCEDURE APPROVE_ALL_COMPILING(P_APPROVER STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
       SET STATUS = 'APPROVED'
     WHERE COMPILE_STATUS = 'PASS' AND STATUS = 'DRAFT';
    RETURN 'approved ' || SQLROWCOUNT::STRING || ' artifact(s) by ' || :P_APPROVER;
END;
$$;

-- ---------------------------------------------------------------------
-- Materialise approved staging models as views, one per source.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE MATERIALIZE_STAGING()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_done STRING DEFAULT '';
    v_name STRING;
    v_code STRING;
    c1 CURSOR FOR
        SELECT OBJECT_NAME, CODE_TEXT
        FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
        WHERE ARTIFACT_KIND = 'STAGING_SELECT' AND STATUS = 'APPROVED';
BEGIN
    FOR r IN c1 DO
        -- Loop variables cannot be referenced directly inside a SQL statement,
        -- so copy them into locals first.
        v_name := r.OBJECT_NAME;
        v_code := r.CODE_TEXT;
        EXECUTE IMMEDIATE 'CREATE OR REPLACE VIEW CAPSTONE_AI_DLC.PIPELINE.'
                          || :v_name || ' AS ' || :v_code;
        UPDATE CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
           SET STATUS = 'MATERIALIZED'
         WHERE OBJECT_NAME = :v_name AND ARTIFACT_KIND = 'STAGING_SELECT';
        v_done := :v_done || :v_name || ' ';
    END FOR;
    RETURN 'materialised: ' || NVL(:v_done, 'nothing');
END;
$$;

-- ---------------------------------------------------------------------
-- Build the Silver Dynamic Table by unioning materialised staging views.
-- UNION ALL is mandated by both the PRD and the coding standard.
--
-- After creation the achieved refresh mode is checked. STD-DT-002 says an
-- unrequested FULL refresh is a defect, not a warning, so this raises one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE BUILD_SILVER_DT(P_TARGET_LAG STRING)
RETURNS OBJECT
LANGUAGE SQL
AS
$$
DECLARE
    v_union   STRING DEFAULT '';
    v_sql     STRING;
    v_mode    STRING;
    v_reason  STRING;
    v_rows    NUMBER;
    v_n       NUMBER DEFAULT 0;
    v_name    STRING;
    c1 CURSOR FOR
        SELECT DISTINCT OBJECT_NAME
        FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
        WHERE ARTIFACT_KIND = 'STAGING_SELECT' AND STATUS = 'MATERIALIZED'
        ORDER BY OBJECT_NAME;
BEGIN
    FOR r IN c1 DO
        v_name := r.OBJECT_NAME;
        IF (v_n > 0) THEN
            v_union := :v_union || '\nUNION ALL\n';
        END IF;
        v_union := :v_union || 'SELECT * FROM CAPSTONE_AI_DLC.PIPELINE.' || :v_name;
        v_n := :v_n + 1;
    END FOR;

    IF (v_n = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','error','no materialised staging models');
    END IF;

    v_sql := 'CREATE OR REPLACE DYNAMIC TABLE CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES'
          || ' TARGET_LAG = ''' || :P_TARGET_LAG || ''''
          || ' WAREHOUSE = COMPUTE_WH'
          || ' REFRESH_MODE = INCREMENTAL'
          || ' INITIALIZE = ON_CREATE'
          || ' AS ' || :v_union;
    EXECUTE IMMEDIATE :v_sql;

    -- Achieved refresh mode is only exposed by SHOW, not INFORMATION_SCHEMA.
    EXECUTE IMMEDIATE
        'SHOW DYNAMIC TABLES LIKE ''SILVER_AP_INVOICES'' IN SCHEMA CAPSTONE_AI_DLC.PIPELINE';
    SELECT "refresh_mode", NVL("refresh_mode_reason", '') INTO :v_mode, :v_reason
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

    SELECT COUNT(*) INTO :v_rows FROM CAPSTONE_AI_DLC.PIPELINE.SILVER_AP_INVOICES;

    -- STD-DT-002: a silent downgrade to FULL is a defect.
    IF (v_mode <> 'INCREMENTAL') THEN
        INSERT INTO CAPSTONE_AI_DLC.ARTIFACTS.DEFECTS
            (DEFECT_ID, RAISED_FROM, SOURCE_REF, RAW_SIGNAL, CATEGORY, SEVERITY,
             ROOT_CAUSE, REMEDIATION, CONFIDENCE, OWNER_HINT, STATUS)
        SELECT UUID_STRING(), 'PIPELINE_ERROR', 'SILVER_AP_INVOICES',
               'Requested REFRESH_MODE=INCREMENTAL but achieved ' || :v_mode
               || '. Reason: ' || NVL(:v_reason,'not reported'),
               'PERFORMANCE', 'HIGH',
               'Dynamic Table query contains a construct that cannot be incrementalised',
               'Review STD-DT-002 rules; isolate the offending expression into a downstream DT',
               1.0, 'Data Platform Team', 'OPEN';
    END IF;

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','sources', :v_n,
                            'refresh_mode', :v_mode, 'refresh_mode_reason', :v_reason,
                            'row_count', :v_rows);
END;
$$;
