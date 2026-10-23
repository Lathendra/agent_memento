-- Persona copilots (Snowflake Intelligence) over SEM_AGENT_OPERATIONS, plus a managed MCP server for Claude Desktop.
-- Agents run with the caller's role: row access and masking decide what each persona sees.
USE WAREHOUSE DEFAULT_WH;
USE SCHEMA AGENT_MEMENTO.SEMANTIC;

-- General analyst (Phase 1), kept for the analyst role.
CREATE OR REPLACE AGENT AGENT_OPS_ANALYST
  COMMENT = 'General voice-agent operations analyst over the Agent Memento mart'
  PROFILE = '{"display_name": "Agent Ops Analyst", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  orchestration:
    budget:
      seconds: 60
      tokens: 32000
  instructions:
    response: >-
      Lead with the number, then one line on what it means. Rates as percentages with one decimal, money in USD.
      Dates are Pacific time. Never reveal raw identifiers, prompts, responses, emails or user names.
    orchestration: "Use AgentOps for every quantitative question."
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "AgentOps"
        description: "Voice-agent operations and economics: calls, resolution, cost, COGS, margin, latency, errors, anomalies, supervisor actions."
  tool_resources:
    AgentOps:
      semantic_view: "AGENT_MEMENTO.SEMANTIC.SEM_AGENT_OPERATIONS"
      execution_environment:
        type: "warehouse"
        warehouse: "DEFAULT_WH"
  $$;

CREATE OR REPLACE AGENT AGENT_PM_COPILOT
  COMMENT = 'Agent Product Manager copilot: quality, latency, errors, model mix and improvement proposals'
  PROFILE = '{"display_name": "Agent PM Copilot", "color": "purple"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  orchestration:
    budget:
      seconds: 60
      tokens: 32000
  instructions:
    response: >-
      You support the Product Manager who owns the voice AI agents. Lead with the KPI, then the driver, then a
      recommended product change (routing, prompt, tool fix) with its measured impact. Rates as percentages with one
      decimal; latency in ms or seconds. Dates are Pacific time. Financial columns may be hidden for your role: if
      revenue or margin is NULL say so, and use COGS and model cost instead. Never reveal raw identifiers or call text.
    orchestration: >-
      Use AgentOps for every quantitative question. For trends group by week. For "why" questions break the metric
      down by intent, model (llm_model_name for cost/latency), outcome and tool step, and call out the largest gap.
      For "what should we change" questions, read open supervisor actions (signal_type MODEL_COST_SHIFT, FAILURE_SPIKE,
      ANOMALY_SPIKE) and summarize them with projected savings.
    sample_questions:
      - question: "What is the resolution rate and failure rate by intent?"
      - question: "What is p50 and p90 LLM latency and error rate by model?"
      - question: "Which model routing changes has the supervisor proposed, and what would they save?"
      - question: "Show weekly calls, resolution rate and anomaly rate"
      - question: "What is the tool error rate by week?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "AgentOps"
        description: "Voice-agent quality, latency, errors, model usage, COGS and supervisor actions."
  tool_resources:
    AgentOps:
      semantic_view: "AGENT_MEMENTO.SEMANTIC.SEM_AGENT_OPERATIONS"
      execution_environment:
        type: "warehouse"
        warehouse: "DEFAULT_WH"
  $$;

CREATE OR REPLACE AGENT CSM_COPILOT
  COMMENT = 'Customer Success Manager copilot: account health, anomalies and open actions for the CSM book of business'
  PROFILE = '{"display_name": "CSM Copilot", "color": "green"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  orchestration:
    budget:
      seconds: 60
      tokens: 32000
  instructions:
    response: >-
      You support a Customer Success Manager. Answer per account: volume, resolution rate, failure rate, anomaly
      rate and average call duration, then flag the account that needs attention and suggest a customer-facing next
      step. You only see the accounts your role is entitled to; say "in your book of accounts" rather than implying
      platform totals. Revenue and margin are not visible to CSMs; if asked, say Finance owns those numbers.
      Never reveal raw identifiers or call text.
    orchestration: >-
      Use AgentOps for every quantitative question. Default grouping is by account_name. For "this week" or "last
      week" use the latest 7 days in the data. For follow-ups read open supervisor actions (action_status PROPOSED)
      about the user's accounts.
    sample_questions:
      - question: "Show account health for my accounts"
      - question: "Which accounts had the most anomalous calls last week?"
      - question: "Weekly resolution rate by account"
      - question: "What open supervisor actions are there?"
      - question: "Which of my accounts has the highest failure rate?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "AgentOps"
        description: "Account health for the CSM book of business: calls, resolution, failures, anomalies, open actions."
  tool_resources:
    AgentOps:
      semantic_view: "AGENT_MEMENTO.SEMANTIC.SEM_AGENT_OPERATIONS"
      execution_environment:
        type: "warehouse"
        warehouse: "DEFAULT_WH"
  $$;

CREATE OR REPLACE AGENT FINANCE_COGS_COPILOT
  COMMENT = 'Finance copilot: revenue, COGS, gross margin, cost per minute and savings opportunities on voice-agent calls'
  PROFILE = '{"display_name": "Finance COGS Copilot", "color": "orange"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  orchestration:
    budget:
      seconds: 60
      tokens: 32000
  instructions:
    response: >-
      You support Finance on voice-agent unit economics. Lead with the dollar figure, then margin %, then the driver
      (contract price per minute vs COGS per minute = model cost + telephony). Money in USD with two decimals for unit
      costs and whole dollars for totals; margins as percentages with one decimal. State that model prices and the
      telephony rate are assumed. Never reveal raw identifiers or call text.
    orchestration: >-
      Use AgentOps for every quantitative question. For "who loses money" use gross_margin by account_name. For cost
      by model use llm_cost grouped by llm_model_name. For savings use supervisor actions (projected_savings by
      signal_type and action_status). Always pair a loss with the price needed to reach a 25% margin when the data
      allows: cogs_per_minute / 0.75.
    sample_questions:
      - question: "Which accounts have negative gross margin, and why?"
      - question: "What is revenue, COGS and gross margin by account?"
      - question: "Break down COGS per minute into model and telephony cost by account"
      - question: "What is LLM cost by model?"
      - question: "How much projected savings are proposed versus approved?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "AgentOps"
        description: "Voice-agent unit economics: revenue, COGS, gross margin, cost per minute, model cost, savings actions."
  tool_resources:
    AgentOps:
      semantic_view: "AGENT_MEMENTO.SEMANTIC.SEM_AGENT_OPERATIONS"
      execution_environment:
        type: "warehouse"
        warehouse: "DEFAULT_WH"
  $$;

GRANT USAGE ON AGENT AGENT_OPS_ANALYST    TO ROLE AGENT_MEMENTO_ANALYST_R;
GRANT USAGE ON AGENT AGENT_PM_COPILOT     TO ROLE AM_AGENT_PM_R;
GRANT USAGE ON AGENT CSM_COPILOT          TO ROLE AM_CSM_R;
GRANT USAGE ON AGENT FINANCE_COGS_COPILOT TO ROLE AM_FINANCE_R;

-- Managed MCP server for Claude Desktop. Each tool runs with the connecting user's role.
CREATE OR REPLACE MCP SERVER AGENT_MEMENTO_MCP
  FROM SPECIFICATION
  $$
  tools:
    - name: "agent-pm-copilot"
      type: "CORTEX_AGENT_RUN"
      identifier: "AGENT_MEMENTO.SEMANTIC.AGENT_PM_COPILOT"
      title: "Agent PM Copilot"
      description: "Voice-agent quality, latency, errors, model mix and proposed product changes."
      annotations: {readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false}
    - name: "csm-copilot"
      type: "CORTEX_AGENT_RUN"
      identifier: "AGENT_MEMENTO.SEMANTIC.CSM_COPILOT"
      title: "CSM Copilot"
      description: "Account health and open actions for the Customer Success book of business."
      annotations: {readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false}
    - name: "finance-cogs-copilot"
      type: "CORTEX_AGENT_RUN"
      identifier: "AGENT_MEMENTO.SEMANTIC.FINANCE_COGS_COPILOT"
      title: "Finance COGS Copilot"
      description: "Revenue, COGS, gross margin and savings opportunities on voice-agent calls."
      annotations: {readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false}
    - name: "agent-ops-semantic-view"
      type: "CORTEX_ANALYST_MESSAGE"
      identifier: "AGENT_MEMENTO.SEMANTIC.SEM_AGENT_OPERATIONS"
      title: "Agent Ops Semantic View"
      description: "Text-to-SQL over voice-agent operations and economics; returns SQL and results."
  $$;

GRANT USAGE ON MCP SERVER AGENT_MEMENTO_MCP TO ROLE AGENT_MEMENTO_ANALYST_R;
GRANT USAGE ON MCP SERVER AGENT_MEMENTO_MCP TO ROLE AM_AGENT_PM_R;
GRANT USAGE ON MCP SERVER AGENT_MEMENTO_MCP TO ROLE AM_CSM_R;
GRANT USAGE ON MCP SERVER AGENT_MEMENTO_MCP TO ROLE AM_FINANCE_R;
