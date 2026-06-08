#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values for skip flags
SKIP_CLUSTER=${SKIP_CLUSTER:-false}
SKIP_CERT_MANAGER=${SKIP_CERT_MANAGER:-false}
SKIP_KEYCLOAK=${SKIP_KEYCLOAK:-false}
SKIP_RBAC=${SKIP_RBAC:-false}
SKIP_KYVERNO=${SKIP_KYVERNO:-false}
SKIP_GATEWAY=${SKIP_GATEWAY:-false}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-cluster)
            SKIP_CLUSTER=true
            shift
            ;;
        --skip-cert-manager)
            SKIP_CERT_MANAGER=true
            shift
            ;;
        --skip-keycloak)
            SKIP_KEYCLOAK=true
            shift
            ;;
        --skip-rbac)
            SKIP_RBAC=true
            shift
            ;;
        --skip-kyverno)
            SKIP_KYVERNO=true
            shift
            ;;
        --skip-gateway)
            SKIP_GATEWAY=true
            shift
            ;;
        --skip-all)
            SKIP_CLUSTER=true
            SKIP_CERT_MANAGER=true
            SKIP_KEYCLOAK=true
            SKIP_RBAC=true
            SKIP_KYVERNO=true
            SKIP_GATEWAY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-cluster       Skip Kind cluster creation"
            echo "  --skip-cert-manager  Skip cert-manager installation"
            echo "  --skip-keycloak      Skip Keycloak installation"
            echo "  --skip-rbac          Skip RBAC configuration"
            echo "  --skip-kyverno       Skip Kyverno installation"
            echo "  --skip-gateway       Skip Gateway API and agentgateway installation"
            echo "  --skip-all           Skip all infrastructure setup (only apply gateway configs and policies)"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to print colored messages
print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

print_success() {
    echo -e "${GREEN}✓ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_error() {
    echo -e "${RED}✗ ${1}${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ${1}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Function to wait for deployment to be ready
wait_for_deployment() {
    local namespace=$1
    local deployment=$2
    local timeout=${3:-300}

    print_info "Waiting for deployment $deployment in namespace $namespace to be ready..."
    kubectl wait --for=condition=available --timeout=${timeout}s deployment/$deployment -n $namespace 2>/dev/null || {
        print_warning "Timeout waiting for $deployment, but continuing..."
    }
}

# Function to wait for pods to be ready
wait_for_pods() {
    local namespace=$1
    local label=$2
    local timeout=${3:-300}

    print_info "Waiting for pods with label $label in namespace $namespace..."
    kubectl wait --for=condition=ready --timeout=${timeout}s pods -l $label -n $namespace 2>/dev/null || {
        print_warning "Timeout waiting for pods, but continuing..."
    }
}

# Function to wait for Kyverno webhook to be ready
wait_for_kyverno_webhook() {
    print_info "Checking if Kyverno webhook is ready..."

    # Check if Kyverno is installed
    if ! kubectl get namespace kyverno >/dev/null 2>&1; then
        print_error "Kyverno namespace not found. Please install Kyverno first."
        return 1
    fi

    # Wait for webhook configuration to exist
    print_info "Waiting for Kyverno webhook configuration to be created..."
    max_attempts=60
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get validatingwebhookconfiguration kyverno-authz-server-validation >/dev/null 2>&1; then
            print_success "Webhook configuration found"
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo -n "."
            sleep 2
        else
            print_error "Webhook configuration was not created in time"
            return 1
        fi
    done

    # Patch webhook configuration to use v1beta1 instead of v1alpha1
    print_info "Updating webhook configuration to use v1beta1 API..."
    kubectl patch validatingwebhookconfiguration kyverno-authz-server-validation --type='json' -p='[
        {"op": "replace", "path": "/webhooks/0/clientConfig/service/path", "value": "/validate-policies-kyverno-io-v1beta1-validatingpolicy"},
        {"op": "replace", "path": "/webhooks/0/rules/0/apiVersions", "value": ["v1beta1"]}
    ]' >/dev/null 2>&1

    # Wait for webhook service endpoints to be ready
    print_info "Waiting for Kyverno webhook service endpoints to be ready..."
    kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s endpoints/kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for webhook service endpoints"
    }

    # Wait for webhook pods to be ready
    print_info "Waiting for Kyverno webhook pods to be ready..."
    kubectl wait --for=condition=ready --timeout=120s pods -l app.kubernetes.io/instance=kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for webhook pods"
    }

    # Test if webhook is actually responding to validation requests
    print_info "Testing webhook readiness..."
    max_attempts=30
    attempt=0
    webhook_ready=false

    # Create a temporary test file
    cat > /tmp/webhook-test.yaml <<'EOF'
apiVersion: policies.kyverno.io/v1beta1
kind: ValidatingPolicy
metadata:
  name: webhook-readiness-test
spec:
  evaluation:
    mode: Envoy
  validations:
    - expression: "envoy.Allowed().Response()"
EOF

    while [ $attempt -lt $max_attempts ]; do
        # Try to create a test ValidatingPolicy with dry-run to test webhook
        if kubectl apply --dry-run=server -f /tmp/webhook-test.yaml >/dev/null 2>&1; then
            webhook_ready=true
            print_success "Webhook is responding to validation requests"
            rm -f /tmp/webhook-test.yaml
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo -n "."
            sleep 2
        fi
    done

    rm -f /tmp/webhook-test.yaml

    if [ "$webhook_ready" = false ]; then
        print_error "Webhook is not responding to validation requests"
        print_info "Check webhook status with: kubectl get pods -n kyverno"
        print_info "Check webhook logs with: kubectl logs -n kyverno -l app.kubernetes.io/instance=kyverno-authz-server"
        return 1
    fi

    return 0
}

# Check prerequisites
print_header "Step 0: Checking Prerequisites"

for cmd in kind kubectl helm curl jq; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd is not installed. Please install it first."
        exit 1
    fi
    print_success "$cmd is installed"
done

# Step 1: Create Kind Cluster
if [ "$SKIP_CLUSTER" = false ]; then
    print_header "Step 1: Create Kind Cluster"

    if kind get clusters | grep -q "^kyverno-authz$"; then
        print_warning "Kind cluster 'kyverno-authz' already exists."
        read -p "Do you want to delete and recreate it? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deleting existing cluster..."
            kind delete cluster --name kyverno-authz
            print_info "Creating Kind cluster..."
            kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
            print_success "Kind cluster created"
        else
            print_warning "Keeping existing cluster."
            print_info "Expected config: bootstrap/kind-config.yaml"
        fi
    else
        print_info "Creating Kind cluster..."
        kind create cluster --image kindest/node:v1.33.1 --config bootstrap/kind-config.yaml
        print_success "Kind cluster created"
    fi
else
    print_warning "Skipping Kind cluster creation"
fi

# Step 2: Install cert-manager (for Kyverno)
if [ "$SKIP_CERT_MANAGER" = false ]; then
    print_header "Step 2: Install cert-manager"

    print_info "Installing/upgrading cert-manager..."
    helm upgrade -i cert-manager oci://quay.io/jetstack/charts/cert-manager \
      --version v1.19.2 \
      --namespace cert-manager \
      --create-namespace \
      --set crds.enabled=true \
      --wait

    print_success "cert-manager is ready"
else
    print_warning "Skipping cert-manager installation"
fi

# Step 3: Install Keycloak
if [ "$SKIP_KEYCLOAK" = false ]; then
    print_header "Step 3: Install Keycloak"

    print_info "Creating namespace..."
    kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

    print_info "Installing/upgrading Keycloak (this may take a few minutes)..."
    helm upgrade -i keycloak keycloakx \
      --repo https://codecentric.github.io/helm-charts \
      --namespace keycloak \
      --wait --timeout 15m \
      -f bootstrap/keycloak-values.yaml

    print_success "Keycloak installed"
    print_info "External access: http://keycloak.localhost:18080 (via NodePort + extraPortMappings)"
    print_info "Internal access: keycloak-http.keycloak.svc.cluster.local:8080 (for Kyverno JWKS)"

    # Wait for pod to be ready (NodePort is accessible once pod is ready)
    print_info "Waiting for Keycloak pod to be ready..."
    kubectl wait --for=condition=ready --timeout=300s pod/keycloak-0 -n keycloak 2>/dev/null || {
        print_warning "Timeout waiting for Keycloak pod"
    }

    # Wait for Keycloak API to respond via NodePort
    print_info "Waiting for Keycloak API to respond at http://keycloak.localhost:18080..."
    max_attempts=60
    attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "http://keycloak.localhost:18080/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
            print_success "Keycloak API is ready at http://keycloak.localhost:18080"
            break
        fi
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            print_error "Keycloak API did not become ready in time"
            print_warning "Check: curl http://keycloak.localhost:18080/realms/master/.well-known/openid-configuration"
            exit 1
        fi
        echo -n "."
        sleep 2
    done

    # Run setup script
    print_info "Configuring Keycloak users, groups, and clients..."
    chmod +x ./bootstrap/setup-keycloak.sh
    KEYCLOAK_URL="http://keycloak.localhost:18080" bash ./bootstrap/setup-keycloak.sh || {
        print_error "Failed to configure Keycloak"
        print_warning "Re-run manually: KEYCLOAK_URL=http://keycloak.localhost:18080 ./bootstrap/setup-keycloak.sh"
        exit 1
    }
    print_success "Keycloak configured"

else
    print_warning "Skipping Keycloak installation"
fi

# Step 4: Configure Kubernetes RBAC
if [ "$SKIP_RBAC" = false ]; then
    print_header "Step 4: Configure Kubernetes RBAC for Users and Groups"

    print_info "Creating namespaces..."
    kubectl create namespace dev-team --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace admin-team --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -

    print_info "Applying RBAC roles..."
    kubectl apply -f bootstrap/roles/dev-team.yaml
    kubectl apply -f bootstrap/roles/admin-team.yaml

    print_success "RBAC configured"
    print_info "To create kubectl OIDC contexts (optional, requires adding OIDC to kind-config.yaml):"
    print_info "  ./bootstrap/create-config.sh"
else
    print_warning "Skipping RBAC configuration"
fi

# Step 5: Install Kyverno Authorization Server
if [ "$SKIP_KYVERNO" = false ]; then
    print_header "Step 5: Install Kyverno Authorization Server"

    print_info "Creating ClusterIssuer..."
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

    print_info "Applying Kyverno CRDs..."
    kubectl apply \
      -f https://raw.githubusercontent.com/kyverno/kyverno/refs/heads/main/config/crds/policies.kyverno.io/policies.kyverno.io_validatingpolicies.yaml

    # Delete the webhook configuration if it exists to avoid field manager conflicts
    kubectl delete validatingwebhookconfiguration kyverno-authz-server-validation 2>/dev/null || true

    print_info "Installing/upgrading Kyverno authorization server (this may take a few minutes)..."
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
      registry: ghcr.io
      repository: lucchmielowski/kyverno-authz
      tag: latest
      pullPolicy: Always
validatingWebhookConfiguration:
  container:
    image:
      registry: ghcr.io
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

    print_info "Applying Kyverno RBAC for SubjectAccessReview..."
    kubectl apply -f policies/kyverno-sar-rbac.yaml

    # Wait for Kyverno deployment to be ready
    print_info "Waiting for Kyverno authorization server to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/kyverno-authz-server -n kyverno 2>/dev/null || {
        print_warning "Timeout waiting for Kyverno deployment"
    }

    # Wait for webhook to be ready
    wait_for_kyverno_webhook || {
        print_warning "Webhook may not be fully ready, but continuing..."
        print_info "If policy application fails, wait a moment and try: kubectl apply -f policies/"
    }

    print_success "Kyverno authorization server installed"
else
    print_warning "Skipping Kyverno installation"
fi

# Step 6: Install Gateway API and agentgateway
if [ "$SKIP_GATEWAY" = false ]; then
    print_header "Step 6: Install Gateway API and agentgateway"

    print_info "Installing Gateway API CRDs..."
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

    print_info "Installing agentgateway CRDs..."
    helm upgrade -i agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds \
      --create-namespace --namespace agentgateway-system \
      --version v2.2.0-main \
      --set controller.image.pullPolicy=Always

    print_info "Installing agentgateway..."
    helm upgrade -i agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway \
      --namespace agentgateway-system \
      --version v2.2.0-main \
      --set controller.image.pullPolicy=Always \
      --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true

    print_info "Waiting for agentgateway components to be ready..."
    wait_for_deployment agentgateway-system agentgateway 300
    wait_for_deployment agentgateway-system agentgateway-proxy 300
    kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s endpoints/agentgateway-proxy -n agentgateway-system 2>/dev/null || {
        print_warning "Timeout waiting for agentgateway proxy endpoints, but continuing..."
    }

    print_success "Gateway API and agentgateway installed"

    print_info "Installing kagent-tools (Kubernetes-aware MCP tools)..."
    helm upgrade -i -n kagent --create-namespace kagent-tools \
      oci://ghcr.io/kagent-dev/tools/helm/kagent-tools \
      --version 0.0.13

    print_success "kagent-tools installed"
else
    print_warning "Skipping Gateway API and agentgateway installation"
fi

# Step 7: Configure Gateway Resources
print_header "Step 7: Configure Gateway Resources with MCP Authentication"

if [ -d ./gateway ]; then
    print_info "Applying gateway configurations..."
    kubectl apply -f gateway/
    print_success "Gateway resources applied"
else
    print_warning "gateway/ directory not found, skipping gateway configuration"
fi

# Step 8: Apply Kyverno Policies
print_header "Step 8: Apply Kyverno Authorization Policies"

if [ -d ./policies ]; then
    # Ensure webhook is ready before applying policies
    if ! wait_for_kyverno_webhook; then
        print_error "Kyverno webhook is not ready. Cannot apply policies."
        print_warning "You can manually apply policies later with:"
        print_warning "  kubectl apply -f policies/"
    else
        print_info "Applying Kyverno policies..."
        kubectl apply -f policies/no-unauthenticated-calls.yaml
        kubectl apply -f policies/restricted-group-deny-tools.yaml
        kubectl apply -f policies/dev-group-tool-guardrails.yaml
        kubectl apply -f policies/create-from-url-authz.yaml
        print_success "Kyverno policies applied"

        print_info "Verifying policies..."
        kubectl get validatingpolicy
    fi
else
    print_warning "policies/ directory not found, skipping policy application"
fi

# Start agentgateway port-forward so gateway.localhost:8080 works
if [ -d ./gateway ]; then
    print_info "Starting port-forward to agentgateway (gateway.localhost:8080)..."
    wait_for_deployment agentgateway-system agentgateway-proxy 300
    kubectl wait --for=jsonpath='{.subsets[*].addresses[*].ip}' --timeout=120s \
        endpoints/agentgateway-proxy -n agentgateway-system 2>/dev/null || {
        print_warning "Timeout waiting for agentgateway proxy endpoints, but continuing..."
    }
    nohup kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080 \
        >/tmp/agentgateway-port-forward.log 2>&1 &
    GATEWAY_PF_PID=$!
    sleep 2
    if kill -0 $GATEWAY_PF_PID 2>/dev/null; then
        print_success "Gateway port-forward started (PID ${GATEWAY_PF_PID})"
        print_info "Gateway log: /tmp/agentgateway-port-forward.log"
    else
        print_warning "Failed to start gateway port-forward."
        print_warning "Retry manually: kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080"
    fi
fi

# Final summary
print_header "Installation Complete!"

echo ""
print_success "All components installed. No /etc/hosts edits required."
echo ""
print_info "Endpoints (macOS RFC 6761 — *.localhost resolves to 127.0.0.1 natively):"
echo "  Keycloak:   http://keycloak.localhost:18080  (NodePort via extraPortMappings)"
echo "  MCP Gateway: http://gateway.localhost:8080/mcp  (kubectl port-forward)"
echo ""
print_info "Quick test:"
echo ""
echo "  # Get token for alice"
echo "  TOKEN=\$(curl -s -X POST http://keycloak.localhost:18080/realms/master/protocol/openid-connect/token \\"
echo "    -d grant_type=password -d client_id=kube -d client_secret=kube-client-secret \\"
echo "    -d username=alice -d password=alice -d scope=openid | jq -r .access_token)"
echo ""
echo "  # Unauthenticated → 401"
echo "  curl -o /dev/null -w \"%{http_code}\" http://gateway.localhost:8080/mcp"
echo ""
echo "  # Authenticated alice (kube-dev) → 200"
echo "  curl -o /dev/null -w \"%{http_code}\" -X POST \\"
echo "    -H \"Authorization: Bearer \$TOKEN\" \\"
echo "    -H \"Content-Type: application/json\" -H \"Accept: application/json, text/event-stream\" \\"
echo "    -H \"MCP-Protocol-Version: 2024-11-05\" \\"
echo "    -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}' \\"
echo "    http://gateway.localhost:8080/mcp"
echo ""
print_info "Keycloak Users:"
echo "  alice / alice           (kube-dev group)"
echo "  user-dev / user-dev     (kube-dev group)"
echo "  user-admin / user-admin (kube-admin group)"
echo ""
print_info "To restart gateway port-forward after a restart:"
echo "  nohup kubectl port-forward svc/agentgateway-proxy -n agentgateway-system 8080:8080 &"
echo ""
print_info "To re-run Keycloak setup (if pod restarted and lost data):"
echo "  KEYCLOAK_URL=http://keycloak.localhost:18080 ./bootstrap/setup-keycloak.sh"
echo ""
