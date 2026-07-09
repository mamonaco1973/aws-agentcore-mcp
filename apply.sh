#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   End-to-end deployment of the Cost Explorer MCP stack. Provisions the six cost
#   Lambdas, the MCP router Lambda, the Cognito identity layer, the OAuth state
#   table, and the HTTP API — then prints the connector URL to add to claude.ai.
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
# Build Lambdas, Cognito, DynamoDB, and API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: Building Lambdas, Cognito, and API Gateway..."

cd 01-lambdas || {
  echo "ERROR: 01-lambdas directory missing."
  exit 1
}

terraform init
terraform apply -auto-approve

# Capture the connector URL for the closing instructions.
MCP_ENDPOINT=$(terraform output -raw mcp_endpoint)

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

  1. In claude.ai:  Settings → Connectors → Add custom connector
  2. Paste this URL:

       ${MCP_ENDPOINT}

  3. Click Connect. Claude opens the Cognito login in your browser. New users
     can click "Sign up" to self-register (verify email), then sign in. On
     success the six cost tools appear — no local proxy, no API keys, no SigV4.

  NOTE: self-signup is OPEN — anyone who reaches this URL can register and read
  your AWS cost data. Keep the endpoint private, or lock it down (see README).

  You can also pre-create a user instead of self-signup:

     aws cognito-idp admin-create-user \\
       --user-pool-id \$(cd 01-lambdas && terraform output -raw cognito_user_pool_id) \\
       --username you@example.com \\
       --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true

     aws cognito-idp admin-set-user-password \\
       --user-pool-id \$(cd 01-lambdas && terraform output -raw cognito_user_pool_id) \\
       --username you@example.com --password 'YourPassw0rd!' --permanent
================================================================================
EOF

# ================================================================================
# End of script
# ================================================================================
