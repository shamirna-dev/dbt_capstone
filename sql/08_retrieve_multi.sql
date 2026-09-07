-- =====================================================================
-- 08_retrieve_multi.sql -- multi-query retrieval
--
-- Why this exists. The first scaffolding run retrieved five chunks for one
-- broad query and none of them was the normalisation mapping table. The
-- model then inferred a payment-terms mapping from the sample rows, which
-- happened to be right, and an approval-status mapping which was wrong and
-- would have NULLed a required column.
--
-- A single broad query is the wrong retrieval strategy when an agent needs
-- several unrelated facts at once. RETRIEVE_MULTI issues one targeted query
-- per fact the agent needs, then merges and de-duplicates the chunks. Recall
-- was the bottleneck, not the model.
-- =====================================================================

USE DATABASE CAPSTONE_AI_DLC;
USE SCHEMA GOVERNANCE;

CREATE OR REPLACE PROCEDURE RETRIEVE_MULTI(P_QUERIES ARRAY, P_TOP_K NUMBER)
RETURNS OBJECT
LANGUAGE SQL
COMMENT = 'Runs one retrieval per query and merges the deduplicated chunk set.'
AS
$$
DECLARE
    v_ids       ARRAY DEFAULT ARRAY_CONSTRUCT();
    v_one       OBJECT;
    v_q         STRING;
    v_i         NUMBER DEFAULT 0;
    v_n         NUMBER;
    v_result    OBJECT;
BEGIN
    v_n := ARRAY_SIZE(:P_QUERIES);

    WHILE (v_i < v_n) DO
        v_q := GET(:P_QUERIES, :v_i)::STRING;
        CALL CAPSTONE_AI_DLC.GOVERNANCE.RETRIEVE_CONTEXT(:v_q, :P_TOP_K) INTO :v_one;
        v_ids := ARRAY_CAT(:v_ids, GET(:v_one,'citations')::ARRAY);
        v_i := :v_i + 1;
    END WHILE;

    -- Rebuild the context from the chunk table rather than concatenating the
    -- per-query context blocks, so a chunk retrieved by two queries appears
    -- once and chunks stay in document order.
    SELECT OBJECT_CONSTRUCT(
               'context_text', COALESCE(LISTAGG('[' || CHUNK_ID || '] (' || TITLE || ')' ||
                                                '\n' || CHUNK_TEXT, '\n\n')
                                        WITHIN GROUP (ORDER BY DOC_ID, CHUNK_INDEX), ''),
               'citations',    COALESCE(ARRAY_AGG(CHUNK_ID)
                                        WITHIN GROUP (ORDER BY DOC_ID, CHUNK_INDEX),
                                        ARRAY_CONSTRUCT()),
               'chunk_count',  COUNT(*))
      INTO :v_result
    FROM CAPSTONE_AI_DLC.GOVERNANCE.KNOWLEDGE_CHUNKS
    WHERE ARRAY_CONTAINS(CHUNK_ID::VARIANT, :v_ids);

    RETURN :v_result;
END;
$$;
