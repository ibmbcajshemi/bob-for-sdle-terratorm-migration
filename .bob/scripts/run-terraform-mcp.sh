#!/usr/bin/env bash
# Wrapper for the HashiCorp Terraform MCP Server (Podman).
# Bob executes this script; it inherits TFE_TOKEN from the shell environment.
# Never commit a token value into this file.
set -euo pipefail

exec podman run \
  -i \
  --rm \
  -e "TFE_ADDRESS=${TFE_ADDRESS:-https://app.terraform.io}" \
  -e "TFE_TOKEN=${TFE_TOKEN}" \
  hashicorp/terraform-mcp-server:1.3.0
