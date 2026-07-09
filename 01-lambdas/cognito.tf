# ================================================================================
# File: cognito.tf
#
# Purpose:
#   Cognito identity layer for the AgentCore Gateway connector. Cognito is the
#   OAuth authorization server AND the JWT issuer that AgentCore Gateway trusts:
#   the Gateway's CUSTOM_JWT authorizer validates every incoming token against
#   this user pool's OIDC discovery document, and only accepts tokens minted for
#   the MCP app client below.
#
# Difference from the hand-built (aws-cognito-mcp) version:
#   There, our own Lambda validated tokens via /oauth2/userInfo and we ran an
#   OAuth proxy to broker claude.ai's dynamic redirect_uri. Here the Gateway does
#   JWT validation natively — but it does NOT serve the MCP OAuth discovery / RFC
#   7591 registration endpoints, so claude.ai still needs help connecting. See
#   the "Connecting Claude" section in README.md.
# ================================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

# ================================================================================
# Cognito User Pool — the directory of humans allowed to use the cost tools
# ================================================================================
resource "aws_cognito_user_pool" "mcp" {
  name = "cost-agentcore-user-pool-${random_id.suffix.hex}"

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

  # Open self-service sign-up (AWS default, set explicitly). This exposes AWS
  # cost data to anyone who can reach the login — keep the connector private or
  # lock it down. Same posture as the V1 project.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }
}

# ================================================================================
# Cognito Hosted UI domain — where the user authenticates during the OAuth flow
# ================================================================================
resource "aws_cognito_user_pool_domain" "mcp" {
  domain       = "cost-agentcore-auth-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.mcp.id
}

# ================================================================================
# Cognito User Pool Client — the MCP connector client
#
# claude.ai drives the authorization-code + PKCE flow against this client and
# receives a Cognito access token; AgentCore Gateway then accepts that token
# because the client id is in the Gateway's allowed_clients list (gateway.tf).
#
# generate_secret = true supports the "paste client id + secret into the
# connector" path. The callback URLs must include the exact redirect the MCP
# client uses (see var.mcp_callback_urls).
# ================================================================================
resource "aws_cognito_user_pool_client" "mcp" {
  name         = "cost-agentcore-mcp-${random_id.suffix.hex}"
  user_pool_id = aws_cognito_user_pool.mcp.id

  generate_secret = true

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  # Claude holds the token for the session and has no refresh flow — issue the
  # Cognito maximum so the session doesn't drop mid-use.
  access_token_validity = 24
  token_validity_units {
    access_token = "hours"
  }

  supported_identity_providers = ["COGNITO"]

  # The MCP client's redirect target(s). Cognito requires an exact match, so
  # these must be the precise callback URLs the connector uses.
  callback_urls = var.mcp_callback_urls

  lifecycle {
    precondition {
      condition     = length(var.mcp_callback_urls) > 0
      error_message = "Set at least one mcp_callback_urls entry (the MCP client's OAuth redirect URL)."
    }
  }
}

# ================================================================================
# Optional test user — seeded only when var.test_user_email is set.
# ================================================================================
resource "aws_cognito_user" "test" {
  count = var.test_user_email != "" ? 1 : 0

  user_pool_id = aws_cognito_user_pool.mcp.id
  username     = var.test_user_email

  attributes = {
    email          = var.test_user_email
    email_verified = "true"
  }

  password       = var.test_user_password
  message_action = "SUPPRESS"
}

# ================================================================================
# Outputs
# ================================================================================
output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.mcp.id
}

output "cognito_domain" {
  description = "Hosted-UI domain prefix"
  value       = aws_cognito_user_pool_domain.mcp.domain
}

output "mcp_client_id" {
  value = aws_cognito_user_pool_client.mcp.id
}

output "mcp_client_secret" {
  description = "Paste into the Claude connector (confidential-client path)"
  value       = aws_cognito_user_pool_client.mcp.client_secret
  sensitive   = true
}

# OIDC discovery URL the Gateway uses to validate JWTs, and that the connector's
# OAuth flow ultimately authenticates against.
output "cognito_oidc_discovery_url" {
  value = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.mcp.id}/.well-known/openid-configuration"
}
