#!/usr/bin/env bash
# Configure Keycloak: realm, users, groups, clients.
# Replaces Terraform + configure-keycloak-client-reg.sh.
# Bash 3.2+ compatible (no associative arrays).

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak.localhost:18080}"
REALM="${REALM:-master}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"

log() { echo "[setup-keycloak] $*"; }

get_token() {
  curl -sS -f -X POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" | jq -r '.access_token'
}

get_group_id() {
  local name="$1"
  curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    | jq -r --arg g "${name}" '.[] | select(.name == $g) | .id'
}

get_user_id() {
  local username="$1"
  curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=${username}" \
    | jq -r '.[0].id // empty'
}

log "Waiting for Keycloak at ${KEYCLOAK_URL}..."
max_attempts=60
attempt=0
while [ $attempt -lt $max_attempts ]; do
  if curl -sf "${KEYCLOAK_URL}/realms/${REALM}/.well-known/openid-configuration" >/dev/null 2>&1; then
    log "Keycloak is ready"
    break
  fi
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    echo "ERROR: Keycloak did not become ready after ${max_attempts} attempts" >&2
    exit 1
  fi
  sleep 2
done

TOKEN="$(get_token)"
if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "null" ]; then
  echo "ERROR: Failed to get admin token" >&2
  exit 1
fi
log "Admin token acquired"

# ── Realm: set frontendUrl + accessTokenLifespan ──────────────────────────────

log "Configuring realm frontendUrl and accessTokenLifespan..."
REALM_JSON="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}")"

UPDATED_REALM_JSON="$(echo "${REALM_JSON}" | jq '
  .attributes.frontendUrl = "http://keycloak.localhost:18080" |
  .accessTokenLifespan = 3600
')"

CODE="$(curl -sS -o /dev/null -w "%{http_code}" \
  -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${UPDATED_REALM_JSON}")"

[ "${CODE}" = "200" ] || [ "${CODE}" = "204" ] || { echo "ERROR: realm update failed (HTTP ${CODE})" >&2; exit 1; }
log "Realm configured"

# Re-acquire token after realm update
TOKEN="$(get_token)"
[ -n "${TOKEN}" ] && [ "${TOKEN}" != "null" ] || { echo "ERROR: Failed to re-acquire token" >&2; exit 1; }

# ── Client registration policies: remove trusted-hosts + allowed-client-templates ──

log "Removing restrictive client registration policies..."
COMPONENTS="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy")"

remove_policy() {
  local provider_id="$1" subtype="$2"
  local id
  id="$(echo "${COMPONENTS}" | jq -r --arg p "${provider_id}" --arg s "${subtype}" \
    '[.[] | select(.providerId == $p and .subType == $s)][0].id')"
  if [ -z "${id}" ] || [ "${id}" = "null" ]; then
    log "Policy '${provider_id}' (${subtype}) not found, skipping"
    return 0
  fi
  CODE="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/components/${id}" \
    -H "Authorization: Bearer ${TOKEN}")"
  [ "${CODE}" = "200" ] || [ "${CODE}" = "204" ] || { echo "ERROR: failed to delete policy ${provider_id} (HTTP ${CODE})" >&2; exit 1; }
  log "Removed policy '${provider_id}' (${subtype})"
}

remove_policy "trusted-hosts" "anonymous"
remove_policy "allowed-client-templates" "anonymous"

# ── Client scope: groups ───────────────────────────────────────────────────────

log "Creating 'groups' client scope..."
SCOPE_ID="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | jq -r '.[] | select(.name == "groups") | .id')"

if [ -z "${SCOPE_ID}" ]; then
  curl -sS -f -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"groups","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","gui.order":"1"}}' \
    >/dev/null
  SCOPE_ID="$(curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | jq -r '.[] | select(.name == "groups") | .id')"
  log "Created 'groups' scope (${SCOPE_ID})"
else
  log "'groups' scope already exists (${SCOPE_ID})"
fi

# Add GroupMembership mapper to groups scope
EXISTING="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
  | jq -r '[.[] | select(.name == "groups")] | length')"
if [ "${EXISTING}" = "0" ]; then
  curl -sS -f -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${SCOPE_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "groups",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-group-membership-mapper",
      "config": {
        "claim.name": "groups",
        "full.path": "false",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }' >/dev/null
  log "Added GroupMembership mapper to 'groups' scope"
fi

# Add groups-for-dynamic-clients mapper to built-in 'basic' scope
log "Adding groups mapper to 'basic' scope..."
BASIC_ID="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | jq -r '.[] | select(.name == "basic") | .id')"

if [ -n "${BASIC_ID}" ] && [ "${BASIC_ID}" != "null" ]; then
  EXISTING="$(curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${BASIC_ID}/protocol-mappers/models" \
    | jq -r '[.[] | select(.name == "groups-for-dynamic-clients")] | length')"
  if [ "${EXISTING}" = "0" ]; then
    curl -sS -f -X POST \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes/${BASIC_ID}/protocol-mappers/models" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "groups-for-dynamic-clients",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-group-membership-mapper",
        "config": {
          "claim.name": "groups",
          "full.path": "false",
          "id.token.claim": "true",
          "access.token.claim": "true",
          "userinfo.token.claim": "true"
        }
      }' >/dev/null
    log "Added groups mapper to 'basic' scope"
  else
    log "groups mapper already on 'basic' scope"
  fi
else
  log "WARNING: 'basic' scope not found, skipping"
fi

# ── Groups ─────────────────────────────────────────────────────────────────────

log "Creating groups..."
create_group() {
  local group="$1"
  local existing_id
  existing_id="$(get_group_id "${group}")"
  if [ -z "${existing_id}" ]; then
    curl -sS -f -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"${group}\"}" >/dev/null
    log "Created group '${group}'"
  else
    log "Group '${group}' already exists (${existing_id})"
  fi
}

create_group kube-dev
create_group kube-admin
create_group restricted

# ── Users ──────────────────────────────────────────────────────────────────────

log "Creating users..."
create_user() {
  local username="$1"
  local existing_id
  existing_id="$(get_user_id "${username}")"
  if [ -z "${existing_id}" ]; then
    curl -sS -f -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/users" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${username}\",
        \"email\": \"${username}@domain.com\",
        \"firstName\": \"${username}\",
        \"lastName\": \"${username}\",
        \"emailVerified\": true,
        \"enabled\": true,
        \"credentials\": [{\"type\":\"password\",\"value\":\"${username}\",\"temporary\":false}]
      }" >/dev/null
    log "Created user '${username}'"
  else
    log "User '${username}' already exists (${existing_id})"
  fi
}

create_user alice
create_user user-dev
create_user user-admin
create_user unauthorized-user

# ── Group assignments ──────────────────────────────────────────────────────────

log "Assigning users to groups..."
assign_group() {
  local username="$1" groupname="$2"
  local uid gid
  uid="$(get_user_id "${username}")"
  gid="$(get_group_id "${groupname}")"
  [ -n "${uid}" ] && [ "${uid}" != "null" ] || { echo "ERROR: user '${username}' not found" >&2; exit 1; }
  [ -n "${gid}" ] && [ "${gid}" != "null" ] || { echo "ERROR: group '${groupname}' not found" >&2; exit 1; }
  CODE="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X PUT "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${uid}/groups/${gid}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Length: 0")"
  [ "${CODE}" = "200" ] || [ "${CODE}" = "204" ] || { echo "ERROR: assign ${username}→${groupname} failed (HTTP ${CODE})" >&2; exit 1; }
  log "  ${username} → ${groupname}"
}

assign_group alice kube-dev
assign_group user-dev kube-dev
assign_group user-admin kube-admin
assign_group unauthorized-user restricted

# ── Helper: get or create client, return client UUID ──────────────────────────

get_client_uuid() {
  local client_id="$1"
  curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients?clientId=${client_id}" \
    | jq -r '.[0].id // empty'
}

create_client() {
  local payload="$1"
  curl -sS -f -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}" >/dev/null
}

set_default_scope() {
  local uuid="$1" scope_name="$2"
  local sid
  sid="$(curl -sS -f \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/client-scopes" | jq -r --arg n "${scope_name}" '.[] | select(.name == $n) | .id')"
  [ -n "${sid}" ] && [ "${sid}" != "null" ] || { log "WARNING: scope '${scope_name}' not found"; return; }
  curl -sS -o /dev/null -X PUT \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${uuid}/default-client-scopes/${sid}" \
    -H "Authorization: Bearer ${TOKEN}"
}

# ── Client: kube ───────────────────────────────────────────────────────────────

log "Creating 'kube' client..."
KUBE_UUID="$(get_client_uuid kube)"
if [ -z "${KUBE_UUID}" ]; then
  create_client '{
    "clientId": "kube",
    "name": "kube",
    "enabled": true,
    "publicClient": false,
    "secret": "kube-client-secret",
    "standardFlowEnabled": false,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {"access.token.lifespan": "31536000"}
  }'
  KUBE_UUID="$(get_client_uuid kube)"
  log "Created 'kube' client (${KUBE_UUID})"
else
  log "'kube' client already exists (${KUBE_UUID})"
fi
set_default_scope "${KUBE_UUID}" "email"
set_default_scope "${KUBE_UUID}" "groups"

# Add audience mapper so JWT includes gateway as audience
EXISTING="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${KUBE_UUID}/protocol-mappers/models" \
  | jq -r '[.[] | select(.name == "gateway-audience")] | length')"
if [ "${EXISTING}" = "0" ]; then
  curl -sS -f -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${KUBE_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "gateway-audience",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.custom.audience": "http://gateway.localhost:8080/mcp",
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }' >/dev/null
  log "Added gateway-audience mapper to kube client"
fi

# ── Client: mcp-inspector ──────────────────────────────────────────────────────

log "Creating 'mcp-inspector' client..."
MCP_INSP_UUID="$(get_client_uuid mcp-inspector)"
if [ -z "${MCP_INSP_UUID}" ]; then
  create_client '{
    "clientId": "mcp-inspector",
    "name": "MCP Inspector",
    "enabled": true,
    "publicClient": true,
    "standardFlowEnabled": true,
    "implicitFlowEnabled": false,
    "directAccessGrantsEnabled": true,
    "attributes": {
      "access.token.lifespan": "31536000",
      "oauth2.device.authorization.grant.enabled": "true",
      "pkce.code.challenge.method": ""
    },
    "redirectUris": [
      "http://localhost:6274/callback",
      "http://localhost:6274/oauth/callback",
      "http://localhost:6274/oauth/callback/debug"
    ],
    "webOrigins": ["http://localhost:6274"]
  }'
  MCP_INSP_UUID="$(get_client_uuid mcp-inspector)"
  log "Created 'mcp-inspector' client (${MCP_INSP_UUID})"
else
  log "'mcp-inspector' client already exists (${MCP_INSP_UUID})"
fi
set_default_scope "${MCP_INSP_UUID}" "email"
set_default_scope "${MCP_INSP_UUID}" "groups"

# Add audience mapper so JWT includes gateway as audience
EXISTING="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${MCP_INSP_UUID}/protocol-mappers/models" \
  | jq -r '[.[] | select(.name == "gateway-audience")] | length')"
if [ "${EXISTING}" = "0" ]; then
  curl -sS -f -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${MCP_INSP_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "gateway-audience",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.custom.audience": "http://gateway.localhost:8080/mcp",
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }' >/dev/null
  log "Added gateway-audience mapper to mcp-inspector client"
fi

# Add preferred_username mapper
EXISTING="$(curl -sS -f \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${MCP_INSP_UUID}/protocol-mappers/models" \
  | jq -r '[.[] | select(.name == "preferred-username")] | length')"
if [ "${EXISTING}" = "0" ]; then
  curl -sS -f -X POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/clients/${MCP_INSP_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "preferred-username",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-usermodel-property-mapper",
      "config": {
        "user.attribute": "username",
        "claim.name": "preferred_username",
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true"
      }
    }' >/dev/null
  log "Added preferred_username mapper to mcp-inspector"
fi

# ── Client: mcp_dynamic_fallback ───────────────────────────────────────────────

MCP_DYN_CLIENT_ID="mcp_gi3APARn2_uHv2oxfJJqq2yZBDV4OyNo"
log "Creating '${MCP_DYN_CLIENT_ID}' client..."
MCP_DYN_UUID="$(get_client_uuid "${MCP_DYN_CLIENT_ID}")"
if [ -z "${MCP_DYN_UUID}" ]; then
  create_client "{
    \"clientId\": \"${MCP_DYN_CLIENT_ID}\",
    \"name\": \"MCP Dynamic Fallback\",
    \"enabled\": true,
    \"publicClient\": true,
    \"standardFlowEnabled\": true,
    \"implicitFlowEnabled\": false,
    \"directAccessGrantsEnabled\": false,
    \"attributes\": {\"access.token.lifespan\": \"31536000\"},
    \"redirectUris\": [
      \"http://localhost:6274/oauth/callback\",
      \"http://localhost:6274/oauth/callback/debug\"
    ],
    \"webOrigins\": [\"http://localhost:6274\"]
  }"
  MCP_DYN_UUID="$(get_client_uuid "${MCP_DYN_CLIENT_ID}")"
  log "Created '${MCP_DYN_CLIENT_ID}' client (${MCP_DYN_UUID})"
else
  log "'${MCP_DYN_CLIENT_ID}' client already exists (${MCP_DYN_UUID})"
fi
set_default_scope "${MCP_DYN_UUID}" "email"
set_default_scope "${MCP_DYN_UUID}" "groups"

log "Keycloak setup complete."
