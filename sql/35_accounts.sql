-- Organization and customer-account dimensions, cost rates. Accounts are synthetic, assigned to calls by hash bucket.
-- Run before sql/40_facts.sql.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.MART;

-- Real org / project ids from the spans (1 org, 1 project in this extract).
CREATE OR REPLACE TABLE DIM_ORGANIZATION COMMENT = 'Voice-agent platform organization (from Braintrust ORG_ID)' AS
SELECT ORG_ID, 'Agent Memento Voice Platform' AS ORG_NAME, PROJECT_ID, PROJECT_NAME
FROM AGENT_MEMENTO.RAW.BRAINTRUST_SPANS
GROUP BY ORG_ID, PROJECT_ID, PROJECT_NAME;

-- Contract price per billable minute is set around the ~$0.031/min COGS so margins differ by account.
-- BUCKET_LO / BUCKET_HI: cumulative volume share (0-100) used to assign calls.
CREATE OR REPLACE TABLE DIM_CUSTOMER_ACCOUNT (
    ACCOUNT_ID                      STRING NOT NULL PRIMARY KEY,
    ACCOUNT_NAME                    STRING,
    ORG_ID                          STRING,
    SEGMENT                         STRING,
    INDUSTRY                        STRING,
    CSM_OWNER                       STRING,
    PLAN_TIER                       STRING,
    CONTRACT_PRICE_PER_MIN_AMOUNT   NUMBER(10,4),
    CONTRACT_START_DATE             DATE,
    BUCKET_LO                       NUMBER(3,0),
    BUCKET_HI                       NUMBER(3,0)
) COMMENT = 'Customer accounts of the voice-agent platform (synthetic)';

INSERT INTO DIM_CUSTOMER_ACCOUNT
SELECT a.column1, a.column2, (SELECT MIN(ORG_ID) FROM DIM_ORGANIZATION), a.column3, a.column4, a.column5, a.column6,
       a.column7, a.column8::DATE,
       SUM(a.column9) OVER (ORDER BY a.column1) - a.column9, SUM(a.column9) OVER (ORDER BY a.column1)
FROM VALUES
    ('A01', 'Northwind Health',          'Enterprise', 'Healthcare',         'Priya Shah', 'Enterprise', 0.0650, '2025-11-01', 22),
    ('A02', 'Contoso Dental Group',      'Mid-market', 'Healthcare',         'Priya Shah', 'Growth',     0.0450, '2026-01-15', 14),
    ('A03', 'Fabrikam Insurance',        'Enterprise', 'Insurance',          'Marcus Lee', 'Enterprise', 0.0280, '2025-09-01', 18),
    ('A04', 'Tailspin Clinics',          'SMB',        'Healthcare',         'Marcus Lee', 'Starter',    0.1200, '2026-03-01',  6),
    ('A05', 'Litware Telehealth',        'Mid-market', 'Healthcare',         'Elena Ruiz', 'Growth',     0.0300, '2026-02-01', 12),
    ('A06', 'Adventure Works Pharmacy',  'Mid-market', 'Retail pharmacy',    'Elena Ruiz', 'Growth',     0.0550, '2026-04-01', 10),
    ('A07', 'Wingtip Veterinary',        'SMB',        'Veterinary',         'Priya Shah', 'Starter',    0.0950, '2026-05-01',  8),
    ('A08', 'Proseware Billing',         'Enterprise', 'Financial services', 'Marcus Lee', 'Enterprise', 0.0380, '2025-12-01', 10)
    AS a;

-- Editable unit costs outside the model price list.
CREATE OR REPLACE TABLE DIM_COST_RATE (
    TELEPHONY_COST_PER_MIN_AMOUNT   NUMBER(10,4),
    RATE_SOURCE                     STRING
) COMMENT = 'Non-model unit costs used for COGS';
INSERT INTO DIM_COST_RATE VALUES (0.0085, 'Assumed carrier rate per minute');

-- Deterministic call -> account bucket (0-99), shared by every fact.
CREATE OR REPLACE FUNCTION FN_ACCOUNT_BUCKET(CALL_HASH STRING)
    RETURNS NUMBER
    COMMENT = 'Stable 0-99 bucket for assigning a call to a synthetic account'
    AS 'MOD(ABS(HASH(CALL_HASH)), 100)';
