-- MART facts. Build order: FCT_LLM_USAGE, FCT_TOOL_CALL, FCT_CALL (reads the LLM cost sum).
-- MART carries hashes only: CALL_HASH (trace) and SPAN_HASH (span); no raw ids, text or user fields.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.MART;

-- One row per llm span.
CREATE OR REPLACE TABLE FCT_LLM_USAGE
CLUSTER BY (SPAN_DATE_PT)
COMMENT = 'One row per LLM span: model, tokens, cost, latency'
AS
SELECT
    SHA2(s.SPAN_ROW_ID, 256)                                AS SPAN_HASH,
    s.CALL_HASH,
    s.MODEL_NAME,
    s.START_TS_UTC::DATE                                    AS SPAN_DATE_UTC,
    s.START_TS_PT::DATE                                     AS SPAN_DATE_PT,
    s.START_TS_UTC::TIMESTAMP_NTZ(3)                        AS SPAN_START_TS_UTC,
    s.IS_NESTED,
    s.IS_ERROR,
    s.LATENCY_MS,
    s.PROMPT_TOKEN_COUNT,
    s.COMPLETION_TOKEN_COUNT,
    s.PROMPT_TOKEN_COUNT + s.COMPLETION_TOKEN_COUNT         AS TOTAL_TOKEN_COUNT,
    ROUND(s.PROMPT_TOKEN_COUNT     * m.INPUT_PRICE_PER_1M_AMOUNT  / 1e6, 6) AS INPUT_COST_AMOUNT,
    ROUND(s.COMPLETION_TOKEN_COUNT * m.OUTPUT_PRICE_PER_1M_AMOUNT / 1e6, 6) AS OUTPUT_COST_AMOUNT,
    ROUND(s.PROMPT_TOKEN_COUNT     * m.INPUT_PRICE_PER_1M_AMOUNT  / 1e6
        + s.COMPLETION_TOKEN_COUNT * m.OUTPUT_PRICE_PER_1M_AMOUNT / 1e6, 6) AS COST_AMOUNT,
    s.QUALITY_SCORE,
    a.ACCOUNT_ID
FROM AGENT_MEMENTO.STAGING.SPANS s
JOIN DIM_LLM_MODEL m ON m.MODEL_NAME = s.MODEL_NAME
JOIN DIM_CUSTOMER_ACCOUNT a ON FN_ACCOUNT_BUCKET(s.CALL_HASH) >= a.BUCKET_LO AND FN_ACCOUNT_BUCKET(s.CALL_HASH) < a.BUCKET_HI
WHERE s.SPAN_TYPE = 'llm';

-- One row per tool span, sequenced within the call.
CREATE OR REPLACE TABLE FCT_TOOL_CALL
CLUSTER BY (SPAN_DATE_PT)
COMMENT = 'One row per tool span: sequence, latency, error'
AS
SELECT
    SHA2(s.SPAN_ROW_ID, 256)                                AS SPAN_HASH,
    s.CALL_HASH,
    ROW_NUMBER() OVER (PARTITION BY s.CALL_HASH ORDER BY s.START_TS_UTC, s.SPAN_ROW_ID) AS TOOL_SEQ_NO,
    s.MODEL_NAME,
    s.START_TS_UTC::DATE                                    AS SPAN_DATE_UTC,
    s.START_TS_PT::DATE                                     AS SPAN_DATE_PT,
    s.START_TS_UTC::TIMESTAMP_NTZ(3)                        AS SPAN_START_TS_UTC,
    s.IS_NESTED,
    s.IS_ERROR,
    LAG(s.IS_ERROR) OVER (PARTITION BY s.CALL_HASH ORDER BY s.START_TS_UTC, s.SPAN_ROW_ID) AS IS_AFTER_ERROR,
    s.LATENCY_MS,
    s.QUALITY_SCORE,
    a.ACCOUNT_ID
FROM AGENT_MEMENTO.STAGING.SPANS s
JOIN DIM_CUSTOMER_ACCOUNT a ON FN_ACCOUNT_BUCKET(s.CALL_HASH) >= a.BUCKET_LO AND FN_ACCOUNT_BUCKET(s.CALL_HASH) < a.BUCKET_HI
WHERE s.SPAN_TYPE = 'tool';

-- One row per call. Anomaly = cost or duration more than 3 standard deviations above
-- the trailing 7-day mean (calls started in the previous 7 PT days).
CREATE OR REPLACE TABLE FCT_CALL
CLUSTER BY (CALL_DATE_PT)
COMMENT = 'One row per agent call: duration, volume, tokens, cost, outcome, intent, anomaly flags'
AS
WITH cost AS (
    SELECT CALL_HASH,
           SUM(COST_AMOUNT)        AS COST_AMOUNT,
           SUM(INPUT_COST_AMOUNT)  AS INPUT_COST_AMOUNT,
           SUM(OUTPUT_COST_AMOUNT) AS OUTPUT_COST_AMOUNT
    FROM FCT_LLM_USAGE GROUP BY CALL_HASH
),
c AS (
    SELECT k.*, COALESCE(x.COST_AMOUNT, 0) AS COST_AMOUNT,
           COALESCE(x.INPUT_COST_AMOUNT, 0) AS INPUT_COST_AMOUNT,
           COALESCE(x.OUTPUT_COST_AMOUNT, 0) AS OUTPUT_COST_AMOUNT
    FROM AGENT_MEMENTO.STAGING.CALLS k LEFT JOIN cost x USING (CALL_HASH)
),
day_stats AS (
    SELECT CALL_DATE_PT, COUNT(*) n,
           SUM(COST_AMOUNT) s_cost, SUM(COST_AMOUNT * COST_AMOUNT) ss_cost,
           SUM(DURATION_SECONDS) s_dur, SUM(DURATION_SECONDS * DURATION_SECONDS) ss_dur
    FROM c GROUP BY 1
),
baseline AS (
    SELECT d.CALL_DATE_PT,
           SUM(p.n) n, SUM(p.s_cost) / NULLIF(SUM(p.n), 0) mean_cost,
           SQRT(GREATEST(SUM(p.ss_cost) / NULLIF(SUM(p.n), 0) - POWER(SUM(p.s_cost) / NULLIF(SUM(p.n), 0), 2), 0)) sd_cost,
           SUM(p.s_dur) / NULLIF(SUM(p.n), 0) mean_dur,
           SQRT(GREATEST(SUM(p.ss_dur) / NULLIF(SUM(p.n), 0) - POWER(SUM(p.s_dur) / NULLIF(SUM(p.n), 0), 2), 0)) sd_dur
    FROM day_stats d
    JOIN day_stats p ON p.CALL_DATE_PT BETWEEN DATEADD('day', -7, d.CALL_DATE_PT) AND DATEADD('day', -1, d.CALL_DATE_PT)
    GROUP BY d.CALL_DATE_PT
)
SELECT
    c.CALL_HASH,
    c.CALL_DATE_UTC,
    c.CALL_DATE_PT,
    c.CALL_START_TS_UTC::TIMESTAMP_NTZ(3)                   AS CALL_START_TS_UTC,
    c.CALL_START_TS_PT,
    c.CALL_END_TS_UTC::TIMESTAMP_NTZ(3)                     AS CALL_END_TS_UTC,
    HOUR(c.CALL_START_TS_PT)                                AS CALL_HOUR_PT,
    c.ROOT_MODEL_NAME                                       AS MODEL_NAME,
    c.INTENT_TAG,
    c.OUTCOME_CODE,
    c.HAS_ROOT,
    c.ROOT_COUNT,
    c.IS_ROOT_ERROR,
    c.DURATION_SECONDS::NUMBER(18,3)                        AS DURATION_SECONDS,
    c.SPAN_COUNT, c.LLM_CALL_COUNT, c.TOOL_CALL_COUNT, c.TASK_COUNT, c.NESTED_SPAN_COUNT,
    c.ERROR_SPAN_COUNT, c.LLM_ERROR_COUNT, c.TOOL_ERROR_COUNT,
    c.PROMPT_TOKEN_COUNT, c.COMPLETION_TOKEN_COUNT,
    c.PROMPT_TOKEN_COUNT + c.COMPLETION_TOKEN_COUNT         AS TOTAL_TOKEN_COUNT,
    c.LLM_LATENCY_MS, c.TOOL_LATENCY_MS,
    c.QUALITY_SCORE,
    c.AVG_SPAN_QUALITY_SCORE,
    c.COST_AMOUNT::NUMBER(18,6)                             AS COST_AMOUNT,
    c.INPUT_COST_AMOUNT::NUMBER(18,6)                       AS INPUT_COST_AMOUNT,
    c.OUTPUT_COST_AMOUNT::NUMBER(18,6)                      AS OUTPUT_COST_AMOUNT,
    COALESCE(b.n >= 1000 AND c.COST_AMOUNT > b.mean_cost + 3 * b.sd_cost, FALSE)          AS IS_COST_ANOMALY,
    COALESCE(b.n >= 1000 AND c.DURATION_SECONDS > b.mean_dur + 3 * b.sd_dur, FALSE)       AS IS_DURATION_ANOMALY,
    -- Account economics: revenue per billable minute; COGS = model cost + telephony.
    acc.ORG_ID,
    acc.ACCOUNT_ID,
    CEIL(c.DURATION_SECONDS / 60)::NUMBER(18,0)                                           AS BILLABLE_MINUTES,
    (CEIL(c.DURATION_SECONDS / 60) * acc.CONTRACT_PRICE_PER_MIN_AMOUNT)::NUMBER(18,6)     AS REVENUE_AMOUNT,
    (CEIL(c.DURATION_SECONDS / 60) * r.TELEPHONY_COST_PER_MIN_AMOUNT)::NUMBER(18,6)       AS TELEPHONY_COST_AMOUNT,
    (c.COST_AMOUNT + CEIL(c.DURATION_SECONDS / 60) * r.TELEPHONY_COST_PER_MIN_AMOUNT)::NUMBER(18,6) AS COGS_AMOUNT,
    (CEIL(c.DURATION_SECONDS / 60) * (acc.CONTRACT_PRICE_PER_MIN_AMOUNT - r.TELEPHONY_COST_PER_MIN_AMOUNT)
        - c.COST_AMOUNT)::NUMBER(18,6)                                                    AS GROSS_MARGIN_AMOUNT,
    CURRENT_ROLE()                                          AS INSERTED_BY,
    CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)                    AS INSERTED_TS_PT
FROM c
LEFT JOIN baseline b ON b.CALL_DATE_PT = c.CALL_DATE_PT
JOIN DIM_CUSTOMER_ACCOUNT acc ON FN_ACCOUNT_BUCKET(c.CALL_HASH) >= acc.BUCKET_LO AND FN_ACCOUNT_BUCKET(c.CALL_HASH) < acc.BUCKET_HI
CROSS JOIN DIM_COST_RATE r;
