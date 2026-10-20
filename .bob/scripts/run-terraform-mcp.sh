#!/usr/bin/env bash
# Wrapper for the HashiCorp Terraform MCP Server (Podman / Docker fallback).
# Bob executes this script; it inherits TFE_TOKEN from the shell environment.
# Never commit a token value into this file.
set -euo pipefail

CONTAINER_RUNTIME=""
if command -v podman >/dev/null 2>&1; then
  CONTAINER_RUNTIME="podman"
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_RUNTIME="docker"
else
  echo "ERROR: Neither podman nor docker found in PATH." >&2
  exit 1
fi

exec "$CONTAINER_RUNTIME" run \
  -i \
  --rm \
  -e "TFE_ADDRESS=${TFE_ADDRESS:-https://app.terraform.io}" \
  -e "TFE_TOKEN=${TFE_TOKEN:-}" \
  hashicorp/terraform-mcp-server:1.3.0
