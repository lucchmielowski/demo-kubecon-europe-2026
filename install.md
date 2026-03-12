# MCP Least Privilege Demo - Complete Tutorial

This tutorial walks you through setting up a complete demonstration of the MCP (Model Context Protocol) Gateway with least privilege access controls for Kubernetes. You'll learn how to integrate Keycloak for authentication, implement OIDC-based access control, and enforce fine-grained authorization policies using Kyverno.

## Overview

By the end of this tutorial, you will have:
- A Kind cluster configured with OIDC authentication
- Keycloak as an identity provider with user groups and OAuth 2.0 support
- AgentgatewayPolicy with MCP authentication for seamless OAuth flows
- Role-based access control (RBAC) for different user personas
- Kyverno authorization policies enforcing MCP tool access
- agentgateway for routing MCP requests with authentication and authorization checks

**Key Feature**: This demo showcases **MCP authentication** via AgentgatewayPolicy, which enables MCP clients (like MCP Inspector, VS Code, or Claude Code) to automatically discover OAuth endpoints, dynamically register with Keycloak, and complete the OAuth 2.0 flow without manual token management.

## Prerequisites

Before starting, ensure you have the following tools installed:
- `kind` (Kubernetes in Docker)
- `kubectl`
- `helm` (v3)
- `openssl`
- `curl`
- `jq`

You should also have basic familiarity with:
- Kubernetes concepts (pods, deployments, namespaces)
- RBAC (roles, role bindings)
- Basic networking concepts

## Architecture

This demo implements a gateway pattern with MCP authentication where:
1. MCP clients discover OAuth endpoints through the AgentgatewayPolicy
2. Clients dynamically register with Keycloak to obtain a client ID
3. Users complete the OAuth flow via Keycloak to receive JWT tokens
4. MCP requests with JWT tokens are routed through agentgateway
5. Kyverno validates requests against RBAC policies and business rules
6. Only authorized actions reach the Kubernetes API server

The AgentgatewayPolicy enables seamless MCP OAuth authentication by:
- Exposing OAuth discovery endpoints (`.well-known/oauth-protected-resource` and `.well-known/oauth-authorization-server`)
- Facilitating dynamic client registration with Keycloak
- Validating JWT tokens using JWKS from Keycloak
- Enforcing strict token validation (issuer, audience, claims)

## Step 1: Generate SSL Certificates

First, we need to create a Certificate Authority (CA) and SSL certificates for securing Keycloak. These certificates will be used to enable HTTPS communication with the Keycloak instance.

```sh
# Create directory for SSL certificates
mkdir -p .ssl

# Generate a private key for the root CA
openssl genrsa -out .ssl/root-ca-key.pem 4096

# Generate a self-signed root CA certificate (valid for 10 years)
openssl req -x509 -new -nodes -key .ssl/root-ca-key.pem \
  -sha256 -days 3650 -out .ssl/root-ca.pem \
  -subj "/CN=Kind Root CA"
```

The root CA certificate will be mounted into the Kubernetes API server so it can validate tokens from Keycloak.

## Step 2: Create Kind Cluster with OIDC Support

Now we'll create a Kind cluster configured to use Keycloak as an OIDC provider. The API server needs specific flags to enable OIDC authentication.

```sh
# create cluster with our generated certificate
# and pass necessary arguments to api server
kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
```

**What this does:**
- Creates a Kind cluster with OIDC authentication enabled
- Configures the API server with Keycloak as the OIDC issuer
- Mounts the root CA certificate so the API server can verify Keycloak's SSL certificate
- Extracts user identity from the `email` claim and group membership from the `groups` claim in JWT tokens

We also need to install MetalLB to provide a way for the ingress controller to expose services outside the cluster.

First get the available addresses from the docker IPAM:

```sh
docker network inspect -f '{{.IPAM.Config}}' kind
# ex: [{172.18.0.0/16  172.18.0.1 map[]} {fc00:f853:ccd:e793::/64  fc00:f853:ccd:e793::1 map[]}]
```

From there you can install and setup the MetalLB config:

```sh
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
# Configure MetalLB IP Pool and L2Advertisement
kubectl apply -f bootstrap/metallb-config.yaml
```

## Step 3: Install cert-manager

cert-manager is required by Kyverno for certificate management:

```sh
helm upgrade -i cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.19.2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

**Note**: We're NOT using NGINX Ingress! Keycloak is exposed directly via LoadBalancer (MetalLB), and AgentgatewayPolicy accesses it securely via the internal Kubernetes service.

## Step 4: Generate Keycloak SSL Certificates

Create SSL certificates for Keycloak, signed by our root CA:

```sh
# Create certificate configuration file
cat <<EOF > .ssl/req.cnf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = keycloak.kind.cluster
EOF

# Generate private key
openssl genrsa -out .ssl/key.pem 2048

# Create certificate signing request
openssl req -new -key .ssl/key.pem -out .ssl/csr.pem \
  -subj "/CN=kube-ca" \
  -addext "subjectAltName = DNS:keycloak.kind.cluster" \
  -sha256 -config .ssl/req.cnf

# Create certificate
openssl x509 -req -in .ssl/csr.pem \
  -CA .ssl/root-ca.pem -CAkey .ssl/root-ca-key.pem \
  -CAcreateserial -sha256 -out .ssl/cert.pem -days 3650 \
  -extensions v3_req -extfile .ssl/req.cnf
```

## Step 5: Install and Configure Keycloak

```sh
# Create namespace
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

# Delete existing TLS secret if it exists (for idempotency)
kubectl delete secret keycloak-tls -n keycloak 2>/dev/null || true

# Create TLS secret with Helm labels for proper ownership
kubectl create secret tls -n keycloak keycloak-tls \
  --cert=.ssl/cert.pem \
  --key=.ssl/key.pem

kubectl label secret keycloak-tls -n keycloak \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate secret keycloak-tls -n keycloak \
  meta.helm.sh/release-name=keycloak \
  meta.helm.sh/release-namespace=keycloak --overwrite

# Install Keycloak
helm upgrade -i keycloak keycloak \
  --repo https://charts.bitnami.com/bitnami \
  --namespace keycloak \
  --wait --timeout 15m \
  -f bootstrap/keycloak-values.yaml
```

Keycloak is now installed with **dual-access architecture**:

### External Access (for kubectl OIDC)
- Exposed via **LoadBalancer** (MetalLB) with HTTPS
- Used by users for OIDC authentication (kubectl)
- Accessible at `https://keycloak.kind.cluster`
- Admin credentials: `admin/admin`

### Internal Access (for MCP Authentication)
- AgentgatewayPolicy accesses Keycloak via **internal ClusterIP service**
- Secure cluster-internal communication
- No external exposure needed for MCP OAuth flows
- Service reference: `keycloak.keycloak.svc.cluster.local:8080`

**Why this architecture?**
1. **Security**: MCP authentication traffic stays within the cluster
2. **Simplicity**: No NGINX proxy needed
3. **Performance**: Direct service-to-service communication for MCP auth

### Configure DNS Resolution

Add Keycloak to your `/etc/hosts` for external OIDC access:

```sh
KEYCLOAK_LB_IP=$(kubectl get svc keycloak -n keycloak \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [[ "$OSTYPE" == "darwin"* ]]; then
  # BSD sed (macOS)
  sudo sed -i '' '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
else
  # GNU sed (Linux)
  sudo sed -i '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
fi

echo "$KEYCLOAK_LB_IP keycloak.kind.cluster" | sudo tee -a /etc/hosts
```

### Setup Keycloak with keycloak.tf

This repo includes a `keycloak.tf` file that uses the [terraform-provider-keycloak](https://registry.terraform.io/providers/mrparkers/keycloak/latest/docs) to automate the creation of Keycloak users, groups, and OIDC clients.

```sh
# Wait for Keycloak to be fully ready (Keycloak uses a StatefulSet, not a Deployment)
kubectl wait --for=condition=ready --timeout=300s pod/keycloak-0 -n keycloak

# Apply Terraform configuration
terraform -chdir=./bootstrap init -upgrade
terraform -chdir=./bootstrap apply -auto-approve
```

This creates users (`alice`, `user-dev`, `user-admin`), groups (`kube-dev`, `kube-admin`), and OAuth clients.

### Configure Keycloak Client Registration

After Terraform, configure Keycloak's client registration trusted hosts for MCP Inspector:

```sh
./bootstrap/configure-keycloak-client-reg.sh
```

## Step 6: Configure K8s RBAC for Users and Groups

Before setting up RBAC, you need to configure Keycloak with users and groups. Access the Keycloak admin console:

Create a namespace in Kubernetes for our dev team and admin team:

```sh
kubectl create namespace dev-team --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace admin-team --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
```


```sh
# DevTeam Role
kubectl apply -f bootstrap/roles/dev-team.yaml
# AdminTeam role (admin CRB)
kubectl apply -f bootstrap/roles/admin-team.yaml

```

Dev-team role creates a namespace-scoped role for developers that allows them to:
- Manage common resources (pods, services, configmaps, deployments)
- View logs and events
- Scale deployments and statefulsets
- Manage ingresses and network policies

Both roles re bound to the `kube-<admin|dev>` group from Keycloak, and developers also have cluster-level discovery permissions to list namespaces and access API endpoints.

## Step 7: Create Kubectl Configurations for Users

```sh
./bootstrap/create-config.sh
```

This script:
1. Obtains OIDC tokens from Keycloak for both `user-admin` and `user-dev`
2. Configures kubectl contexts for each user with their respective credentials
3. Creates kubeconfig entries that automatically refresh tokens using the OIDC provider

After running this, you can switch between users with:
```sh
kubectl config use-context user-admin
# or
kubectl config use-context user-dev
```

**Test the RBAC setup:**
```sh
# Switch to dev user
kubectl config use-context user-dev

# This should work (dev-team namespace)
kubectl get pods -n dev-team

# This should fail (no access to kube-system)
kubectl get pods -n kube-system

# Switch back to admin
kubectl config use-context user-admin
```


## Step 8: Install Kyverno Authorization Server

Kyverno will act as an authorization server that validates MCP requests against Kubernetes RBAC policies and custom business rules.

```sh
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

```sh
# Apply CRDs
kubectl apply \
  -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml

# Delete the webhook configuration if it exists to avoid field manager conflicts
kubectl delete validatingwebhookconfiguration kyverno-authz-server-validation 2>/dev/null || true

# Install authz server
helm upgrade -i kyverno-authz-server kyverno-authz-server \
  --repo https://kyverno.github.io/kyverno-authz \
  --namespace kyverno --create-namespace \
  --wait \
  --values - <<EOF
config:
  type: envoy
authzServer:
  container:
    image:
      repository: lucchmielowski/kyverno-authz
      tag: latest
      pullPolicy: Always
validatingWebhookConfiguration:
  container:
    image:
      repository: lucchmielowski/kyverno-authz
      tag: latest
      pullPolicy: Always
  certificates:
    certManager:
      issuerRef:
        group: cert-manager.io
        kind: ClusterIssuer
        name: selfsigned-issuer
EOF
```

After Kyverno is installed, apply the RBAC needed for SubjectAccessReview checks:

```sh
kubectl apply -f policies/kyverno-sar-rbac.yaml
```

Wait for the Kyverno webhook to be ready, then patch it to use `v1beta1`:

```sh
# Wait for webhook configuration to be created
kubectl wait --for=jsonpath='{.metadata.name}'=kyverno-authz-server-validation \
  validatingwebhookconfiguration/kyverno-authz-server-validation --timeout=120s

# Patch webhook configuration to use v1beta1 instead of v1alpha1
kubectl patch validatingwebhookconfiguration kyverno-authz-server-validation --type='json' -p='[
    {"op": "replace", "path": "/webhooks/0/clientConfig/service/path", "value": "/validate-policies-kyverno-io-v1beta1-validatingpolicy"},
    {"op": "replace", "path": "/webhooks/0/rules/0/apiVersions", "value": ["v1beta1"]}
]'

# Wait for webhook service endpoints to be ready
kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s \
  endpoints/kyverno-authz-server -n kyverno
```

The Kyverno authorization server will:
- Intercept requests sent to the MCP gateway
- Decode JWT tokens to extract user identity and groups
- Perform SubjectAccessReview checks against Kubernetes RBAC
- Enforce custom validation policies (namespace restrictions, label policies, etc.)

## Step 9: Install KGateway and Gateway API

```sh
# Install Gateway API
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml


# Install Agentgateway CRDS
helm upgrade -i agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds --create-namespace --namespace agentgateway-system --version v2.2.0-main --set controller.image.pullPolicy=Always

# Install Agentgateway
helm upgrade -i agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway   --namespace agentgateway-system   --version v2.2.0-main   --set controller.image.pullPolicy=Always   --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true
```

We also need install kubernetes-aware MCP tools:

```sh
helm upgrade -i -n kagent --create-namespace kagent-tools oci://ghcr.io/kagent-dev/tools/helm/kagent-tools --version 0.0.13
```

**What we just installed:**
- **Gateway API CRDs**: Custom Resource Definitions for the Gateway API (HTTPRoute, Gateway, etc.)
- **KGateway CRDs**: Additional CRDs specific to KGateway
- **KGateway**: The main gateway controller with AI/MCP extension support
- **agentgateway**: Enables agent-based interactions with enhanced AI features
- **kagent-tools**: Kubernetes-aware tools that can be called through the MCP protocol

## Step 10: Configure Gateway Resources with MCP Authentication

Now we'll apply the gateway configurations that set up routing, MCP authentication, and authorization policies:

```sh
kubectl apply -f gateway/
```

The `gateway/` directory contains:
- **gateway.yaml**: Main gateway configuration
- **gateway-extension.yaml**: AI/MCP extension configuration
- **http-route.yaml**: Routing rules for MCP requests including OAuth discovery paths
- **mcp-backend.yaml**: Backend service configuration for MCP tools
- **ref-grant.yaml**: Cross-namespace reference permissions
- **gateway-policy.yaml**: AgentgatewayPolicy with MCP authentication and Kyverno authorization

### Understanding the AgentgatewayPolicy

The `gateway-policy.yaml` file contains two key authentication/authorization configurations:

#### 1. MCP Authentication (`backend.mcp.authentication`)

This section configures OAuth 2.0 authentication for MCP clients:

```yaml
backend:
  mcp:
    authentication:
      # Issuer URL - must match the 'iss' claim in JWT tokens
      issuer: "https://keycloak.kind.cluster/realms/master"

      # JWKS configuration for token validation
      jwks:
        backendRef:
          name: keycloak
          kind: Service
          namespace: keycloak
          port: 8080
        jwksPath: "/realms/master/protocol/openid-connect/certs"

      # Expected audience in JWT tokens
      audiences:
        - "http://localhost:8080/mcp"

      # Strict validation mode
      mode: Strict

      # Identity provider type
      provider: Keycloak

      # MCP resource metadata for OAuth discovery
      resourceMetadata:
        resource: "http://localhost:8080/mcp"
        scopesSupported:
          - email
        bearerMethodsSupported:
          - header
          - body
          - query
```

**What this does:**
- Enables MCP clients to discover OAuth endpoints automatically
- Allows dynamic client registration with Keycloak
- Validates JWT tokens using public keys from Keycloak's JWKS endpoint
- Requires strict validation of issuer, audience, and claims
- Supports multiple methods for providing bearer tokens

#### 2. External Authorization with Kyverno (`traffic.extAuth`)

This section integrates Kyverno for fine-grained authorization:

```yaml
traffic:
  extAuth:
    backendRef:
      name: kyverno-authz-server
      namespace: kyverno
      port: 9081
    grpc: {}
    forwardBody:
      maxSize: 1024
```

**What this does:**
- Forwards requests to Kyverno authorization server via gRPC
- Validates requests against Kubernetes RBAC policies
- Enforces custom business rules (namespace restrictions, etc.)
- Passes request body to Kyverno for context-aware decisions

### HTTP Route Configuration

The HTTPRoute must include paths for OAuth discovery:

```yaml
matches:
  # Main MCP endpoint
  - path:
      type: PathPrefix
      value: /mcp

  # OAuth resource metadata discovery
  - path:
      type: PathPrefix
      value: /.well-known/oauth-protected-resource/mcp

  # OAuth authorization server metadata discovery
  - path:
      type: PathPrefix
      value: /.well-known/oauth-authorization-server/mcp

  # JWKS endpoint for token validation
  - path:
      type: PathPrefix
      value: /realms/master/protocol/openid-connect/certs
```

This creates the complete authentication and authorization pipeline:
```
MCP Client → OAuth Discovery → Client Registration (Keycloak) →
User Auth Flow → JWT Token → Gateway (MCP Auth) →
Kyverno Authorization → MCP Backend → Kubernetes API
```

## Step 11: Configure Gateway DNS (Optional)

Add the gateway hostname to your `/etc/hosts` file for easier access:

```sh
GATEWAY_LB_IP=$(kubectl get gateway -n agentgateway-system \
  -o jsonpath='{.items[0].status.addresses[0].value}')

if [[ "$OSTYPE" == "darwin"* ]]; then
  # BSD sed (macOS)
  sudo sed -i '' '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
else
  # GNU sed (Linux)
  sudo sed -i '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
fi

echo "$GATEWAY_LB_IP gateway.kind.cluster" | sudo tee -a /etc/hosts
```

Now you can access the gateway at `http://gateway.kind.cluster:8080/mcp` instead of using the IP address.

**Note:** This is optional. You can also use the LoadBalancer IP directly.

## Step 12: Apply Kyverno Authorization Policies

Apply the Kyverno policies that enforce authentication and authorization on MCP requests:

```sh
kubectl apply -f policies/no-unauthenticated-calls.yaml
kubectl apply -f policies/create-from-url-authz.yaml
```

Verify the policies are applied:

```sh
kubectl get validatingpolicy
```

These policies:
- **no-unauthenticated-calls**: Rejects any MCP request that does not include a valid JWT token
- **create-from-url-authz**: Performs SubjectAccessReview checks to enforce Kubernetes RBAC on MCP tool calls

## Step 13: Testing MCP Authentication and Authorization

The AgentgatewayPolicy enables full MCP OAuth authentication. You can test this using the MCP Inspector, which automatically discovers OAuth endpoints and guides you through the authentication flow.

### Test with MCP Inspector (Recommended)

The MCP Inspector provides a user-friendly interface for testing the complete MCP OAuth flow:

```sh
# Launch MCP Inspector
npx @modelcontextprotocol/inspector@0.18.0
```

#### Connect to the Gateway with MCP Auth:

1. **Get the Gateway Address:**
   ```sh
   GATEWAY_URL="$(kubectl get gateway -n agentgateway-system -o jsonpath='{.items[0].status.addresses[0].value}'):8080"
   echo "Gateway URL: http://$GATEWAY_URL/mcp"
   ```

2. **In MCP Inspector:**
   - Transport Type: Select **Streamable HTTP**
   - URL: Enter `http://$GATEWAY_URL/mcp`
   - Click **Connect**

3. **Verify Authentication Required:**
   - The connection should fail initially because authentication is required
   - This confirms the AgentgatewayPolicy is enforcing authentication

4. **Run Through the OAuth Flow:**
   - Click **Open Auth Settings** to start the MCP Auth flow
   - You can choose **Quick OAuth Flow** for automatic progression or manually step through each phase

#### Manual OAuth Flow Steps:

**Phase 1: Metadata Discovery**
- Click **Continue** to start metadata discovery
- The MCP Inspector queries `/.well-known/oauth-protected-resource/mcp` and `/.well-known/oauth-authorization-server/mcp`
- Verify you see authorization server metadata including:
  - Authorization endpoint
  - Token endpoint
  - Supported scopes (email)
  - Bearer token methods (header, body, query)

**Phase 2: Client Registration**
- Click **Continue** to register as a client
- The AgentgatewayPolicy facilitates registration with Keycloak
- A dynamic client ID is assigned to the MCP Inspector
- Verify you receive a client ID

**Phase 3: Authorization**
- Click **Continue** to prepare authorization
- You'll receive a Keycloak login URL
- Open the URL in your browser
- Log in with one of these users:
  - **Dev User**: username `user-dev`, password `password`
  - **Admin User**: username `user-admin`, password `password`

**Phase 4: Authorization Code Exchange**
- After login, copy the authorization code displayed
- Paste the code into the MCP Inspector's "Authorization Code" field
- Click **Continue**

**Phase 5: Token Request**
- Click **Continue** to exchange the authorization code for a JWT token
- Verify the "Authentication Complete" phase succeeds
- You should receive an `access_token` from Keycloak

**Phase 6: Connect with Token**
- Copy the `access_token` value
- Open the **Authentication** section in MCP Inspector
- In the **Custom Headers** card, click **Add**
- Add header:
  - Name: `Authorization`
  - Value: `Bearer <paste_access_token_here>`
- Click **Connect**

5. **Test MCP Tool Calls:**

Once authenticated, test different scenarios:

**As Dev User (should succeed):**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "k8s_get_resources",
    "arguments": {
      "namespace": "dev-team",
      "resource_type": "pods"
    }
  }
}
```

**As Dev User (should fail - no access to kube-system):**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "k8s_get_resources",
    "arguments": {
      "namespace": "kube-system",
      "resource_type": "pods"
    }
  }
}
```

This validates that:
- ✅ MCP authentication is working (AgentgatewayPolicy)
- ✅ JWT tokens are validated correctly
- ✅ Kyverno authorization enforces RBAC policies
- ✅ Developers can only access their authorized namespaces

### Test with curl (Alternative Method)

If you prefer command-line testing, you can obtain a token manually:

### Verify AgentgatewayPolicy Configuration

Before testing, verify the policy is correctly applied:

```sh
# Check the policy status
kubectl get agentgatewaypolicy -n agentgateway-system

# View the policy details
kubectl describe agentgatewaypolicy ext-authz -n agentgateway-system

# Test OAuth discovery endpoints
GATEWAY_URL="$(kubectl get gateway -n agentgateway-system -o jsonpath='{.items[0].status.addresses[0].value}'):8080"

# Test resource metadata discovery
curl http://$GATEWAY_URL/.well-known/oauth-protected-resource/mcp | jq

# Test authorization server metadata discovery
curl http://$GATEWAY_URL/.well-known/oauth-authorization-server/mcp | jq
```

You should see JSON responses containing OAuth configuration details.

### Test with curl (Advanced)

For advanced testing or automation, you can use curl:

```sh
# Get the gateway endpoint
GATEWAY_URL="$(kubectl get gateway -n agentgateway-system -o jsonpath='{.items[0].status.addresses[0].value}'):8080"

# Get a session ID
SESSION_ID=$(curl -sS --http1.1 -i http://$GATEWAY_URL/mcp \
  -H "Authorization: Bearer $DEV_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
  | grep -i "^Mcp-Session-Id:" | cut -d' ' -f2 | tr -d '\r')


# Try calling a tool (e.g., list pods in dev-team namespace)
curl -k http://$GATEWAY_URL/mcp \
  -H "Authorization: Bearer $DEV_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream, application/json" \
  -H "Mcp-Session-Id: $SESSION_ID" \
  -H "MCP-Protocol-Version: 2025-06-18" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "k8s_get_resources",
      "arguments": {
        "all_namespaces": "false",
        "namespace": "kube-system",
        "output": "json",
        "resource_name": "",
        "resource_type": "pods"
      },
      "_meta": {
        "progressToken": 0
      }
    }
  }'
```

Note that since we're using the dev token, accessing `kube-system` namespace **shouldn't work**. This is what we're going to enforce in the next part.

### Common Issues

**1. MCP OAuth Discovery Failing**
- Verify AgentgatewayPolicy is applied: `kubectl get agentgatewaypolicy -n agentgateway-system`
- Check HTTPRoute includes discovery paths:
  ```sh
  kubectl get httproute mcp -n agentgateway-system -o yaml | grep "well-known"
  ```
- Test discovery endpoints manually:
  ```sh
  curl http://$GATEWAY_URL/.well-known/oauth-protected-resource/mcp
  curl http://$GATEWAY_URL/.well-known/oauth-authorization-server/mcp
  ```

**2. Client Registration Failing**
- Verify Keycloak is accessible from the gateway
- Check Keycloak service reference in AgentgatewayPolicy:
  ```sh
  kubectl get svc -n keycloak keycloak
  ```
- Review gateway logs for connection errors:
  ```sh
  kubectl logs -n agentgateway-system -l app=agentgateway
  ```

**3. JWT Token Validation Failing**
- Verify JWKS endpoint is accessible:
  ```sh
  curl http://$GATEWAY_URL/realms/master/protocol/openid-connect/certs
  ```
- Check issuer URL matches in AgentgatewayPolicy and Keycloak
- Decode JWT token to verify claims (use jwt.io):
  - `iss` should match `issuer` in policy
  - `aud` should match `audiences` in policy
  - Token should contain `email` and `groups` claims

**4. Keycloak not accessible**
- Verify ingress is running: `kubectl get ingress -n keycloak`
- Check `/etc/hosts` has the correct entry
- Verify SSL certificate: `kubectl get secret -n keycloak keycloak.kind.cluster-tls`

**5. Token validation failing (Kubernetes API Server)**
- Ensure the root CA is mounted in the API server
- Check API server logs: `kubectl logs -n kube-system kube-apiserver-kind-control-plane`
- Verify OIDC configuration: `kubectl cluster-info dump | grep oidc`

**6. Kyverno policy denials**
- Check policy is applied: `kubectl get validatingpolicy -A`
- Review Kyverno logs for denial reasons:
  ```sh
  kubectl logs -n kyverno -l app=kyverno-authz-server
  ```
- Verify JWT token contains expected claims (email, groups)
- Test external auth connection:
  ```sh
  kubectl describe agentgatewaypolicy ext-authz -n agentgateway-system
  ```

**7. RBAC permission errors**
- Test permissions directly with kubectl: `kubectl auth can-i list pods -n dev-team --as=user-dev@domain.com`
- Review role bindings: `kubectl get rolebinding -n dev-team`
- Check cluster role bindings: `kubectl get clusterrolebinding | grep kube-dev`
- Verify group membership in JWT token matches RBAC group names

### Cleanup

To tear down the demo environment:

```sh
# Delete the Kind cluster
kind delete cluster

# Remove /etc/hosts entries
if [[ "$OSTYPE" == "darwin"* ]]; then
  sudo sed -i '' '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
  sudo sed -i '' '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
else
  sudo sed -i '/keycloak\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
  sudo sed -i '/gateway\.kind\.cluster/d' /etc/hosts 2>/dev/null || true
fi

# Optional: Clean up SSL certificates
rm -rf .ssl/
```