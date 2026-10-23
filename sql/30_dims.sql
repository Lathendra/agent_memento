-- MART dimensions. Natural keys; small, seeded, idempotent (CREATE OR REPLACE).
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.MART;

-- Calendar covering the data range plus headroom.
CREATE OR REPLACE TABLE DIM_DATE COMMENT = 'Calendar, one row per date' AS
SELECT
    d                                   AS DATE_KEY,
    YEAR(d)                             AS YEAR_NO,
    QUARTER(d)                          AS QUARTER_NO,
    MONTH(d)                            AS MONTH_NO,
    TO_CHAR(d, 'YYYY-MM')               AS YEAR_MONTH,
    DATE_TRUNC('week', d)               AS WEEK_START_DATE,
    DAYOFWEEKISO(d)                     AS DAY_OF_WEEK_NO,
    DAYNAME(d)                          AS DAY_NAME,
    DAYOFWEEKISO(d) IN (6, 7)           AS IS_WEEKEND
FROM (SELECT DATEADD('day', SEQ4(), '2026-07-01'::DATE) AS d FROM TABLE(GENERATOR(ROWCOUNT => 366)));

-- Source models are anonymised (model_a/b/c). Mapped to Claude models; prices are USD per 1M tokens,
-- Anthropic list prices, editable here. Not verified against the Snowflake consumption table.
CREATE OR REPLACE TABLE DIM_LLM_MODEL (
    MODEL_NAME                      STRING NOT NULL PRIMARY KEY,
    MAPPED_MODEL_NAME               STRING,
    PROVIDER_NAME                   STRING,
    MODEL_TIER                      STRING,
    INPUT_PRICE_PER_1M_AMOUNT       NUMBER(10,4),
    OUTPUT_PRICE_PER_1M_AMOUNT      NUMBER(10,4),
    PRICE_SOURCE                    STRING
) COMMENT = 'LLM models with the price used for cost';
INSERT INTO DIM_LLM_MODEL VALUES
    ('model_a', 'claude-sonnet-4-5', 'Anthropic', 'Standard', 3.00, 15.00, 'Anthropic list price (assumed)'),
    ('model_b', 'claude-haiku-4-5',  'Anthropic', 'Economy',  1.00,  5.00, 'Anthropic list price (assumed)'),
    ('model_c', 'claude-opus-4-5',   'Anthropic', 'Premium',  5.00, 25.00, 'Anthropic list price (assumed)'),
    ('unknown', NULL,                NULL,        'Unknown',  0.00,  0.00, 'No model on span');

CREATE OR REPLACE TABLE DIM_SPAN_TYPE (
    SPAN_TYPE           STRING NOT NULL PRIMARY KEY,
    SPAN_TYPE_NAME      STRING,
    DESCRIPTION         STRING
) COMMENT = 'Braintrust span types';
INSERT INTO DIM_SPAN_TYPE VALUES
    ('task',    'Agent task', 'Root span: one per agent run'),
    ('llm',     'LLM call',   'Model invocation; source of tokens and cost'),
    ('tool',    'Tool call',  'Tool invocation by the agent'),
    ('unknown', 'Unknown',    'Span without a type');

-- Outcome rules live in STAGING.CALLS (sql/20_staging.sql); flags drive the KPIs.
CREATE OR REPLACE TABLE DIM_OUTCOME (
    OUTCOME_CODE        STRING NOT NULL PRIMARY KEY,
    OUTCOME_NAME        STRING,
    RULE_DESCRIPTION    STRING,
    IS_RESOLVED         BOOLEAN,
    IS_FAILURE          BOOLEAN,
    HAD_ERRORS          BOOLEAN,
    SORT_ORDER          NUMBER
) COMMENT = 'Call outcome, derived by deterministic rules';
INSERT INTO DIM_OUTCOME VALUES
    ('RESOLVED',             'Resolved',              'Root ok, no span errors, quality score >= 0.3', TRUE,  FALSE, FALSE, 1),
    ('RESOLVED_LOW_QUALITY', 'Resolved, low quality', 'Root ok, no span errors, quality score < 0.3',  TRUE,  FALSE, FALSE, 2),
    ('RECOVERED',            'Recovered from errors', 'Root ok, at least one child span errored',      TRUE,  FALSE, TRUE,  3),
    ('FAILED',               'Failed',                'Root span errored',                             FALSE, TRUE,  TRUE,  4),
    ('INCOMPLETE',           'Incomplete',            'No root span found for the trace',              FALSE, TRUE,  FALSE, 5);

-- Intent comes from the root span tag. Business names are an assumed mapping for the synthetic tags.
CREATE OR REPLACE TABLE DIM_INTENT (
    INTENT_TAG          STRING NOT NULL PRIMARY KEY,
    INTENT_NAME         STRING,
    INTENT_GROUP        STRING
) COMMENT = 'Call intent, mapped from the root span tag';
INSERT INTO DIM_INTENT VALUES
    ('tag_1',    'Account and access',  'Self-service'),
    ('tag_2',    'Billing and payments','Revenue'),
    ('tag_3',    'Scheduling',          'Operations'),
    ('tag_4',    'Technical support',   'Support'),
    ('tag_5',    'General inquiry',     'Support'),
    ('untagged', 'Not detected',        'Unknown');
