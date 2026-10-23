-- STAGING: typed spans, then one row per call (trace). Rebuildable from RAW; transient.
-- Call key: ROOT_SPAN_ID. metadata.session_id is unique per span in this data, so it is not a call key.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.STAGING;

-- 1. SPANS: one row per ID (RAW has no duplicate IDs, so no version dedup is needed).
CREATE OR REPLACE TRANSIENT TABLE SPANS
CLUSTER BY (EVENT_DATE_UTC, ROOT_SPAN_ID)
COMMENT = 'Typed Braintrust spans, one row per span ID'
AS
SELECT
    s.ID                                                    AS SPAN_ROW_ID,
    s.SPAN_ID,
    s.ROOT_SPAN_ID,
    AGENT_MEMENTO.GOVERNANCE.FN_CALL_HASH(s.ROOT_SPAN_ID)   AS CALL_HASH,
    s.SPAN_PARENTS[0]::STRING                               AS PARENT_SPAN_ID,
    s.IS_ROOT,
    COALESCE(s.SPAN_PARENTS[0]::STRING <> s.ROOT_SPAN_ID, FALSE) AND NOT s.IS_ROOT AS IS_NESTED,
    COALESCE(s.SPAN_ATTRIBUTES:type::STRING, 'unknown')     AS SPAN_TYPE,
    s.SPAN_ATTRIBUTES:name::STRING                          AS SPAN_NAME,
    COALESCE(s.METADATA:model::STRING, 'unknown')           AS MODEL_NAME,
    COALESCE(s.TAGS[0]::STRING, 'untagged')                 AS TAG,
    s.CREATED::TIMESTAMP_NTZ(6)                             AS START_TS_UTC,
    DATEADD('millisecond', s.METRICS:latency_ms::NUMBER, s.CREATED)::TIMESTAMP_NTZ(6) AS END_TS_UTC,
    CONVERT_TIMEZONE('UTC', 'America/Los_Angeles', s.CREATED::TIMESTAMP_NTZ)::TIMESTAMP_TZ(3) AS START_TS_PT,
    s.METRICS:latency_ms::NUMBER(18,0)                      AS LATENCY_MS,
    s.METRICS:prompt_tokens::NUMBER(18,0)                   AS PROMPT_TOKEN_COUNT,
    s.METRICS:completion_tokens::NUMBER(18,0)               AS COMPLETION_TOKEN_COUNT,
    s.SCORES:score_1::FLOAT                                 AS QUALITY_SCORE,
    s.ERROR IS NOT NULL                                     AS IS_ERROR,
    s.ERROR:message::STRING                                 AS ERROR_MESSAGE,
    s.METADATA:session_id::STRING                           AS SESSION_ID,
    s.METADATA:user_email::STRING                           AS USER_EMAIL,
    s.METADATA:user_name::STRING                            AS USER_NAME,
    s.INPUT,
    s.OUTPUT,
    s.EVENT_DT                                              AS EVENT_DATE_UTC,
    s.PROJECT_NAME,
    s._SOURCE_FILE                                          AS SOURCE_FILE,
    CURRENT_ROLE()                                          AS INSERTED_BY,
    CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)                    AS INSERTED_TS_PT,
    LAST_QUERY_ID()                                         AS INSERTED_BY_QUERY_ID
FROM AGENT_MEMENTO.RAW.BRAINTRUST_SPANS s;

-- 2. CALLS: one row per ROOT_SPAN_ID. Attributes from the earliest root; measures from all spans.
--    Tokens are taken from llm spans only (tool/task token metrics are not billed in this model).
CREATE OR REPLACE TRANSIENT TABLE CALLS
CLUSTER BY (CALL_DATE_UTC)
COMMENT = 'One row per agent call (trace), with deterministic outcome and intent'
AS
WITH roots AS (
    SELECT ROOT_SPAN_ID, MODEL_NAME, TAG, QUALITY_SCORE, IS_ERROR, LATENCY_MS
    FROM SPANS
    WHERE IS_ROOT
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ROOT_SPAN_ID ORDER BY START_TS_UTC, SPAN_ROW_ID) = 1
),
agg AS (
    SELECT
        ROOT_SPAN_ID,
        ANY_VALUE(CALL_HASH)                                   AS CALL_HASH,
        COUNT_IF(IS_ROOT)                                      AS ROOT_COUNT,
        MIN(START_TS_UTC)                                      AS CALL_START_TS_UTC,
        MAX(END_TS_UTC)                                        AS CALL_END_TS_UTC,
        COUNT(*)                                               AS SPAN_COUNT,
        COUNT_IF(SPAN_TYPE = 'llm')                            AS LLM_CALL_COUNT,
        COUNT_IF(SPAN_TYPE = 'tool')                           AS TOOL_CALL_COUNT,
        COUNT_IF(SPAN_TYPE = 'task')                           AS TASK_COUNT,
        COUNT_IF(IS_NESTED)                                    AS NESTED_SPAN_COUNT,
        COUNT_IF(IS_ERROR)                                     AS ERROR_SPAN_COUNT,
        COUNT_IF(IS_ERROR AND SPAN_TYPE = 'llm')               AS LLM_ERROR_COUNT,
        COUNT_IF(IS_ERROR AND SPAN_TYPE = 'tool')              AS TOOL_ERROR_COUNT,
        SUM(IFF(SPAN_TYPE = 'llm', PROMPT_TOKEN_COUNT, 0))     AS PROMPT_TOKEN_COUNT,
        SUM(IFF(SPAN_TYPE = 'llm', COMPLETION_TOKEN_COUNT, 0)) AS COMPLETION_TOKEN_COUNT,
        SUM(IFF(SPAN_TYPE = 'llm', LATENCY_MS, 0))             AS LLM_LATENCY_MS,
        SUM(IFF(SPAN_TYPE = 'tool', LATENCY_MS, 0))            AS TOOL_LATENCY_MS,
        AVG(QUALITY_SCORE)                                     AS AVG_SPAN_QUALITY_SCORE,
        COUNT(DISTINCT EVENT_DATE_UTC)                         AS EVENT_DAY_COUNT
    FROM SPANS
    GROUP BY ROOT_SPAN_ID
)
SELECT
    a.CALL_HASH,
    a.ROOT_SPAN_ID,
    a.ROOT_COUNT,
    a.ROOT_COUNT > 0                                          AS HAS_ROOT,
    a.CALL_START_TS_UTC,
    a.CALL_END_TS_UTC,
    CONVERT_TIMEZONE('UTC', 'America/Los_Angeles', a.CALL_START_TS_UTC)::TIMESTAMP_TZ(3) AS CALL_START_TS_PT,
    a.CALL_START_TS_UTC::DATE                                 AS CALL_DATE_UTC,
    CONVERT_TIMEZONE('UTC', 'America/Los_Angeles', a.CALL_START_TS_UTC)::DATE AS CALL_DATE_PT,
    DATEDIFF('millisecond', a.CALL_START_TS_UTC, a.CALL_END_TS_UTC) / 1000 AS DURATION_SECONDS,
    COALESCE(r.MODEL_NAME, 'unknown')                         AS ROOT_MODEL_NAME,
    COALESCE(r.TAG, 'untagged')                               AS INTENT_TAG,
    r.QUALITY_SCORE                                           AS QUALITY_SCORE,
    COALESCE(r.IS_ERROR, FALSE)                               AS IS_ROOT_ERROR,
    a.SPAN_COUNT, a.LLM_CALL_COUNT, a.TOOL_CALL_COUNT, a.TASK_COUNT, a.NESTED_SPAN_COUNT,
    a.ERROR_SPAN_COUNT, a.LLM_ERROR_COUNT, a.TOOL_ERROR_COUNT,
    a.PROMPT_TOKEN_COUNT, a.COMPLETION_TOKEN_COUNT, a.LLM_LATENCY_MS, a.TOOL_LATENCY_MS,
    a.AVG_SPAN_QUALITY_SCORE, a.EVENT_DAY_COUNT,
    -- Outcome rules, evaluated in order. Thresholds are documented in docs/Architecture.md.
    CASE
        WHEN a.ROOT_COUNT = 0                       THEN 'INCOMPLETE'
        WHEN COALESCE(r.IS_ERROR, FALSE)            THEN 'FAILED'
        WHEN a.ERROR_SPAN_COUNT > 0                 THEN 'RECOVERED'
        WHEN r.QUALITY_SCORE < 0.3                  THEN 'RESOLVED_LOW_QUALITY'
        ELSE 'RESOLVED'
    END                                                       AS OUTCOME_CODE,
    CURRENT_ROLE()                                            AS INSERTED_BY,
    CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)                      AS INSERTED_TS_PT,
    LAST_QUERY_ID()                                           AS INSERTED_BY_QUERY_ID
FROM agg a
LEFT JOIN roots r ON r.ROOT_SPAN_ID = a.ROOT_SPAN_ID;
