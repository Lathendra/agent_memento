-- Semantic view over the agent spans mart: operations, account economics (COGS / margin) and supervisor actions.
-- Row access and masking on the base tables apply to every query, so personas see only what their role allows.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.SEMANTIC;

CREATE OR REPLACE SEMANTIC VIEW SEM_AGENT_OPERATIONS
  TABLES (
    calls AS AGENT_MEMENTO.MART.FCT_CALL PRIMARY KEY (CALL_HASH)
      WITH SYNONYMS = ('agent calls', 'voice calls', 'traces', 'sessions', 'conversations')
      COMMENT = 'One row per voice-agent call (trace)',
    llm AS AGENT_MEMENTO.MART.FCT_LLM_USAGE PRIMARY KEY (SPAN_HASH)
      WITH SYNONYMS = ('llm calls', 'model calls', 'llm usage')
      COMMENT = 'One row per LLM span',
    tools AS AGENT_MEMENTO.MART.FCT_TOOL_CALL PRIMARY KEY (SPAN_HASH)
      WITH SYNONYMS = ('tool calls', 'tool invocations')
      COMMENT = 'One row per tool span',
    accounts AS AGENT_MEMENTO.MART.DIM_CUSTOMER_ACCOUNT PRIMARY KEY (ACCOUNT_ID)
      WITH SYNONYMS = ('customers', 'customer accounts', 'clients', 'book of business')
      COMMENT = 'Customer accounts of the voice-agent platform',
    orgs AS AGENT_MEMENTO.MART.DIM_ORGANIZATION PRIMARY KEY (ORG_ID)
      COMMENT = 'Platform organization',
    models AS AGENT_MEMENTO.MART.DIM_LLM_MODEL PRIMARY KEY (MODEL_NAME)
      COMMENT = 'LLM models and token prices',
    intents AS AGENT_MEMENTO.MART.DIM_INTENT PRIMARY KEY (INTENT_TAG)
      COMMENT = 'Call intent',
    outcomes AS AGENT_MEMENTO.MART.DIM_OUTCOME PRIMARY KEY (OUTCOME_CODE)
      COMMENT = 'Call outcome and KPI flags',
    dates AS AGENT_MEMENTO.MART.DIM_DATE PRIMARY KEY (DATE_KEY)
      COMMENT = 'Calendar (Pacific time)',
    actions AS AGENT_MEMENTO.OPS.AGENT_ACTIONS PRIMARY KEY (ACTION_ID)
      WITH SYNONYMS = ('supervisor actions', 'recommendations', 'proposals', 'decisions', 'action inbox')
      COMMENT = 'Actions proposed by the autonomous supervisor and the human decision on each'
  )
  RELATIONSHIPS (
    calls_to_account AS calls (ACCOUNT_ID)   REFERENCES accounts,
    calls_to_model   AS calls (MODEL_NAME)   REFERENCES models,
    calls_to_intent  AS calls (INTENT_TAG)   REFERENCES intents,
    calls_to_outcome AS calls (OUTCOME_CODE) REFERENCES outcomes,
    calls_to_date    AS calls (CALL_DATE_PT) REFERENCES dates,
    accounts_to_org  AS accounts (ORG_ID)    REFERENCES orgs,
    llm_to_call      AS llm (CALL_HASH)      REFERENCES calls,
    tools_to_call    AS tools (CALL_HASH)    REFERENCES calls
  )
  FACTS (
    calls.duration_seconds AS DURATION_SECONDS COMMENT = 'Call duration, first span start to last span end',
    calls.billable_minutes AS BILLABLE_MINUTES COMMENT = 'Billable minutes (duration rounded up to the minute)',
    calls.cost_amount AS COST_AMOUNT COMMENT = 'Model (LLM) cost of the call in USD',
    calls.telephony_cost_amount AS TELEPHONY_COST_AMOUNT COMMENT = 'Telephony cost of the call in USD',
    calls.cogs_amount AS COGS_AMOUNT COMMENT = 'COGS = model cost + telephony cost, USD',
    calls.revenue_amount AS REVENUE_AMOUNT COMMENT = 'Revenue = billable minutes x contract price, USD (Finance only)',
    calls.gross_margin_amount AS GROSS_MARGIN_AMOUNT COMMENT = 'Revenue minus COGS, USD (Finance only)',
    calls.total_tokens AS TOTAL_TOKEN_COUNT COMMENT = 'Prompt plus completion tokens of the call',
    calls.span_count AS SPAN_COUNT,
    calls.tool_call_count AS TOOL_CALL_COUNT,
    calls.llm_call_count AS LLM_CALL_COUNT,
    calls.error_span_count AS ERROR_SPAN_COUNT,
    calls.tool_error_count AS TOOL_ERROR_COUNT,
    calls.quality_score AS QUALITY_SCORE COMMENT = 'Root span quality score, 0 to 1',
    calls.is_resolved_flag AS IFF(OUTCOME_CODE IN ('RESOLVED', 'RESOLVED_LOW_QUALITY', 'RECOVERED'), 1, 0),
    calls.is_failure_flag AS IFF(OUTCOME_CODE IN ('FAILED', 'INCOMPLETE'), 1, 0),
    calls.is_anomaly_flag AS IFF(IS_COST_ANOMALY OR IS_DURATION_ANOMALY, 1, 0),
    llm.latency_ms AS LATENCY_MS COMMENT = 'LLM span latency in milliseconds',
    llm.tokens AS TOTAL_TOKEN_COUNT,
    llm.cost_amount AS COST_AMOUNT,
    llm.is_error_flag AS IFF(IS_ERROR, 1, 0),
    tools.latency_ms AS LATENCY_MS COMMENT = 'Tool span latency in milliseconds',
    tools.is_error_flag AS IFF(IS_ERROR, 1, 0),
    accounts.contract_price AS CONTRACT_PRICE_PER_MIN_AMOUNT COMMENT = 'Contract price per billable minute, USD (Finance only)',
    actions.projected_savings AS PROJECTED_SAVINGS_AMOUNT COMMENT = 'Monthly run-rate impact computed in SQL, USD',
    actions.is_approved_flag AS IFF(STATUS = 'APPROVED', 1, 0),
    actions.is_proposed_flag AS IFF(STATUS = 'PROPOSED', 1, 0)
  )
  DIMENSIONS (
    calls.call_date AS CALL_DATE_PT WITH SYNONYMS = ('date', 'day') COMMENT = 'Call date, Pacific time',
    calls.call_hour AS CALL_HOUR_PT COMMENT = 'Hour of day the call started, Pacific time',
    calls.is_cost_anomaly AS IS_COST_ANOMALY COMMENT = 'Cost above 3 standard deviations of the trailing 7-day mean',
    calls.is_duration_anomaly AS IS_DURATION_ANOMALY COMMENT = 'Duration above 3 standard deviations of the trailing 7-day mean',
    accounts.account_name AS ACCOUNT_NAME WITH SYNONYMS = ('customer', 'account', 'client') COMMENT = 'Customer account name',
    accounts.segment AS SEGMENT COMMENT = 'Enterprise, Mid-market or SMB',
    accounts.industry AS INDUSTRY,
    accounts.csm_owner AS CSM_OWNER WITH SYNONYMS = ('customer success manager', 'csm') COMMENT = 'Customer Success Manager who owns the account',
    accounts.plan_tier AS PLAN_TIER,
    orgs.org_name AS ORG_NAME,
    models.mapped_model_name AS MAPPED_MODEL_NAME WITH SYNONYMS = ('model', 'llm') COMMENT = 'Claude model of the root span',
    models.model_tier AS MODEL_TIER COMMENT = 'Premium, Standard or Economy',
    intents.intent_name AS INTENT_NAME WITH SYNONYMS = ('intent', 'reason', 'topic') COMMENT = 'Why the caller contacted the agent',
    intents.intent_group AS INTENT_GROUP,
    outcomes.outcome_name AS OUTCOME_NAME WITH SYNONYMS = ('outcome', 'result') COMMENT = 'Resolved, Resolved low quality, Recovered, Failed, Incomplete',
    outcomes.is_resolved AS IS_RESOLVED,
    outcomes.is_failure AS IS_FAILURE,
    dates.week_start_date AS WEEK_START_DATE WITH SYNONYMS = ('week'),
    dates.year_month AS YEAR_MONTH WITH SYNONYMS = ('month'),
    dates.day_name AS DAY_NAME,
    dates.is_weekend AS IS_WEEKEND,
    llm.llm_date AS SPAN_DATE_PT COMMENT = 'LLM span date, Pacific time',
    llm.llm_model_name AS MODEL_NAME COMMENT = 'Source model of the LLM span (model_a = Sonnet, model_b = Haiku, model_c = Opus)',
    tools.tool_date AS SPAN_DATE_PT COMMENT = 'Tool span date, Pacific time',
    tools.tool_seq_no AS TOOL_SEQ_NO COMMENT = 'Position of the tool call within its call',
    actions.signal_type AS SIGNAL_TYPE COMMENT = 'NEGATIVE_MARGIN_ACCOUNT, MODEL_COST_SHIFT, ANOMALY_SPIKE, FAILURE_SPIKE',
    actions.entity_type AS ENTITY_TYPE COMMENT = 'ACCOUNT, INTENT or PLATFORM',
    actions.entity_name AS ENTITY_NAME COMMENT = 'Account, intent or platform the action is about',
    actions.owner_persona AS OWNER_PERSONA COMMENT = 'Finance, Agent PM or CSM',
    actions.action_status AS STATUS WITH SYNONYMS = ('decision', 'approval status') COMMENT = 'PROPOSED, APPROVED or REJECTED',
    actions.action_title AS TITLE,
    actions.recommendation AS RECOMMENDATION_TEXT,
    actions.decided_role AS DECIDED_ROLE COMMENT = 'Role that approved or rejected',
    actions.decision_note AS DECISION_NOTE,
    actions.as_of_date AS AS_OF_DATE COMMENT = 'Week-ending date the supervisor evaluated'
  )
  METRICS (
    calls.call_count AS COUNT(calls.CALL_HASH) WITH SYNONYMS = ('number of calls', 'volume') COMMENT = 'Number of calls',
    calls.resolution_rate AS SUM(calls.is_resolved_flag) / NULLIF(COUNT(calls.CALL_HASH), 0)
      WITH SYNONYMS = ('containment rate', 'success rate') COMMENT = 'Share of calls resolved (incl. recovered and low quality)',
    calls.failure_rate AS SUM(calls.is_failure_flag) / NULLIF(COUNT(calls.CALL_HASH), 0) COMMENT = 'Share of calls failed or incomplete',
    calls.anomaly_rate AS SUM(calls.is_anomaly_flag) / NULLIF(COUNT(calls.CALL_HASH), 0) COMMENT = 'Share of calls flagged cost or duration anomaly',
    calls.anomaly_call_count AS SUM(calls.is_anomaly_flag) COMMENT = 'Calls flagged as cost or duration anomaly',
    calls.total_minutes AS SUM(calls.billable_minutes) COMMENT = 'Billable minutes',
    calls.total_model_cost AS SUM(calls.cost_amount) WITH SYNONYMS = ('llm cost', 'model spend') COMMENT = 'Model cost, USD',
    calls.total_telephony_cost AS SUM(calls.telephony_cost_amount) COMMENT = 'Telephony cost, USD',
    calls.total_cogs AS SUM(calls.cogs_amount) WITH SYNONYMS = ('cogs', 'cost of goods sold') COMMENT = 'COGS (model + telephony), USD',
    calls.total_revenue AS SUM(calls.revenue_amount) WITH SYNONYMS = ('revenue', 'billings') COMMENT = 'Revenue, USD (Finance only)',
    calls.gross_margin AS SUM(calls.gross_margin_amount) WITH SYNONYMS = ('margin', 'profit') COMMENT = 'Gross margin, USD (Finance only)',
    calls.gross_margin_pct AS SUM(calls.gross_margin_amount) / NULLIF(SUM(calls.revenue_amount), 0) COMMENT = 'Gross margin / revenue (Finance only)',
    calls.cogs_per_minute AS SUM(calls.cogs_amount) / NULLIF(SUM(calls.billable_minutes), 0) COMMENT = 'COGS per billable minute, USD',
    calls.cost_per_call AS SUM(calls.cost_amount) / NULLIF(COUNT(calls.CALL_HASH), 0) COMMENT = 'Average model cost per call, USD',
    calls.cost_per_resolved_call AS SUM(calls.cogs_amount) / NULLIF(SUM(calls.is_resolved_flag), 0) COMMENT = 'COGS divided by resolved calls, USD',
    calls.avg_duration_seconds AS AVG(calls.duration_seconds) COMMENT = 'Average call duration in seconds',
    calls.p90_duration_seconds AS APPROX_PERCENTILE(calls.duration_seconds, 0.9) COMMENT = '90th percentile call duration in seconds',
    calls.avg_quality_score AS AVG(calls.quality_score) COMMENT = 'Average root quality score',
    calls.avg_tool_calls_per_call AS AVG(calls.tool_call_count) COMMENT = 'Average tool calls per call',
    llm.llm_call_count_metric AS COUNT(llm.SPAN_HASH) COMMENT = 'Number of LLM calls',
    llm.llm_cost AS SUM(llm.cost_amount) COMMENT = 'LLM cost in USD; use with llm_model_name for cost by model',
    llm.llm_p50_latency_ms AS APPROX_PERCENTILE(llm.latency_ms, 0.5) COMMENT = 'Median LLM latency (ms)',
    llm.llm_p90_latency_ms AS APPROX_PERCENTILE(llm.latency_ms, 0.9) COMMENT = '90th percentile LLM latency (ms)',
    llm.llm_error_rate AS AVG(llm.is_error_flag) COMMENT = 'Share of LLM calls that errored',
    tools.tool_call_count_metric AS COUNT(tools.SPAN_HASH) COMMENT = 'Number of tool calls',
    tools.tool_error_rate AS AVG(tools.is_error_flag) WITH SYNONYMS = ('tool failure rate') COMMENT = 'Share of tool calls that errored',
    tools.tool_p90_latency_ms AS APPROX_PERCENTILE(tools.latency_ms, 0.9) COMMENT = '90th percentile tool latency (ms)',
    actions.action_count AS COUNT(actions.ACTION_ID) COMMENT = 'Number of supervisor actions',
    actions.approved_action_count AS SUM(actions.is_approved_flag) COMMENT = 'Approved actions',
    actions.proposed_action_count AS SUM(actions.is_proposed_flag) COMMENT = 'Actions awaiting a decision',
    actions.total_projected_savings AS SUM(actions.projected_savings) COMMENT = 'Monthly run-rate impact of actions, USD'
  )
  COMMENT = 'Voice-agent operations and economics: volume, resolution, cost, COGS, margin, latency, errors, anomalies, supervisor actions'
  AI_SQL_GENERATION 'Dates are Pacific time. Rates are ratios between 0 and 1; show them as percentages. Money is USD; model prices and telephony rate are assumed. Revenue, gross margin and contract price are visible to Finance only; if they return NULL, say the user''s role cannot see financials. Row access limits accounts by role; never claim totals cover all accounts unless asked. The call model (models.*) is the root span model only; for cost, tokens or latency BY MODEL use llm metrics grouped by llm.llm_model_name. Actions: latest week is the MAX(as_of_date); filter actions by action_status for open (PROPOSED) items.'
  AI_VERIFIED_QUERIES (
    fin_negative_margin AS (
      QUESTION 'Which accounts have negative gross margin?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT a.account_name, SUM(c.revenue_amount) AS revenue, SUM(c.cogs_amount) AS cogs, SUM(c.gross_margin_amount) AS gross_margin, SUM(c.gross_margin_amount) / NULLIF(SUM(c.revenue_amount), 0) AS gross_margin_pct FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id GROUP BY a.account_name HAVING SUM(c.gross_margin_amount) < 0 ORDER BY gross_margin'
    ),
    fin_margin_by_account AS (
      QUESTION 'What is revenue, COGS and gross margin by account?'
      SQL 'SELECT a.account_name, a.segment, SUM(c.revenue_amount) AS revenue, SUM(c.cogs_amount) AS cogs, SUM(c.gross_margin_amount) AS gross_margin, SUM(c.gross_margin_amount) / NULLIF(SUM(c.revenue_amount), 0) AS gross_margin_pct FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id GROUP BY a.account_name, a.segment ORDER BY gross_margin_pct'
    ),
    fin_cogs_breakdown AS (
      QUESTION 'Break down COGS per minute into model and telephony cost by account'
      SQL 'SELECT a.account_name, SUM(c.cost_amount) / NULLIF(SUM(c.billable_minutes), 0) AS model_cost_per_minute, SUM(c.telephony_cost_amount) / NULLIF(SUM(c.billable_minutes), 0) AS telephony_cost_per_minute, SUM(c.cogs_amount) / NULLIF(SUM(c.billable_minutes), 0) AS cogs_per_minute FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id GROUP BY a.account_name ORDER BY cogs_per_minute DESC'
    ),
    fin_llm_cost_by_model AS (
      QUESTION 'What is LLM cost by model?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT l.llm_model_name, SUM(l.cost_amount) AS llm_cost, COUNT(l.span_hash) AS llm_calls FROM __llm AS l GROUP BY l.llm_model_name ORDER BY llm_cost DESC'
    ),
    fin_savings_pipeline AS (
      QUESTION 'How much projected savings are proposed versus approved?'
      SQL 'SELECT x.action_status, x.signal_type, COUNT(x.action_id) AS actions, SUM(x.projected_savings) AS projected_monthly_impact FROM __actions AS x GROUP BY x.action_status, x.signal_type ORDER BY projected_monthly_impact DESC NULLS LAST'
    ),
    pm_resolution_by_intent AS (
      QUESTION 'What is the resolution rate and failure rate by intent?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT i.intent_name, COUNT(c.call_hash) AS calls, SUM(c.is_resolved_flag) / NULLIF(COUNT(c.call_hash), 0) AS resolution_rate, SUM(c.is_failure_flag) / NULLIF(COUNT(c.call_hash), 0) AS failure_rate FROM __calls AS c JOIN __intents AS i ON c.intent_tag = i.intent_tag GROUP BY i.intent_name ORDER BY calls DESC'
    ),
    pm_weekly_quality AS (
      QUESTION 'Show weekly calls, resolution rate and anomaly rate'
      SQL 'SELECT d.week_start_date, COUNT(c.call_hash) AS calls, SUM(c.is_resolved_flag) / NULLIF(COUNT(c.call_hash), 0) AS resolution_rate, SUM(c.is_anomaly_flag) / NULLIF(COUNT(c.call_hash), 0) AS anomaly_rate FROM __calls AS c JOIN __dates AS d ON c.call_date = d.date_key GROUP BY d.week_start_date ORDER BY d.week_start_date'
    ),
    pm_latency_by_model AS (
      QUESTION 'What is p50 and p90 LLM latency and error rate by model?'
      SQL 'SELECT l.llm_model_name, APPROX_PERCENTILE(l.latency_ms, 0.5) AS p50_latency_ms, APPROX_PERCENTILE(l.latency_ms, 0.9) AS p90_latency_ms, AVG(l.is_error_flag) AS error_rate FROM __llm AS l GROUP BY l.llm_model_name ORDER BY l.llm_model_name'
    ),
    pm_tool_errors AS (
      QUESTION 'What is the tool error rate by week?'
      SQL 'SELECT DATE_TRUNC(''week'', t.tool_date) AS week, COUNT(t.span_hash) AS tool_calls, AVG(t.is_error_flag) AS tool_error_rate FROM __tools AS t GROUP BY 1 ORDER BY 1'
    ),
    pm_model_shift_actions AS (
      QUESTION 'Which model routing changes has the supervisor proposed?'
      SQL 'SELECT x.as_of_date, x.entity_name AS intent, x.action_title, x.projected_savings, x.action_status FROM __actions AS x WHERE x.signal_type = ''MODEL_COST_SHIFT'' ORDER BY x.as_of_date DESC, x.projected_savings DESC'
    ),
    csm_account_health AS (
      QUESTION 'Show account health for my accounts'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT a.account_name, a.csm_owner, COUNT(c.call_hash) AS calls, SUM(c.is_resolved_flag) / NULLIF(COUNT(c.call_hash), 0) AS resolution_rate, SUM(c.is_failure_flag) / NULLIF(COUNT(c.call_hash), 0) AS failure_rate, SUM(c.is_anomaly_flag) / NULLIF(COUNT(c.call_hash), 0) AS anomaly_rate, AVG(c.duration_seconds) AS avg_duration_seconds FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id GROUP BY a.account_name, a.csm_owner ORDER BY calls DESC'
    ),
    csm_weekly_by_account AS (
      QUESTION 'Weekly resolution rate by account'
      SQL 'SELECT d.week_start_date, a.account_name, COUNT(c.call_hash) AS calls, SUM(c.is_resolved_flag) / NULLIF(COUNT(c.call_hash), 0) AS resolution_rate FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id JOIN __dates AS d ON c.call_date = d.date_key GROUP BY d.week_start_date, a.account_name ORDER BY d.week_start_date, a.account_name'
    ),
    csm_anomalies AS (
      QUESTION 'Which accounts had the most anomalous calls last week?'
      SQL 'SELECT a.account_name, COUNT(c.call_hash) AS calls, SUM(c.is_anomaly_flag) AS anomaly_calls, SUM(c.is_anomaly_flag) / NULLIF(COUNT(c.call_hash), 0) AS anomaly_rate FROM __calls AS c JOIN __accounts AS a ON c.account_id = a.account_id WHERE c.call_date > (SELECT MAX(call_date) FROM __calls) - 7 GROUP BY a.account_name ORDER BY anomaly_calls DESC'
    ),
    csm_open_actions AS (
      QUESTION 'What open supervisor actions are there?'
      SQL 'SELECT x.as_of_date, x.owner_persona, x.signal_type, x.entity_name, x.action_title, x.projected_savings FROM __actions AS x WHERE x.action_status = ''PROPOSED'' ORDER BY x.as_of_date DESC, x.projected_savings DESC NULLS LAST'
    ),
    audit_decisions AS (
      QUESTION 'Show every action that was approved or rejected and who decided'
      SQL 'SELECT x.action_id, x.as_of_date, x.signal_type, x.entity_name, x.action_status, x.decided_role, x.decision_note FROM __actions AS x WHERE x.action_status <> ''PROPOSED'' ORDER BY x.as_of_date DESC'
    )
  );

GRANT SELECT ON SEMANTIC VIEW SEM_AGENT_OPERATIONS TO ROLE AGENT_MEMENTO_ANALYST_R;
GRANT SELECT ON SEMANTIC VIEW SEM_AGENT_OPERATIONS TO ROLE AM_AGENT_PM_R;
GRANT SELECT ON SEMANTIC VIEW SEM_AGENT_OPERATIONS TO ROLE AM_CSM_R;
GRANT SELECT ON SEMANTIC VIEW SEM_AGENT_OPERATIONS TO ROLE AM_FINANCE_R;
