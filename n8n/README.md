# n8n Setup

Two importable workflows plus a verification script.

| File | Purpose |
|---|---|
| `capstone_sdlc_pipeline.json` | Requirements to deployed, tested pipeline, with a human approval gate |
| `capstone_qa_watchdog.json` | Scheduled QA run, triage on failure, alert |
| `verify_sql_api.ps1` | Proves the Snowflake SQL API leg works before you touch n8n |

## Why n8n is here at all

Be clear about this, because it is the first thing a reviewer should challenge.

Everything these workflows do can be done by the Snowflake Task DAG in
`sql/15_orchestration.sql`. Both call the same five stage procedures. n8n earns
its place on exactly two things:

1. **The human approval gate.** `HUMAN APPROVAL GATE` is a Wait node that blocks
   until a reviewer calls its resume URL. Generated code sits at `DRAFT` in
   `ARTIFACTS.GENERATED_CODE` until then, and `STAGE_DEPLOY` is what promotes it.
   The Task DAG cannot wait for a person, so `T_SDLC_DEPLOY` auto-approves - which
   is precisely the compromise n8n removes.
2. **Outbound notification and escalation.** Routing a CRITICAL defect to a
   channel, with the triage summary attached.

If you do not need those two things, use the Task DAG and run one fewer runtime.
That is a legitimate answer, and the DAG ships for exactly that reason.

## Prerequisites

### 1. A network policy (required for token auth)

Snowflake refuses programmatic access token authentication unless a network
policy applies to the user or account. Without it the SQL API returns:

```
401  {"code":"390432","message":"Fail : Network policy is required."}
```

This is a security control, so decide the allowed range yourself rather than
copying an example. Something like:

```sql
CREATE NETWORK POLICY n8n_local_policy
  ALLOWED_IP_LIST = ('<your.public.ip>/32');

ALTER USER <your_user> SET NETWORK_POLICY = n8n_local_policy;
```

Scope it to the user, not the account, and remove it when you are done:

```sql
ALTER USER <your_user> UNSET NETWORK_POLICY;
DROP NETWORK POLICY n8n_local_policy;
```

### 2. A programmatic access token

```sql
ALTER USER <your_user> ADD PROGRAMMATIC ACCESS TOKEN n8n_capstone
  ROLE_RESTRICTION = 'ACCOUNTADMIN'
  DAYS_TO_EXPIRY   = 7;
```

The secret is shown once. Treat it as a password: put it straight into the n8n
credential and do not paste it anywhere else. Revoke with:

```sql
ALTER USER <your_user> REMOVE PROGRAMMATIC ACCESS TOKEN n8n_capstone;
```

### 3. Verify before importing

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_sql_api.ps1
```

This mints a short-lived token, calls `STAGE_QA` over the SQL API, prints the
result, then revokes the token and deletes the temp file. Expect:

```
SQL_API_STATUS: OK
SQL_API_RESULT: {"stage":"QA","gate":"PASS",...}
```

If you see `390432`, the network policy is missing. If you see `391902
Unsupported Accept header`, an `Accept: application/json` header is missing -
the SQL API requires it explicitly, which is why every HTTP node in these
workflows sets it.

## Import

1. Run n8n. Docker is not required:
   ```powershell
   npx.cmd n8n
   ```
   Then open http://localhost:5678.

2. Create the credential: **Credentials → New → Header Auth**
   - Name: `Snowflake PAT`
   - Header Name: `Authorization`
   - Header Value: `Bearer <your token secret>`

   Header Auth is used rather than a Snowflake node because the SQL API needs the
   companion header `X-Snowflake-Authorization-Token-Type: PROGRAMMATIC_ACCESS_TOKEN`,
   which the workflows set on each request.

3. **Workflows → Import from File** for each JSON.

4. In each imported workflow, open every HTTP Request node and select the
   `Snowflake PAT` credential. Credentials are deliberately not embedded in the
   exported JSON.

5. Edit the `Config` node if your account host differs from
   `igtstwc-td17035.snowflakecomputing.com`.

## Running the pipeline workflow

Execute the workflow. It will:

1. `STAGE_REQUIREMENTS` on the `reqId` in `Config`, default `REQ-101`.
2. Branch if governance refused the request. Set `reqId` to `REQ-102` to see this:
   the Workday request is blocked by the PRD pending a Data Processing Agreement,
   and the workflow halts having written zero stories. That is the control
   working, not a failure.
3. `STAGE_BUILD` scaffolds every source. Workday is included in the loop on
   purpose so the refusal appears in the run log rather than being hidden by a
   skip.
4. **Pause at the approval gate.** Open the execution, copy the resume URL from
   the Wait node, review the generated SQL in `ARTIFACTS.GENERATED_CODE`, then
   call the URL to continue.
5. `STAGE_DEPLOY` approves compiling artifacts, materialises the staging views and
   rebuilds the Silver Dynamic Table.
6. `STAGE_QA` regenerates, compiles and runs the test suite.
7. On failure, `STAGE_TRIAGE` raises a triaged defect. On success, it reports the
   release.

## Watchdog workflow

Runs `STAGE_QA` with `P_REGENERATE = FALSE` every six hours. A watchdog must run
the suite a human approved, not invent a new one each cycle. On failure it
triages and builds an alert; wire the trailing no-op to your Slack, Teams or
email node.

## Honest status

The workflow JSON is valid and imports cleanly, and the SQL API request shape is
verified correct - endpoint, headers, body and the callable stage procedures. The
final authenticated call was not executed end to end here, because doing so
requires attaching a network policy to the account, which is a security change
that belongs to whoever owns the account rather than to a build script. Run
`verify_sql_api.ps1` after step 1 to close that gap yourself in about a minute.
