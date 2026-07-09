# ================================================================================
# File: cognito.tf
#
# Purpose:
#   Provisions the Cognito identity layer that secures the MCP connector. Claude
#   (claude.ai / Claude Desktop) authenticates the human via Cognito's Hosted UI,
#   receives a Bearer access token through the OAuth flow in oauth.py, and sends
#   it on every POST /mcp call. mcp.py validates the token against Cognito's
#   /oauth2/userInfo endpoint.
#
# Why Cognito instead of the old IAM proxy:
#   The previous design signed each request with SigV4 from a local proxy script.
#   MCP clients cannot sign SigV4, so a local runtime was mandatory. Cognito OAuth
#   is a protocol Claude speaks natively — the proxy disappears entirely.
# ================================================================================

# --------------------------------------------------------------------------------
# Locals — a random suffix keeps the Hosted-UI domain globally unique per deploy.
# --------------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 4
}

# ================================================================================
# Cognito User Pool — the directory of humans allowed to use the cost tools
# ================================================================================
resource "aws_cognito_user_pool" "mcp" {
  name = "cost-mcp-user-pool-${random_id.suffix.hex}"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Open self-service sign-up: anyone can register through the Hosted UI "Sign up"
  # link and then use the cost tools. This is the AWS default, set explicitly so
  # the intent is documented and a later apply doesn't silently change it.
  # NOTE: this exposes AWS cost data to anyone who can reach the connector URL —
  # keep the endpoint private, or switch to a pre-sign-up domain allowlist /
  # allow_admin_create_user_only = true if that is too open.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }
}

# ================================================================================
# Cognito Hosted UI domain — where the user actually types their credentials
# ================================================================================
resource "aws_cognito_user_pool_domain" "mcp" {
  domain       = "cost-mcp-auth-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.mcp.id
}

# ================================================================================
# Cognito User Pool Client — MCP OAuth (confidential client with a secret)
#
# The client secret lives only in the router Lambda's env, never in a browser or
# in the MCP client. Only our own /oauth/callback URL is registered — claude.ai's
# dynamic redirect_uri is brokered by the proxy in oauth.py, not by Cognito.
# ================================================================================
resource "aws_cognito_user_pool_client" "mcp" {
  name         = "cost-mcp-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.mcp.id

  generate_secret = true

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Claude holds the access token for the whole session and has no refresh flow,
  # so issue the Cognito maximum. oauth_token() reports this same 24h lifetime —
  # underreporting makes the client attempt an unsupported refresh and drop the
  # session after 1 hour.
  access_token_validity = 24
  token_validity_units {
    access_token = "hours"
  }

  supported_identity_providers = ["COGNITO"]

  # Only our server-side callback — the proxy re-issues to claude.ai's real URL.
  callback_urls = ["${aws_apigatewayv2_api.costs_api.api_endpoint}/oauth/callback"]
}

# ================================================================================
# Optional test user — seeded only when var.test_user_email is set.
#
# Lets ./apply.sh produce a login that works end-to-end for demos. Leave the
# variables unset in production and create users through the Cognito console or
# `aws cognito-idp admin-create-user` instead (see README).
# ================================================================================
resource "aws_cognito_user" "test" {
  count = var.test_user_email != "" ? 1 : 0

  user_pool_id = aws_cognito_user_pool.mcp.id
  username     = var.test_user_email

  attributes = {
    email          = var.test_user_email
    email_verified = "true"
  }

  # Set a permanent password so the user can log in without a forced reset.
  password       = var.test_user_password
  message_action = "SUPPRESS"
}

# ================================================================================
# Outputs — consumed by validate.sh / apply.sh to print connector instructions
# ================================================================================
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.mcp.id
}

output "cognito_domain" {
  description = "Hosted-UI domain prefix (region-qualified URL built by the Lambda)"
  value       = aws_cognito_user_pool_domain.mcp.domain
}

output "mcp_client_id" {
  value = aws_cognito_user_pool_client.mcp.id
}
