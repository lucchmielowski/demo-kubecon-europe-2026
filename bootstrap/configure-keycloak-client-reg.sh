#!/usr/bin/env bash
# Disable Keycloak Trusted Hosts client registration policy for MCP Inspector.

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.kind.cluster:8080}"
REALM="${REALM:-master}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

echo "Configuring Keycloak client registration policy..."
echo "================================================="

echo "Getting admin token..."
TOKEN="$(curl -sS -f -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')"

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "Failed to get admin token"
  exit 1
fi
echo "Admin token acquired"

echo "Configuring realm frontend URL for HTTPS Keycloak endpoint..."
REALM_JSON="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}")"

UPDATED_REALM_JSON="$(echo "${REALM_JSON}" | jq '
  .attributes.frontendUrl = "http://keycloak.kind.cluster:8080" |
  .accessTokenLifespan = 3600
')"

REALM_UPDATE_CODE="$(curl -sS -o /tmp/realm-update-response.json -w "%{http_code}" \
  -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${UPDATED_REALM_JSON}")"

if [ "${REALM_UPDATE_CODE}" != "200" ] && [ "${REALM_UPDATE_CODE}" != "204" ]; then
  echo "Failed to set realm frontendUrl (HTTP ${REALM_UPDATE_CODE})"
  if [ -s /tmp/realm-update-response.json ]; then
    echo "Response:"
    jq '.' /tmp/realm-update-response.json 2>/dev/null || cat /tmp/realm-update-response.json
  fi
  exit 1
fi
echo "Realm frontendUrl set to http://keycloak.kind.cluster:8080"
echo "Realm accessTokenLifespan set to 3600s (1 hour)"

echo "Re-acquiring admin token after realm update..."
TOKEN="$(curl -sS -f -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')"

if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "Failed to re-acquire admin token after realm update"
  exit 1
fi
echo "Admin token re-acquired"

echo "Reading client registration policy components..."
COMPONENTS_JSON="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy")"

remove_policy_component() {
  local provider_id="$1"
  local subtype="$2"
  local component_id=""
  local http_code=""
  local response_file="/tmp/client-reg-delete-${provider_id}-${subtype}.json"

  component_id="$(echo "${COMPONENTS_JSON}" | jq -r --arg provider_id "${provider_id}" --arg subtype "${subtype}" '[.[] | select(.providerId == $provider_id and .subType == $subtype)][0].id')"

  if [ -z "${component_id}" ] || [ "${component_id}" = "null" ]; then
    echo "Policy '${provider_id}' (${subtype}) not found (already removed)."
    return 0
  fi

  echo "Removing policy '${provider_id}' (${subtype}) component (${component_id})..."
  http_code="$(curl -sS -o "${response_file}" -w "%{http_code}" \
    -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/components/${component_id}" \
    -H "Authorization: Bearer ${TOKEN}")"

  if [ "${http_code}" != "200" ] && [ "${http_code}" != "204" ]; then
    echo "Failed to remove policy '${provider_id}' (${subtype}) (HTTP ${http_code})"
    if [ -s "${response_file}" ]; then
      echo "Response:"
      jq '.' "${response_file}" 2>/dev/null || cat "${response_file}"
    fi
    exit 1
  fi

  echo "Policy '${provider_id}' (${subtype}) removed."
}

remove_policy_component "trusted-hosts" "anonymous"
remove_policy_component "allowed-client-templates" "anonymous"

echo "Client registration policy configuration completed."
