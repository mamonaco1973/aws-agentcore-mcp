# ==========================================================================================
# Terraform + AWS Provider Configuration
# ------------------------------------------------------------------------------------------
# Purpose:
#   - Defines the AWS provider and its default region for all Terraform resources
#   - Pins a provider new enough to include the AgentCore Gateway resources
#     (aws_bedrockagentcore_gateway / _gateway_target were added in the 6.x line)
# ==========================================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.32"
    }
  }
}

provider "aws" {
  region = "us-east-1" # Primary AWS region (N. Virginia)
}

# ------------------------------------------------------------------------------
# AWS Data Sources
# ------------------------------------------------------------------------------
# Retrieve the current AWS account ID and active region for dynamic references.
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {} # Returns the AWS account ID and ARN
data "aws_region" "current" {}          # Returns the currently configured region

# --------------------------------------------------------------------------------
# DATA: archive_file.lambdas_zip
# --------------------------------------------------------------------------------
# Description:
#   Packages all Lambda source code from the local "code" directory into a ZIP
#   archive. All six handler functions live in costs.py so a single ZIP serves
#   every Lambda function defined in this module.
#
# Expected code layout:
#   code/
#     costs.py   — contains all six cost-query handler functions
# --------------------------------------------------------------------------------
data "archive_file" "lambdas_zip" {
  type        = "zip"
  source_dir  = "${path.module}/code"
  output_path = "${path.module}/lambdas.zip"
}
