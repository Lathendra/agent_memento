"""Run one or more SQL build scripts against the hackathon account.

Usage: python scripts/run_sql.py sql/10_raw_load.sql [sql/20_...sql ...]
"""
import os
import sys
import time

import snowflake.connector

CONNECTION = os.getenv("SNOWFLAKE_CONNECTION_NAME", "ANTHROPIC-SNOWFLAKE-HACKATHON-ASDZAA")

con = snowflake.connector.connect(connection_name=CONNECTION, role="ATTENDEE_ROLE", warehouse="DEFAULT_WH")
try:
    for path in sys.argv[1:]:
        with open(path) as f:
            sql = f.read()
        print(f"== {path}", flush=True)
        for cur in con.execute_string(sql, remove_comments=True):
            t = time.strftime("%H:%M:%S")
            first = cur.fetchone() if cur.description else None
            print(f"{t} {cur.sfqid} rows={cur.rowcount} {str(first)[:160] if first else ''}", flush=True)
finally:
    con.close()
