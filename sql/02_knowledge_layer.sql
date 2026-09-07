-- =====================================================================
-- 02_knowledge_layer.sql -- RAG knowledge base over governing documents
--
-- Design note: retrieval is Cortex Search (hybrid lexical + semantic with
-- reranking) rather than hand-rolled cosine similarity over embeddings.
-- Every agent records the CHUNK_IDs it retrieved, so any generated artifact
-- can be traced back to the governing clause that authorised it.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA GOVERNANCE;

CREATE TABLE IF NOT EXISTS KNOWLEDGE_DOCS (
    DOC_ID       STRING NOT NULL PRIMARY KEY,
    DOC_TYPE     STRING NOT NULL,   -- PRD | DATA_CONTRACT | CODING_STANDARD | PATTERN | TEST_TAXONOMY | BUSINESS_RULE
    TITLE        STRING NOT NULL,
    OWNER        STRING,
    VERSION      STRING,
    EFFECTIVE_DATE DATE,
    BODY         STRING NOT NULL,
    LOADED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS KNOWLEDGE_CHUNKS (
    CHUNK_ID   STRING NOT NULL PRIMARY KEY,
    DOC_ID     STRING NOT NULL,
    DOC_TYPE   STRING NOT NULL,
    TITLE      STRING NOT NULL,
    CHUNK_INDEX NUMBER NOT NULL,
    CHUNK_TEXT STRING NOT NULL,
    CHAR_LEN   NUMBER
);

-- ---------------------------------------------------------------------
-- Rebuild chunks from docs. 1200-char windows with 200-char overlap:
-- large enough to keep a business rule and its rationale together,
-- overlapped so a rule split across a boundary is still retrievable.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE REBUILD_KNOWLEDGE_CHUNKS()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    TRUNCATE TABLE CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS;

    INSERT INTO CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS
        (CHUNK_ID, DOC_ID, DOC_TYPE, TITLE, CHUNK_INDEX, CHUNK_TEXT, CHAR_LEN)
    SELECT
        d.DOC_ID || '#' || LPAD(f.INDEX::STRING, 3, '0'),
        d.DOC_ID, d.DOC_TYPE, d.TITLE,
        f.INDEX,
        f.VALUE::STRING,
        LENGTH(f.VALUE::STRING)
    FROM CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_DOCS d,
         LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
             d.BODY, 'markdown', 1200, 200)) f;

    RETURN 'chunks rebuilt: ' ||
           (SELECT COUNT(*)::STRING FROM CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS);
END;
$$;

-- ---------------------------------------------------------------------
-- Retrieval. Note: SNOWFLAKE.CORTEX.SEARCH_PREVIEW requires its arguments
-- to be compile-time constants, so it cannot be wrapped in a parameterised
-- SQL UDF. Retrieval is therefore a procedure that builds the request
-- literal and EXECUTE IMMEDIATEs it. Single quotes in the query are escaped
-- before interpolation.
--
-- Returns an OBJECT: { context_text, citations, chunk_count }
-- so every agent shares one grounding format.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE RETRIEVE_CONTEXT(P_QUERY STRING, P_TOP_K NUMBER)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'RAG retrieval over the governance knowledge base via Cortex Search.'
AS
$$
DECLARE
    v_request    STRING;
    v_sql        STRING;
    v_result     OBJECT;
    res          RESULTSET;
BEGIN
    v_request := '{"query":"' || REPLACE(REPLACE(:P_QUERY, '\\', '\\\\'), '"', '\\"') ||
                 '","columns":["CHUNK_ID","DOC_ID","DOC_TYPE","TITLE","CHUNK_TEXT"]' ||
                 ',"limit":' || :P_TOP_K::STRING || '}';

    v_sql := 'SELECT OBJECT_CONSTRUCT(''context_text'', COALESCE(LISTAGG(''['' || r.value:CHUNK_ID::STRING || ''] ('' || r.value:TITLE::STRING || '')'' || CHAR(10) || r.value:CHUNK_TEXT::STRING, CHAR(10) || CHAR(10)) WITHIN GROUP (ORDER BY r.index), ''''),'
          || ' ''citations'', COALESCE(ARRAY_AGG(r.value:CHUNK_ID::STRING) WITHIN GROUP (ORDER BY r.index), ARRAY_CONSTRUCT()),'
          || ' ''chunk_count'', COUNT(*)) AS ctx'
          || ' FROM TABLE(FLATTEN(input => PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('
          || '''CAPSTONE_AI_DLC.GOVERNANCE.KB_SEARCH'', '
          || '''' || REPLACE(v_request, '''', '''''') || '''))'
          || ':results)) r';

    res := (EXECUTE IMMEDIATE :v_sql);
    LET c CURSOR FOR res;
    OPEN c;
    FETCH c INTO v_result;
    CLOSE c;
    RETURN v_result;
END;
$$;

