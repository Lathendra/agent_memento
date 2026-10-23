-- Persona agent evaluation: question -> DATA_AGENT_RUN under the persona's role -> compare with SQL truth.
-- Results land in OPS.AGENT_EVAL_RESULT. The runner loop lives in the session notebook; one call looks like this.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.OPS;

CREATE TABLE IF NOT EXISTS AGENT_EVAL_RESULT (
    EVAL_ID         STRING DEFAULT UUID_STRING(),
    AGENT_NAME      STRING,
    RUN_ROLE        STRING,
    QUESTION        STRING,
    EXPECTED_FACT   STRING,
    ANSWER_TEXT     STRING,
    IS_PASS         BOOLEAN,
    RUN_TS_PT       TIMESTAMP_TZ(3) DEFAULT CURRENT_TIMESTAMP()::TIMESTAMP_TZ(3)
) COMMENT = 'Persona agent evaluation results (answer vs SQL truth)';

-- Example: Finance persona, run as AM_FINANCE_R. Expected facts: Fabrikam Insurance and Litware Telehealth.
-- USE ROLE AM_FINANCE_R;
-- SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN('AGENT_MEMENTO.SEMANTIC.FINANCE_COGS_COPILOT',
--   $${"messages":[{"role":"user","content":[{"type":"text","text":"Which accounts have negative gross margin, and why?"}]}]}$$);

-- Eval set (expected fact must appear in the answer):
-- | Agent                | Role          | Question                                                          | Expected            |
-- | FINANCE_COGS_COPILOT | AM_FINANCE_R  | Which accounts have negative gross margin, and why?               | Fabrikam, Litware   |
-- | FINANCE_COGS_COPILOT | AM_FINANCE_R  | What is LLM cost by model?                                        | 64,1 / 38,5 / 12,8  |
-- | CSM_COPILOT          | AM_CSM_R      | Show account health for my accounts                               | Northwind, Contoso, Wingtip |
-- | CSM_COPILOT          | AM_CSM_R      | What is the gross margin of my accounts?                          | Finance (refusal)   |
-- | AGENT_PM_COPILOT     | AM_AGENT_PM_R | Which model routing changes has the supervisor proposed ...?      | Sonnet, savings     |
-- | AGENT_PM_COPILOT     | AM_AGENT_PM_R | What is the resolution rate by intent?                            | 97                  |

GRANT SELECT ON TABLE AGENT_EVAL_RESULT TO ROLE AM_AGENT_PM_R;
