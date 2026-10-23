-- Autonomous supervisor: detect signals in SQL, have Claude draft the wording, propose actions, humans decide.
-- Numbers always come from SQL; the model only writes title / diagnosis / recommendation from aggregates (no PHI).
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.OPS;

CREATE TABLE IF NOT EXISTS AGENT_SIGNALS (
    SIGNAL_KEY          STRING NOT NULL PRIMARY KEY,
    SIGNAL_TYPE         STRING NOT NULL,
    ENTITY_TYPE         STRING NOT NULL,
    ENTITY_ID           STRING NOT NULL,
    ENTITY_NAME         STRING,
    AS_OF_DATE          DATE NOT NULL,
    METRIC_VALUE        FLOAT,
    BASELINE_VALUE      FLOAT,
    IMPACT_AMOUNT       NUMBER(18,2),
    OWNER_PERSONA       STRING,
    EVIDENCE            VARIANT,
    INSERTED_TS_PT      TIMESTAMP_TZ(3) DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)
) COMMENT = 'Signals detected by SQL rules over a 7-day window; aggregates only';

CREATE TABLE IF NOT EXISTS AGENT_ACTIONS (
    ACTION_ID                   NUMBER AUTOINCREMENT START 1 INCREMENT 1 PRIMARY KEY,
    SIGNAL_KEY                  STRING NOT NULL UNIQUE,
    SIGNAL_TYPE                 STRING,
    ENTITY_TYPE                 STRING,
    ENTITY_ID                   STRING,
    ENTITY_NAME                 STRING,
    AS_OF_DATE                  DATE,
    OWNER_PERSONA               STRING,
    TITLE                       STRING,
    DIAGNOSIS_TEXT              STRING,
    RECOMMENDATION_TEXT         STRING,
    PROJECTED_SAVINGS_AMOUNT    NUMBER(18,2),
    AI_MODEL                    STRING,
    DRAFT_STATUS                STRING,
    STATUS                      STRING DEFAULT 'PROPOSED',
    DECIDED_BY                  STRING,
    DECIDED_ROLE                STRING,
    DECIDED_PERSONA             STRING,
    DECIDED_TS_PT               TIMESTAMP_TZ(3),
    DECISION_NOTE               STRING,
    INSERTED_TS_PT              TIMESTAMP_TZ(3) DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)
) COMMENT = 'Supervisor proposals and human decisions (audit trail)';

CREATE TABLE IF NOT EXISTS AGENT_RUN_LOG (
    RUN_ID          STRING NOT NULL PRIMARY KEY,
    PROC_NAME       STRING,
    AS_OF_DATE      DATE,
    STARTED_TS_PT   TIMESTAMP_TZ(3),
    ENDED_TS_PT     TIMESTAMP_TZ(3),
    SIGNAL_COUNT    NUMBER,
    ACTION_COUNT    NUMBER,
    STATUS          STRING,
    ERROR_MESSAGE   STRING,
    RUN_BY_ROLE     STRING
) COMMENT = 'One row per supervisor run';

-- 1. DETECT: rules over the 7 PT days ending P_AS_OF_DATE vs the 7 days before. Idempotent on SIGNAL_KEY.
CREATE OR REPLACE PROCEDURE PROC_DETECT_SIGNALS(P_AS_OF_DATE DATE)
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_before NUMBER;
    v_after  NUMBER;
BEGIN
    v_before := (SELECT COUNT(*) FROM AGENT_MEMENTO.OPS.AGENT_SIGNALS);

    MERGE INTO AGENT_MEMENTO.OPS.AGENT_SIGNALS t
    USING (
        WITH w AS (
            SELECT f.*, IFF(f.CALL_DATE_PT > DATEADD('day', -7, :P_AS_OF_DATE), 'CUR', 'PRIOR') AS WIN
            FROM AGENT_MEMENTO.MART.FCT_CALL f
            WHERE f.CALL_DATE_PT BETWEEN DATEADD('day', -13, :P_AS_OF_DATE) AND :P_AS_OF_DATE
        ),
        acct AS (
            SELECT w.ACCOUNT_ID, a.ACCOUNT_NAME, a.CONTRACT_PRICE_PER_MIN_AMOUNT AS PRICE,
                   COUNT_IF(WIN = 'CUR') AS CALLS,
                   SUM(IFF(WIN = 'CUR', BILLABLE_MINUTES, 0)) AS MINUTES,
                   SUM(IFF(WIN = 'CUR', REVENUE_AMOUNT, 0)) AS REVENUE,
                   SUM(IFF(WIN = 'CUR', COGS_AMOUNT, 0)) AS COGS,
                   SUM(IFF(WIN = 'CUR', COST_AMOUNT, 0)) AS MODEL_COST,
                   SUM(IFF(WIN = 'CUR', TELEPHONY_COST_AMOUNT, 0)) AS TELEPHONY_COST,
                   SUM(IFF(WIN = 'CUR', GROSS_MARGIN_AMOUNT, 0)) AS MARGIN,
                   COUNT_IF(WIN = 'PRIOR') AS PRIOR_CALLS,
                   COUNT_IF(WIN = 'CUR' AND OUTCOME_CODE IN ('FAILED', 'INCOMPLETE')) / NULLIF(COUNT_IF(WIN = 'CUR'), 0) AS FAIL_RATE,
                   COUNT_IF(WIN = 'PRIOR' AND OUTCOME_CODE IN ('FAILED', 'INCOMPLETE')) / NULLIF(COUNT_IF(WIN = 'PRIOR'), 0) AS PRIOR_FAIL_RATE,
                   COUNT_IF(WIN = 'CUR' AND (IS_COST_ANOMALY OR IS_DURATION_ANOMALY)) / NULLIF(COUNT_IF(WIN = 'CUR'), 0) AS ANOM_RATE,
                   COUNT_IF(WIN = 'PRIOR' AND (IS_COST_ANOMALY OR IS_DURATION_ANOMALY)) / NULLIF(COUNT_IF(WIN = 'PRIOR'), 0) AS PRIOR_ANOM_RATE
            FROM w JOIN AGENT_MEMENTO.MART.DIM_CUSTOMER_ACCOUNT a USING (ACCOUNT_ID)
            GROUP BY 1, 2, 3
        ),
        neg_margin AS (
            SELECT 'NEGATIVE_MARGIN_ACCOUNT' AS SIGNAL_TYPE, 'ACCOUNT' AS ENTITY_TYPE, ACCOUNT_ID AS ENTITY_ID, ACCOUNT_NAME AS ENTITY_NAME,
                   MARGIN / NULLIF(REVENUE, 0) AS METRIC_VALUE, 0.25 AS BASELINE_VALUE,
                   ROUND(-MARGIN * 30 / 7, 2) AS IMPACT_AMOUNT, 'Finance' AS OWNER_PERSONA,
                   OBJECT_CONSTRUCT('window_days', 7, 'calls', CALLS, 'billable_minutes', MINUTES,
                        'revenue_usd', ROUND(REVENUE, 2), 'cogs_usd', ROUND(COGS, 2), 'model_cost_usd', ROUND(MODEL_COST, 2),
                        'telephony_cost_usd', ROUND(TELEPHONY_COST, 2), 'gross_margin_usd', ROUND(MARGIN, 2),
                        'gross_margin_pct', ROUND(100 * MARGIN / NULLIF(REVENUE, 0), 1),
                        'contract_price_per_min', PRICE, 'cogs_per_min', ROUND(COGS / NULLIF(MINUTES, 0), 4),
                        'price_for_25pct_margin', ROUND(COGS / NULLIF(MINUTES, 0) / 0.75, 4),
                        'monthly_loss_run_rate_usd', ROUND(-MARGIN * 30 / 7, 2)) AS EVIDENCE
            FROM acct WHERE MARGIN < 0
        ),
        -- Account spikes only when they exceed the platform-wide change; a platform-wide shift is one signal.
        platform AS (
            SELECT SUM(CALLS) AS P_CALLS,
                   SUM(ANOM_RATE * CALLS) / NULLIF(SUM(CALLS), 0) AS P_ANOM_RATE,
                   SUM(PRIOR_ANOM_RATE * PRIOR_CALLS) / NULLIF(SUM(PRIOR_CALLS), 0) AS P_PRIOR_ANOM_RATE,
                   (SUM(ANOM_RATE * CALLS) / NULLIF(SUM(CALLS), 0)) / NULLIF(SUM(PRIOR_ANOM_RATE * PRIOR_CALLS) / NULLIF(SUM(PRIOR_CALLS), 0), 0) AS P_ANOM_RATIO,
                   (SUM(FAIL_RATE * CALLS) / NULLIF(SUM(CALLS), 0)) / NULLIF(SUM(PRIOR_FAIL_RATE * PRIOR_CALLS) / NULLIF(SUM(PRIOR_CALLS), 0), 0) AS P_FAIL_RATIO,
                   SUM(PRIOR_CALLS) AS P_PRIOR_CALLS
            FROM acct
        ),
        fail_spike AS (
            SELECT 'FAILURE_SPIKE', 'ACCOUNT', ACCOUNT_ID, ACCOUNT_NAME, FAIL_RATE, PRIOR_FAIL_RATE,
                   NULL, 'Agent PM',
                   OBJECT_CONSTRUCT('window_days', 7, 'calls', CALLS, 'failure_rate_pct', ROUND(100 * FAIL_RATE, 2),
                        'prior_failure_rate_pct', ROUND(100 * PRIOR_FAIL_RATE, 2), 'ratio', ROUND(FAIL_RATE / NULLIF(PRIOR_FAIL_RATE, 0), 2),
                        'platform_ratio', ROUND(p.P_FAIL_RATIO, 2))
            FROM acct, platform p
            WHERE PRIOR_CALLS >= 500 AND FAIL_RATE > 1.3 * PRIOR_FAIL_RATE
              AND FAIL_RATE / NULLIF(PRIOR_FAIL_RATE, 0) > 1.2 * p.P_FAIL_RATIO
        ),
        anom_spike AS (
            SELECT 'ANOMALY_SPIKE', 'ACCOUNT', ACCOUNT_ID, ACCOUNT_NAME, ANOM_RATE, PRIOR_ANOM_RATE,
                   NULL, 'CSM',
                   OBJECT_CONSTRUCT('window_days', 7, 'calls', CALLS, 'anomaly_rate_pct', ROUND(100 * ANOM_RATE, 2),
                        'prior_anomaly_rate_pct', ROUND(100 * PRIOR_ANOM_RATE, 2), 'ratio', ROUND(ANOM_RATE / NULLIF(PRIOR_ANOM_RATE, 0), 2),
                        'platform_ratio', ROUND(p.P_ANOM_RATIO, 2))
            FROM acct, platform p
            WHERE PRIOR_CALLS >= 500 AND ANOM_RATE > 1.5 * PRIOR_ANOM_RATE
              AND ANOM_RATE / NULLIF(PRIOR_ANOM_RATE, 0) > 1.2 * p.P_ANOM_RATIO
            UNION ALL
            SELECT 'ANOMALY_SPIKE', 'PLATFORM', 'ALL', 'All accounts', P_ANOM_RATE, P_PRIOR_ANOM_RATE, NULL, 'Agent PM',
                   OBJECT_CONSTRUCT('window_days', 7, 'calls', P_CALLS, 'anomaly_rate_pct', ROUND(100 * P_ANOM_RATE, 2),
                        'prior_anomaly_rate_pct', ROUND(100 * P_PRIOR_ANOM_RATE, 2), 'ratio', ROUND(P_ANOM_RATIO, 2),
                        'scope', 'Platform-wide: every account moved together')
            FROM platform WHERE P_PRIOR_CALLS >= 4000 AND P_ANOM_RATIO > 1.5
        ),
        -- Premium model share of LLM cost per intent; savings = premium spend re-priced at the Standard tier.
        llm AS (
            SELECT c.INTENT_TAG, i.INTENT_NAME, u.MODEL_NAME, m.MODEL_TIER,
                   SUM(u.COST_AMOUNT) AS COST,
                   SUM(u.PROMPT_TOKEN_COUNT) AS PT, SUM(u.COMPLETION_TOKEN_COUNT) AS CT
            FROM AGENT_MEMENTO.MART.FCT_LLM_USAGE u
            JOIN AGENT_MEMENTO.MART.FCT_CALL c USING (CALL_HASH)
            JOIN AGENT_MEMENTO.MART.DIM_LLM_MODEL m ON m.MODEL_NAME = u.MODEL_NAME
            JOIN AGENT_MEMENTO.MART.DIM_INTENT i ON i.INTENT_TAG = c.INTENT_TAG
            WHERE c.CALL_DATE_PT BETWEEN DATEADD('day', -6, :P_AS_OF_DATE) AND :P_AS_OF_DATE
            GROUP BY 1, 2, 3, 4
        ),
        std AS (SELECT INPUT_PRICE_PER_1M_AMOUNT AS IP, OUTPUT_PRICE_PER_1M_AMOUNT AS OP, MAPPED_MODEL_NAME
                FROM AGENT_MEMENTO.MART.DIM_LLM_MODEL WHERE MODEL_TIER = 'Standard'),
        intent_mix AS (
            SELECT l.INTENT_TAG, l.INTENT_NAME,
                   SUM(l.COST) AS TOTAL_COST,
                   SUM(IFF(l.MODEL_TIER = 'Premium', l.COST, 0)) AS PREMIUM_COST,
                   SUM(IFF(l.MODEL_TIER = 'Premium', (l.PT * s.IP + l.CT * s.OP) / 1e6, 0)) AS PREMIUM_AT_STANDARD,
                   ANY_VALUE(s.MAPPED_MODEL_NAME) AS STANDARD_MODEL
            FROM llm l CROSS JOIN std s
            GROUP BY 1, 2
        ),
        model_shift AS (
            SELECT 'MODEL_COST_SHIFT', 'INTENT', INTENT_TAG, INTENT_NAME, PREMIUM_COST / NULLIF(TOTAL_COST, 0), 0.40,
                   ROUND((PREMIUM_COST - PREMIUM_AT_STANDARD) * 30 / 7, 2), 'Agent PM',
                   OBJECT_CONSTRUCT('window_days', 7, 'llm_cost_usd', ROUND(TOTAL_COST, 2), 'premium_cost_usd', ROUND(PREMIUM_COST, 2),
                        'premium_share_pct', ROUND(100 * PREMIUM_COST / NULLIF(TOTAL_COST, 0), 1),
                        'premium_cost_at_standard_price_usd', ROUND(PREMIUM_AT_STANDARD, 2),
                        'standard_model', STANDARD_MODEL,
                        'monthly_savings_run_rate_usd', ROUND((PREMIUM_COST - PREMIUM_AT_STANDARD) * 30 / 7, 2))
            FROM intent_mix WHERE PREMIUM_COST / NULLIF(TOTAL_COST, 0) > 0.40
              AND (PREMIUM_COST - PREMIUM_AT_STANDARD) * 30 / 7 >= 100
        ),
        allsig AS (
            SELECT * FROM neg_margin UNION ALL SELECT * FROM fail_spike
            UNION ALL SELECT * FROM anom_spike UNION ALL SELECT * FROM model_shift
        )
        SELECT SIGNAL_TYPE || '|' || ENTITY_ID || '|' || TO_CHAR(:P_AS_OF_DATE, 'YYYY-MM-DD') AS SIGNAL_KEY, a.*, :P_AS_OF_DATE AS AS_OF_DATE
        FROM allsig a
    ) s
    ON t.SIGNAL_KEY = s.SIGNAL_KEY
    WHEN NOT MATCHED THEN INSERT
        (SIGNAL_KEY, SIGNAL_TYPE, ENTITY_TYPE, ENTITY_ID, ENTITY_NAME, AS_OF_DATE, METRIC_VALUE, BASELINE_VALUE, IMPACT_AMOUNT, OWNER_PERSONA, EVIDENCE)
        VALUES (s.SIGNAL_KEY, s.SIGNAL_TYPE, s.ENTITY_TYPE, s.ENTITY_ID, s.ENTITY_NAME, s.AS_OF_DATE, s.METRIC_VALUE, s.BASELINE_VALUE, s.IMPACT_AMOUNT, s.OWNER_PERSONA, s.EVIDENCE);

    v_after := (SELECT COUNT(*) FROM AGENT_MEMENTO.OPS.AGENT_SIGNALS);
    RETURN v_after - v_before;
END;
$$;

-- 2. DRAFT: one action per new signal. Claude writes the wording from the evidence JSON only.
CREATE OR REPLACE PROCEDURE PROC_DRAFT_ACTIONS(P_AS_OF_DATE DATE)
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_before NUMBER;
BEGIN
    v_before := (SELECT COUNT(*) FROM AGENT_MEMENTO.OPS.AGENT_ACTIONS);
    BEGIN
        INSERT INTO AGENT_MEMENTO.OPS.AGENT_ACTIONS
            (SIGNAL_KEY, SIGNAL_TYPE, ENTITY_TYPE, ENTITY_ID, ENTITY_NAME, AS_OF_DATE, OWNER_PERSONA,
             TITLE, DIAGNOSIS_TEXT, RECOMMENDATION_TEXT, PROJECTED_SAVINGS_AMOUNT, AI_MODEL, DRAFT_STATUS)
        WITH todo AS (
            SELECT s.* FROM AGENT_MEMENTO.OPS.AGENT_SIGNALS s
            LEFT JOIN AGENT_MEMENTO.OPS.AGENT_ACTIONS a ON a.SIGNAL_KEY = s.SIGNAL_KEY
            WHERE a.SIGNAL_KEY IS NULL AND s.AS_OF_DATE = :P_AS_OF_DATE
        ),
        drafted AS (
            SELECT t.*,
                   TRY_PARSE_JSON(AI_COMPLETE(
                       model => 'claude-sonnet-4-5',
                       prompt => 'You are the operations supervisor for a voice AI agent platform. Write for the ' || t.OWNER_PERSONA
                              || ' persona. Use ONLY the numbers in the evidence; do not invent figures. Be concise: title <= 12 words, '
                              || 'diagnosis <= 3 sentences, recommendation = 2-3 concrete steps. Signal: ' || t.SIGNAL_TYPE
                              || ' for ' || t.ENTITY_TYPE || ' "' || t.ENTITY_NAME || '" (week ending ' || TO_CHAR(t.AS_OF_DATE)
                              || '). Evidence: ' || t.EVIDENCE::STRING,
                       model_parameters => {'temperature': 0, 'max_tokens': 500},
                       response_format => {'type': 'json', 'schema': {'type': 'object',
                           'properties': {'title': {'type': 'string'}, 'diagnosis': {'type': 'string'}, 'recommendation': {'type': 'string'}},
                           'required': ['title', 'diagnosis', 'recommendation']}}
                   )) AS J
            FROM todo t
        )
        SELECT SIGNAL_KEY, SIGNAL_TYPE, ENTITY_TYPE, ENTITY_ID, ENTITY_NAME, AS_OF_DATE, OWNER_PERSONA,
               COALESCE(J:title::STRING, SIGNAL_TYPE || ': ' || ENTITY_NAME),
               COALESCE(J:diagnosis::STRING, 'Rule ' || SIGNAL_TYPE || ' fired. Evidence: ' || EVIDENCE::STRING),
               COALESCE(J:recommendation::STRING, 'Review the evidence and decide.'),
               IMPACT_AMOUNT, 'claude-sonnet-4-5', IFF(J IS NULL, 'AI_FAILED', 'AI_DRAFTED')
        FROM drafted;
    EXCEPTION
        WHEN OTHER THEN
            -- Model unavailable: still propose, with the SQL evidence as the text.
            INSERT INTO AGENT_MEMENTO.OPS.AGENT_ACTIONS
                (SIGNAL_KEY, SIGNAL_TYPE, ENTITY_TYPE, ENTITY_ID, ENTITY_NAME, AS_OF_DATE, OWNER_PERSONA,
                 TITLE, DIAGNOSIS_TEXT, RECOMMENDATION_TEXT, PROJECTED_SAVINGS_AMOUNT, AI_MODEL, DRAFT_STATUS)
            SELECT s.SIGNAL_KEY, s.SIGNAL_TYPE, s.ENTITY_TYPE, s.ENTITY_ID, s.ENTITY_NAME, s.AS_OF_DATE, s.OWNER_PERSONA,
                   s.SIGNAL_TYPE || ': ' || s.ENTITY_NAME, 'Rule ' || s.SIGNAL_TYPE || ' fired. Evidence: ' || s.EVIDENCE::STRING,
                   'Review the evidence and decide.', s.IMPACT_AMOUNT, NULL, 'AI_FAILED'
            FROM AGENT_MEMENTO.OPS.AGENT_SIGNALS s
            LEFT JOIN AGENT_MEMENTO.OPS.AGENT_ACTIONS a ON a.SIGNAL_KEY = s.SIGNAL_KEY
            WHERE a.SIGNAL_KEY IS NULL AND s.AS_OF_DATE = :P_AS_OF_DATE;
    END;
    RETURN (SELECT COUNT(*) FROM AGENT_MEMENTO.OPS.AGENT_ACTIONS) - v_before;
END;
$$;

-- 3. RUN: detect + draft + log. P_AS_OF_DATE NULL = latest call date in the mart.
CREATE OR REPLACE PROCEDURE PROC_RUN_SUPERVISOR(P_AS_OF_DATE DATE)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id  STRING DEFAULT UUID_STRING();
    v_asof    DATE;
    v_started TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP();
    v_sig     NUMBER DEFAULT 0;
    v_act     NUMBER DEFAULT 0;
    v_err     STRING;
BEGIN
    v_asof := COALESCE(:P_AS_OF_DATE, (SELECT MAX(CALL_DATE_PT) FROM AGENT_MEMENTO.MART.FCT_CALL));
    CALL AGENT_MEMENTO.OPS.PROC_DETECT_SIGNALS(:v_asof) INTO :v_sig;
    CALL AGENT_MEMENTO.OPS.PROC_DRAFT_ACTIONS(:v_asof) INTO :v_act;
    INSERT INTO AGENT_MEMENTO.OPS.AGENT_RUN_LOG
        SELECT :v_run_id, 'PROC_RUN_SUPERVISOR', :v_asof, :v_started, CURRENT_TIMESTAMP(), :v_sig, :v_act, 'SUCCEEDED', NULL, CURRENT_ROLE();
    RETURN OBJECT_CONSTRUCT('run_id', v_run_id, 'as_of_date', v_asof, 'signals', v_sig, 'actions', v_act);
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        INSERT INTO AGENT_MEMENTO.OPS.AGENT_RUN_LOG
            SELECT :v_run_id, 'PROC_RUN_SUPERVISOR', :v_asof, :v_started, CURRENT_TIMESTAMP(), :v_sig, :v_act, 'FAILED', :v_err, CURRENT_ROLE();
        RAISE;
END;
$$;

-- 4. DECIDE: human approval. Caller's rights so DECIDED_ROLE is the real role.
CREATE OR REPLACE PROCEDURE PROC_DECIDE_ACTION(P_ACTION_ID NUMBER, P_DECISION STRING, P_PERSONA STRING, P_NOTE STRING)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_status STRING;
BEGIN
    IF (UPPER(:P_DECISION) NOT IN ('APPROVED', 'REJECTED')) THEN
        RETURN 'ERROR: decision must be APPROVED or REJECTED';
    END IF;
    v_status := (SELECT MAX(STATUS) FROM AGENT_MEMENTO.OPS.AGENT_ACTIONS WHERE ACTION_ID = :P_ACTION_ID);
    IF (v_status IS NULL) THEN
        RETURN 'ERROR: action not found';
    END IF;
    IF (v_status <> 'PROPOSED') THEN
        RETURN 'ERROR: action already ' || v_status;
    END IF;
    UPDATE AGENT_MEMENTO.OPS.AGENT_ACTIONS
       SET STATUS = UPPER(:P_DECISION), DECIDED_BY = CURRENT_USER(), DECIDED_ROLE = CURRENT_ROLE(),
           DECIDED_PERSONA = :P_PERSONA, DECIDED_TS_PT = CURRENT_TIMESTAMP(), DECISION_NOTE = :P_NOTE
     WHERE ACTION_ID = :P_ACTION_ID AND STATUS = 'PROPOSED';
    RETURN 'OK: action ' || P_ACTION_ID || ' ' || UPPER(P_DECISION);
END;
$$;

-- Daily schedule (data is a fixed extract, so a re-run on the latest date is a no-op).
CREATE OR REPLACE TASK TSK_AGENT_SUPERVISOR
    WAREHOUSE = DEFAULT_WH
    SCHEDULE = 'USING CRON 15 6 * * * America/Los_Angeles'
    COMMENT = 'Daily: detect signals, draft actions with Claude, log the run'
AS
    CALL AGENT_MEMENTO.OPS.PROC_RUN_SUPERVISOR(NULL);

-- Persona read access to the decision log; decisions go through PROC_DECIDE_ACTION.
GRANT SELECT ON TABLE AGENT_SIGNALS TO ROLE AM_AGENT_PM_R;
GRANT SELECT ON TABLE AGENT_SIGNALS TO ROLE AM_CSM_R;
GRANT SELECT ON TABLE AGENT_SIGNALS TO ROLE AM_FINANCE_R;
GRANT SELECT, UPDATE ON TABLE AGENT_ACTIONS TO ROLE AM_AGENT_PM_R;
GRANT SELECT, UPDATE ON TABLE AGENT_ACTIONS TO ROLE AM_CSM_R;
GRANT SELECT, UPDATE ON TABLE AGENT_ACTIONS TO ROLE AM_FINANCE_R;
GRANT SELECT ON TABLE AGENT_RUN_LOG TO ROLE AM_AGENT_PM_R;
GRANT SELECT ON TABLE AGENT_RUN_LOG TO ROLE AM_FINANCE_R;
GRANT USAGE ON PROCEDURE PROC_DECIDE_ACTION(NUMBER, STRING, STRING, STRING) TO ROLE AM_AGENT_PM_R;
GRANT USAGE ON PROCEDURE PROC_DECIDE_ACTION(NUMBER, STRING, STRING, STRING) TO ROLE AM_CSM_R;
GRANT USAGE ON PROCEDURE PROC_DECIDE_ACTION(NUMBER, STRING, STRING, STRING) TO ROLE AM_FINANCE_R;

ALTER TASK TSK_AGENT_SUPERVISOR RESUME;

-- One-time backfill (weekly as-of dates over the extract). Re-running is a no-op.
CALL PROC_RUN_SUPERVISOR('2026-08-03'::DATE);
CALL PROC_RUN_SUPERVISOR('2026-08-10'::DATE);
CALL PROC_RUN_SUPERVISOR('2026-08-17'::DATE);
CALL PROC_RUN_SUPERVISOR('2026-08-24'::DATE);
CALL PROC_RUN_SUPERVISOR('2026-08-31'::DATE);
