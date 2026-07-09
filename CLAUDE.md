# CLAUDE.md — aws-agentcore-mcp

The **AgentCore-native** version of the Cost Explorer MCP connector. Six Lambda
tools are exposed to Claude through an **Amazon Bedrock AgentCore Gateway** with a
**Cognito CUSTOM_JWT** authorizer. There is no hand-built OAuth proxy, no MCP
JSON-RPC handler, and no HTTP API — the Gateway does all of that.

> **This is V2.** The sibling repo `aws-cognito-mcp` (V1) builds the exact same
> six cost tools with a *hand-rolled* front door: `oauth.py` + `mcp.py` +
> `router.py` + API Gateway. Same tools, two front doors — the pair is the
> "build it yourself vs. buy the managed service" comparison. Read V1's CLAUDE.md
> for the hand-built side.

---

## What This Project Does

The six cost Lambdas (`costs.py`) are unchanged in *logic* from V1 — they query
Cost Explorer and return plain-text summaries. Only two things differ:

1. **Response shape.** Handlers return the summary **string directly**. AgentCore
   Gateway relays a Lambda target's return value verbatim as the MCP tool result,
   so there is no API-Gateway `{statusCode, body}` envelope and no `_response`
   dict. (`_response` now just returns the text.)
2. **No tool registry in code.** Tool name / description / inputSchema are
   declared in each Gateway target's `tool_schema` block in `gateway.tf`. There
   is no `tools_handler` and no `cost-tools` Lambda.

---

## Architecture

```
Claude (claude.ai / Claude Desktop) — remote MCP client
     │  OAuth (authorization code + PKCE) against Cognito → Cognito access token
     │  MCP JSON-RPC over HTTPS, Authorization: Bearer <cognito access token>
     ▼
Amazon Bedrock AgentCore Gateway  (protocol_type = MCP)
     │  CUSTOM_JWT authorizer: validates the token against Cognito OIDC discovery,
     │  requires client_id ∈ allowed_clients
     │  assumes its IAM role to invoke the target Lambdas
     ├── target get_month_to_date_cost  → Lambda cost-mtd
     ├── target get_cost_by_service     → Lambda cost-by-service
     ├── target compare_this_month…     → Lambda cost-compare
     ├── target get_daily_cost_trend    → Lambda cost-daily
     ├── target find_top_cost_drivers   → Lambda cost-top-drivers
     └── target forecast_month_end_cost → Lambda cost-forecast
                                              │
                                     AWS Cost Explorer (us-east-1)

Cognito User Pool + Hosted UI + MCP app client  (the OAuth authorization server)
```

---

## Connecting Claude — the gap you must know about

This is the headline difference from V1, and the reason V1 is not obsolete.

**AgentCore Gateway does not serve the MCP OAuth spec endpoints** — RFC 8414
authorization-server metadata and RFC 7591 dynamic client registration — and
Cognito does not support DCR either. So claude.ai / Claude Desktop **cannot
self-register**. Two ways to connect:

1. **Manual credentials (default here).** Add the connector with the `client_id`
   and `client_secret` that `apply.sh` prints (from the Cognito MCP client). The
   client's redirect URL must be one of `var.mcp_callback_urls` (defaults cover
   `https://claude.ai|claude.com/api/mcp/auth_callback`). Cognito requires an
   exact match, so if your client uses a different redirect, add it and re-apply.
2. **DCR shim (the V1 punchline).** Front the Gateway with a small service that
   serves `/.well-known/oauth-protected-resource` + OIDC metadata + `/register`,
   creating/returning Cognito clients and pointing Claude at Cognito for
   authorize/token. That shim is essentially V1's `oauth.py`. Not built in this
   repo — see "Deferred" below. Reference: `stache-ai/agentcore-dcr` and
   awslabs/agentcore-samples issue #1056.

The teaching point: the managed service replaced ~700 lines of our plumbing, but
the last-mile OAuth discovery for claude.ai still needs the hand-built piece.

---

## Repository Layout

```
01-lambdas/
  code/
    costs.py         Six cost handlers (logic unchanged; returns plain strings)
  main.tf            AWS provider (pinned >= 6.32 for AgentCore), archive_file
  variables.tf       test-user knobs + mcp_callback_urls
  cognito.tf         User pool (open signup), Hosted UI domain, MCP app client
  gateway.tf         Gateway IAM role, aws_bedrockagentcore_gateway (CUSTOM_JWT),
                     six aws_bedrockagentcore_gateway_target (for_each)
  lambda-mtd.tf …    One file per cost Lambda (function + scoped CE role)
check_env.sh         Pre-flight: aws / terraform / jq + credential test
apply.sh             Deploy + validate + print connector instructions
destroy.sh           Teardown (Gateway teardown can take minutes)
validate.sh          Smoke test: direct-invoke each cost Lambda
```

Gone vs. V1: `oauth.py`, `mcp.py`, `router.py`, `api.tf`, `dynamo.tf`,
`lambda-mcp.tf`, `lambda-tools.tf`.

---

## Auth model

- **Gateway CUSTOM_JWT authorizer** validates the Cognito access token against
  `discovery_url` (the pool's OIDC config) and `allowed_clients` (the MCP client
  id). This is the managed equivalent of V1's `_get_auth_user` + `/oauth2/userInfo`.
- **Gateway → Lambdas**: the Gateway assumes `aws_iam_role.gateway_role`, scoped
  to `lambda:InvokeFunction` on exactly the six cost Lambdas. Each Lambda keeps
  its own least-privilege Cost Explorer role.
- **Users**: Cognito pool, **open self-signup** (same posture as V1 — exposes
  cost data to anyone who can reach the login; keep it private or lock down).

---

## Adding a tool

1. Add the handler to `costs.py` (return a string via `_response`).
2. Add a `lambda-<tool>.tf` (function + scoped CE role), mirroring `lambda-mtd.tf`.
3. Add an entry to `local.cost_tools` in `gateway.tf` (tool name, description,
   `lambda_arn`). The `for_each` creates the target and the invoke policy picks
   up the ARN automatically.
4. `./apply.sh`.

---

## Gotchas / things to verify on first deploy

- **Terraform provider must be ≥ 6.32** for the `aws_bedrockagentcore_*`
  resources (pinned in `main.tf`).
- **Gateway service principal** is assumed to be `bedrock-agentcore.amazonaws.com`
  in `gateway.tf`'s trust policy — confirm on first apply.
- **Tool naming**: Gateway may namespace a tool as `<target-name>___<tool-name>`.
  If the model sees prefixed names, that's why. Verify against a live `tools/list`.
- **claude.ai connect is not one-click** — see "Connecting Claude" above.
- **Create/destroy latency**: AgentCore Gateway operations can take minutes
  (30-min Terraform timeouts).
- The `.drawio`/`00-resources` assets are inherited from V1 and depict the
  hand-built design — regenerate for this architecture.

## Deferred (not in this repo yet)

- The **DCR shim** for true one-click claude.ai connect. It's V1's `oauth.py`
  adapted to front the Gateway. Left out because its exact discovery chaining
  with Gateway needs live testing against claude.ai before shipping.

## Code Commenting Standards

See the workspace-root `.claude/CLAUDE.md`: comment the *why*, not the *what*;
`# ===` section headers; inline comments only for non-obvious intent.
