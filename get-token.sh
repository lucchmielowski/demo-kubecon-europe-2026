#!/usr/bin/env bash

RESPONSE=$(curl -s -X POST http://keycloak.localhost:18080/realms/master/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'grant_type=password' \
  -d 'client_id=mcp-inspector' \
  -d "username=$1" \
  -d "password=$1" \
  -d 'scope=openid')

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
  echo "Failed to obtain token" >&2
  echo "$RESPONSE" | jq >&2
  exit 1
fi

# Print to stdout (so it can be captured)
echo "$TOKEN"

# Also copy to clipboard on mac
if command -v pbcopy >/dev/null 2>&1; then
  echo "$TOKEN" | pbcopy
fi