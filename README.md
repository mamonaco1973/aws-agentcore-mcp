# AWS AgentCore MCP — Cost Explorer Connector

This project exposes six AWS **Cost Explorer** tools to Claude as a remote **MCP
(Model Context Protocol)** connector — built on **Amazon Bedrock AgentCore
Gateway** with an **Amazon Cognito** JWT authorizer. AgentCore Gateway turns each
Lambda into an MCP tool and enforces inbound OAuth, so there is **no hand-written
OAuth proxy, MCP protocol handler, or API Gateway** in this repo.

It uses **Terraform** and **Python (boto3)**. The Lambda tool logic is identical
to the hand-built version — only the front door changed.

> ## Two versions, one comparison
> This is **V2**. Its sibling repo **`aws-cognito-mcp`** (V1) implements the exact
> same six cost tools with a *hand-rolled* front door: an OAuth 2.0
> authorization-server proxy (`oauth.py`), an MCP JSON-RPC handler (`mcp.py`), a
> router Lambda, and an HTTP API — roughly 700 lines of plumbing. **V2 deletes
> almost all of it** and lets AgentCore Gateway do the work. The interesting part
> is what the managed service *doesn't* do — see **Connecting Claude** below.

## Architecture

```
Claude ──OAuth (code+PKCE) → Cognito──▶ Cognito access token
Claude ──MCP over HTTPS, Bearer token──▶ AgentCore Gateway
                                          │  CUSTOM_JWT authorizer (validates
                                          │  token vs Cognito OIDC + allowed_clients)
                                          │  assumes its IAM role to invoke:
                                          ├─▶ Lambda cost-mtd, cost-by-service, …
                                          └─▶ Cost Explorer (us-east-1)
```

## What gets built

- **6 cost Lambdas** (`cost-mtd`, `cost-by-service`, `cost-compare`, `cost-daily`,
  `cost-top-drivers`, `cost-forecast`), each with a least-privilege Cost Explorer
  role. Logic unchanged from V1; they return plain-text summaries.
- **AgentCore Gateway** (`protocol_type = MCP`) with a **CUSTOM_JWT** authorizer
  bound to the Cognito pool, and **six Gateway targets** (one per Lambda) whose
  `tool_schema` declares the MCP tool the model sees.
- **Gateway IAM role** scoped to `lambda:InvokeFunction` on exactly those six.
- **Cognito** user pool + Hosted UI domain + MCP app client (the OAuth server).

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/) with Cost Explorer enabled
* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  and [Terraform](https://developer.hashicorp.com/terraform/install)
  (**AWS provider ≥ 6.32** — required for the AgentCore resources; pinned in `main.tf`)
* `jq` in PATH
* Access to Amazon Bedrock AgentCore in your account/region

## Deploy

```bash
# Optional: seed a ready-to-log-in Cognito user
export TF_VAR_test_user_email="you@example.com"
export TF_VAR_test_user_password="ChangeMe-Str0ng!"

./apply.sh
```

`apply.sh` validates the environment, `terraform apply`s the stack (creating the
Gateway can take a few minutes), direct-invokes each cost Lambda to confirm Cost
Explorer connectivity, and prints the MCP endpoint + OAuth client credentials.

## Connecting Claude

**This is not one-click**, and that is the whole lesson of V2.

AgentCore Gateway does **not** serve the MCP OAuth discovery endpoints (RFC 8414
metadata, RFC 7591 dynamic client registration), and Cognito doesn't support DCR.
So Claude cannot auto-register. You have two options:

1. **Manual credentials (default).** In claude.ai → Settings → Connectors → Add
   custom connector, paste the Gateway MCP URL and supply the `client_id` /
   `client_secret` from `apply.sh`. The connector's redirect URL must be one of
   `var.mcp_callback_urls` (defaults cover claude.ai / claude.com); Cognito needs
   an exact match, so add yours and re-apply if it differs.
2. **DCR shim.** Front the Gateway with a small service that serves the
   discovery + `/register` endpoints and brokers Cognito — essentially V1's
   `oauth.py`. Not included here (see the repo's CLAUDE.md → "Deferred").
   References: [awslabs/agentcore-samples #1056](https://github.com/awslabs/agentcore-samples/issues/1056),
   [stache-ai/agentcore-dcr](https://github.com/stache-ai/agentcore-dcr).

> **The takeaway:** the managed service removed ~700 lines of our plumbing, but
> the last-mile OAuth discovery for claude.ai still wants the hand-built piece.
> Understanding V1 is what lets you diagnose and fix that in minutes.

Users self-register through the Cognito Hosted UI (**open signup** — anyone who
can reach the login can read your cost data; keep it private or lock it down), or
you pre-create one with `aws cognito-idp admin-create-user`.

## Teardown

```bash
./destroy.sh    # Gateway teardown can take several minutes
```

## MCP Tools

| Tool | Backing Lambda | Description |
|------|----------------|-------------|
| `get_month_to_date_cost` | `cost-mtd` | Total AWS spend from the 1st of this month through today |
| `get_cost_by_service` | `cost-by-service` | MTD spend by service, sorted descending |
| `compare_this_month_to_last_month` | `cost-compare` | This month MTD vs last month full total |
| `get_daily_cost_trend` | `cost-daily` | Day-by-day spend with running totals |
| `find_top_cost_drivers` | `cost-top-drivers` | Top 10 services by spend with % share |
| `forecast_month_end_cost` | `cost-forecast` | Projected remaining spend (80% CI) |

Tool metadata is declared in each Gateway target's `tool_schema` (`gateway.tf`),
not in code.

## V1 vs V2 at a glance

| | V1 `aws-cognito-mcp` | V2 `aws-agentcore-mcp` |
|---|---|---|
| MCP protocol | hand-written `mcp.py` | AgentCore Gateway |
| Inbound auth | `oauth.py` proxy + `/oauth2/userInfo` | Gateway CUSTOM_JWT authorizer |
| Transport | API Gateway HTTP API | Gateway endpoint |
| Tool → Lambda | router `lambda:InvokeFunction` | Gateway targets |
| claude.ai connect | one-click (proxy does DCR) | manual creds, or add a DCR shim |
| Extra state | DynamoDB (OAuth codes) | none |
| Lines of front-door code | ~700 | ~0 (Terraform config) |
