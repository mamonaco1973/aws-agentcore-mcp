# CLAUDE.md — aws-cognito-mcp

A serverless AWS Cost Explorer API exposed as a **remote MCP connector** secured
with **Cognito OAuth 2.0**. Claude (claude.ai / Claude Desktop) connects directly
to a remote `/mcp` endpoint over HTTPS, authenticates the user through Cognito's
Hosted UI, and calls the cost tools — **no local proxy, no SigV4, no API keys**.

> This is the Cognito port of `aws-serverless-mcp`, which used AWS_IAM auth and a
> local SigV4-signing proxy. The OAuth pattern here is adapted from
> `mycorpus-runtime` (`03-core/code/oauth.py` + `mcp.py`).

---

## What This Project Does

Six Lambda functions query the Cost Explorer API and return plain-text summaries.
A seventh **router Lambda** is the MCP front door: it serves the OAuth endpoints
and the MCP JSON-RPC endpoint, and on `tools/call` invokes the appropriate cost
Lambda via `lambda:InvokeFunction`. The six cost Lambdas are **not** exposed
through API Gateway anymore.

| Tool Name | Backing Lambda | Operation |
|-----------|----------------|-----------|
| get_month_to_date_cost | cost-mtd | MTD total spend |
| get_cost_by_service | cost-by-service | Per-service breakdown |
| compare_this_month_to_last_month | cost-compare | MoM delta |
| get_daily_cost_trend | cost-daily | Day-by-day spend |
| find_top_cost_drivers | cost-top-drivers | Ranked services |
| forecast_month_end_cost | cost-forecast | CE forecast |
| *(registry)* | cost-tools | `TOOL_REGISTRY` for `tools/list` |

---

## Architecture

```
Claude (claude.ai / Claude Desktop) — remote MCP client
     │  1. discover:  GET /.well-known/oauth-authorization-server
     │  2. register:  POST /oauth/register            (RFC 7591)
     │  3. login:     GET /authorize → Cognito Hosted UI → GET /oauth/callback
     │  4. token:     POST /oauth/token   (mac_ code → Cognito access token)
     │  5. use:       POST /mcp  (Authorization: Bearer <cognito access token>)
     ▼
API Gateway (HTTP API) — costs-mcp-api   [all routes PUBLIC; Lambda enforces auth]
     ▼
cost-mcp-router (Lambda)  ── router.py → oauth.py + mcp.py
     │   validates Bearer via Cognito /oauth2/userInfo
     │   tools/list → invoke cost-tools;  tools/call → invoke cost-<tool>
     ├── lambda:InvokeFunction ──▶ cost-mtd / cost-by-service / … / cost-forecast
     └── DynamoDB (cost-mcp-oauth) — transient PENDINGAUTH / AUTHCODE (5-min TTL)
                    │
     Cognito User Pool + Hosted UI + MCP confidential client (secret)
```

### The claude.ai redirect_uri problem (why oauth.py is a proxy)

claude.ai's `redirect_uri` embeds the org ID
(`https://claude.ai/api/organizations/<id>/mcp/callback`), which Cognito's
exact-match allow-list rejects. So `oauth.py` advertises **our own** API as the
OAuth authorization server, registers only our fixed `/oauth/callback` with
Cognito, brokers the Cognito login, and hands claude.ai a one-time `mac_` code
backed by the real Cognito access token in DynamoDB. The token passed to Claude
is a genuine Cognito access token — validated statelessly at `/mcp` via
`/oauth2/userInfo`. No custom crypto.

---

## Repository Layout

```
01-lambdas/
  code/
    costs.py         Six cost handlers + TOOL_REGISTRY (unchanged from the IAM version)
    oauth.py         OAuth 2.0 authorization-server proxy (metadata, register,
                     authorize, callback, token)
    mcp.py           MCP JSON-RPC handler; validates Cognito token; invokes cost Lambdas
    router.py        Lambda entrypoint; dispatches the public routes
  main.tf            AWS provider, data sources, archive_file (one zip, many handlers)
  variables.tf       Optional test-user email/password
  cognito.tf         User pool, Hosted UI domain, MCP confidential client, test user
  dynamo.tf          OAuth state table (pk/sk, TTL)
  api.tf             HTTP API, 6 public routes → router integration, stage, output
  lambda-mcp.tf      Router Lambda + IAM role (invoke cost Lambdas + DynamoDB) + env
  lambda-tools.tf    cost-tools Lambda (returns TOOL_REGISTRY)
  lambda-mtd.tf …    One file per cost Lambda (function + scoped CE role)
check_env.sh         Pre-flight: aws / terraform / jq + credential test
apply.sh             Deploy + validate + print connector instructions
destroy.sh           Teardown
validate.sh          Smoke test: direct-invoke each cost Lambda
```

---

## Auth model

- **API Gateway**: every route is public. An authorizer would reject the OAuth
  handshake and the client's initial unauthenticated `/mcp` probe.
- **`/mcp`**: `mcp._get_auth_user` requires a `Bearer` token and resolves it via
  Cognito `/oauth2/userInfo`. No token / invalid token → 401.
- **OAuth endpoints**: they *are* the authentication — they broker Cognito login.
- **Router → cost Lambdas**: `lambda:InvokeFunction` scoped to exactly the seven
  functions. The router holds no Cost Explorer permission; each cost Lambda keeps
  its own least-privilege CE role.
- **Users** live in the Cognito user pool. **Self-signup is OPEN**
  (`allow_admin_create_user_only = false` in cognito.tf): anyone who reaches the
  Hosted UI can register and then read AWS cost data — keep the endpoint private,
  or lock it down (pre-sign-up domain allowlist, or admin-create-only). You can
  also seed a user with `TF_VAR_test_user_email` / `TF_VAR_test_user_password`,
  or pre-create via `aws cognito-idp admin-create-user`.

---

## Key environment variables (router Lambda)

| Var | Source | Used by |
|-----|--------|---------|
| `TABLE_NAME` | `aws_dynamodb_table.oauth_state.name` | oauth.py |
| `COGNITO_DOMAIN` | Hosted UI domain prefix | oauth.py + mcp.py |
| `MCP_CLIENT_ID` | MCP Cognito client id | oauth.py |
| `MCP_CLIENT_SECRET` | MCP Cognito client secret | oauth.py |
| `TOOLS_FUNCTION` | `cost-tools` function name | mcp.py (`tools/list`) |
| `TOOL_FUNCTIONS` | JSON map tool→function name | mcp.py (`tools/call`) |

---

## Adding a tool

1. Add the handler to `costs.py` and its entry to `TOOL_REGISTRY`.
2. Add a `lambda-<tool>.tf` (function + scoped CE role), mirroring `lambda-mtd.tf`.
3. Add the tool→function mapping to `local.mcp_tool_functions` and the ARN to
   `local.mcp_invokable_arns` in `lambda-mcp.tf`.
4. `./apply.sh`. `tools/list` picks it up from the registry automatically.

---

## Gotchas that have bitten

- **Token lifetime must match.** `oauth_token()` reports `expires_in: 86400` to
  match the Cognito client's `access_token_validity = 24h`. Underreporting makes
  Claude attempt an unsupported refresh and silently drop the session after 1h.
- **`/mcp` and OAuth routes must stay public.** Do not attach a JWT authorizer —
  the flow breaks before a token exists.
- **CE endpoint is always us-east-1** regardless of deploy region (see costs.py).
- The `.drawio` / `.png` diagrams and `00-resources/` still depict the old
  IAM+proxy design — regenerate before reusing them.

## Code Commenting Standards

See the workspace-root `.claude/CLAUDE.md`: comment the *why*, not the *what*;
`# ===` section headers; inline comments only for non-obvious intent.
