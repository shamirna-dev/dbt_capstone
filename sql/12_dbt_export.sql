-- =====================================================================
-- 12_dbt_export.sql -- write the dbt project out as files
--
-- The generated code lives in ARTIFACTS.GENERATED_CODE as data. This turns
-- the approved artifacts into an actual dbt project on a stage, which can
-- then be pulled to a working copy with:
--     snow stage copy @CAPSTONE_AI_DLC.GOVERNANCE.DBT_EXPORT ./dbt_project
--       --recursive
--
-- Files are written with all CSV framing disabled so the staged object is
-- the raw text of the model, not a quoted CSV field.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA GOVERNANCE;

CREATE STAGE IF NOT EXISTS DBT_EXPORT
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Generated dbt project artifacts';

CREATE OR REPLACE FILE FORMAT RAW_TEXT
    TYPE = CSV
    COMPRESSION = NONE
    FIELD_DELIMITER = NONE
    RECORD_DELIMITER = NONE
    FIELD_OPTIONALLY_ENCLOSED_BY = NONE
    ESCAPE_UNENCLOSED_FIELD = NONE
    EMPTY_FIELD_AS_NULL = FALSE;

CREATE OR REPLACE PROCEDURE EXPORT_DBT_PROJECT()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_name STRING;
    v_code STRING;
    v_n    NUMBER DEFAULT 0;
    c1 CURSOR FOR
        SELECT OBJECT_NAME, CODE_TEXT
        FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE
        WHERE ARTIFACT_KIND = 'DBT_MODEL' AND COMPILE_STATUS = 'PASS';
BEGIN
    FOR r IN c1 DO
        v_name := LOWER(r.OBJECT_NAME);
        v_code := r.CODE_TEXT;
        EXECUTE IMMEDIATE
            'COPY INTO @CAPSTONE_AI_DLC.GOVERNANCE.DBT_EXPORT/models/staging/'
            || :v_name || '.sql'
            || ' FROM (SELECT CODE_TEXT FROM CAPSTONE_AI_DLC.ARTIFACTS.GENERATED_CODE'
            || '        WHERE ARTIFACT_KIND = ''DBT_MODEL'' AND OBJECT_NAME = '''
            || UPPER(:v_name) || ''')'
            || ' FILE_FORMAT = (FORMAT_NAME = CAPSTONE_AI_DLC.GOVERNANCE.RAW_TEXT)'
            || ' OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 134217728';
        v_n := :v_n + 1;
    END FOR;
    RETURN 'exported ' || :v_n::STRING || ' dbt model file(s)';
END;
$$;

CALL EXPORT_DBT_PROJECT();

LS @DBT_EXPORT;
