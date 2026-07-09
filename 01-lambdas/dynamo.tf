# ================================================================================
# File: dynamo.tf
#
# Purpose:
#   Transient state store for the OAuth authorization-code proxy (oauth.py).
#   It holds nothing durable — only two short-lived record types, each with a
#   5-minute TTL:
#     pk=PENDINGAUTH#<sess>  sk=PENDINGAUTH  — the claude.ai redirect_uri + state
#                                              captured while the user logs in
#     pk=AUTHCODE#<code>     sk=AUTHCODE     — the one-time mac_ code mapped to the
#                                              real Cognito access token
#
# Why a table at all: the OAuth flow bounces the browser Cognito → our callback →
# claude.ai across separate stateless Lambda invocations, so the in-flight state
# has to live somewhere both invocations can read. DynamoDB TTL auto-reaps it.
# ================================================================================

resource "aws_dynamodb_table" "oauth_state" {
  name         = "cost-mcp-oauth-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "pk"
  range_key = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  # Auto-expire in-flight OAuth records — every item carries a `ttl` epoch attr.
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}
