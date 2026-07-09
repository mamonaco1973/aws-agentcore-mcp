#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   End-to-end deployment of the AgentCore Cost Explorer connector. Provisions the
#   six cost Lambdas, the Cognito identity layer, and the Amazon Bedrock AgentCore
#   Gateway (with its six MCP tool targets) — then prints how to connect Claude.
#
# Note: creating the AgentCore Gateway can take several minutes.
# ================================================================================

# Default AWS region for all CLI and Terraform operations.
export AWS_DEFAULT_REGION="us-east-1"

# Strict shell: exit on error, error on unset vars, fail on any pipe stage.
set -euo pipefail

# ------------------------------------------------------------------------------
# Environment pre-check
# ------------------------------------------------------------------------------

echo "NOTE: Running environment validation..."
./check_env.sh

# ------------------------------------------------------------------------------
# Build Lambdas, Cognito, and the AgentCore Gateway
# ------------------------------------------------------------------------------

echo "NOTE: Building Lambdas, Cognito, and AgentCore Gateway..."

cd 01-lambdas || {
  echo "ERROR: 01-lambdas directory missing."
  exit 1
}

terraform init
terraform apply -auto-approve

# Capture connector details for the closing instructions.
GATEWAY_URL=$(terraform output -raw gateway_mcp_url)
CLIENT_ID=$(terraform output -raw mcp_client_id)
CLIENT_SECRET=$(terraform output -raw mcp_client_secret)
POOL_ID=$(terraform output -raw cognito_user_pool_id)

cd .. || exit

# ------------------------------------------------------------------------------
# Post-deployment validation
# ------------------------------------------------------------------------------

# Direct-invokes each cost Lambda to confirm Cost Explorer connectivity.
echo "NOTE: Running build validation..."
./validate.sh

# ------------------------------------------------------------------------------
# Connector instructions
# ------------------------------------------------------------------------------

cat <<EOF

================================================================================
  Deploy complete. Connect Claude to your cost tools:
================================================================================

  MCP endpoint (AgentCore Gateway):
       ${GATEWAY_URL}

  OAuth client (for the connector's auth settings):
       client_id:     ${CLIENT_ID}
       client_secret: ${CLIENT_SECRET}

  IMPORTANT — the connection is NOT one-click like the V1 project.
  AgentCore Gateway does not serve the MCP OAuth discovery / dynamic client
  registration endpoints, so Claude cannot self-register. Add the connector
  with the client_id + client_secret above (the "manual credentials" path).
  If your MCP client sends a redirect_uri other than the defaults in
  var.mcp_callback_urls, add it there and re-apply, or front the Gateway with
  the DCR shim. See README.md → "Connecting Claude".

  Users: self-signup is OPEN via the Cognito Hosted UI. Or pre-create one:

     aws cognito-idp admin-create-user \\
       --user-pool-id ${POOL_ID} \\
       --username you@example.com \\
       --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true

     aws cognito-idp admin-set-user-password \\
       --user-pool-id ${POOL_ID} \\
       --username you@example.com --password 'YourPassw0rd!' --permanent
================================================================================
EOF

# ================================================================================
# End of script
# ================================================================================
