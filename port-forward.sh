#!/usr/bin/env bash
#
# Re-enable host access when /etc/hosts contains:
#   127.0.0.1 gateway.kind.cluster
#   127.0.0.1 keycloak.kind.cluster
#
# Both names use local port 8080. Traffic goes through one port-forward to
# agentgateway-proxy; HTTPRoutes route by path (e.g. /mcp vs /realms/master), so
# a single forward is enough for typical demo use (see gateway/http-route.yaml).
#
# Usage:
#   ./port-forward.sh              # background, logs to /tmp/agentgateway-port-forward.log
#   ./port-forward.sh --foreground # stay in foreground (Ctrl+C to stop)
#   ./port-forward.sh --stop       # stop background port-forward (best-effort)

set -euo pipefail

SVC="svc/agentgateway-proxy"
NS="agentgateway-system"
LOCAL_PORT="${LOCAL_PORT:-8080}"
REMOTE_PORT="${REMOTE_PORT:-8080}"
LOG="${LOG:-/tmp/agentgateway-port-forward.log}"
PID_FILE="${PID_FILE:-/tmp/agentgateway-port-forward.pid}"

stop_forward() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "Stopping port-forward (PID $pid)..."
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  fi
  # Best-effort: free local port if something else is listening (e.g. stale kubectl)
  if command -v lsof >/dev/null 2>&1; then
    local pids
    pids=$(lsof -tiTCP:"$LOCAL_PORT" -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "${pids:-}" ]]; then
      echo "Warning: port $LOCAL_PORT still in use (PIDs: $pids). Stop those processes if needed."
    fi
  fi
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_forward
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH" >&2
  exit 1
fi

stop_forward

CMD=(kubectl port-forward "$SVC" -n "$NS" "${LOCAL_PORT}:${REMOTE_PORT}")

if [[ "${1:-}" == "--foreground" ]]; then
  echo "Port-forward: ${CMD[*]}"
  echo "Gateway MCP:  http://gateway.kind.cluster:${LOCAL_PORT}/mcp"
  echo "Keycloak (via same listener): http://keycloak.kind.cluster:${LOCAL_PORT}/realms/master/..."
  exec "${CMD[@]}"
fi

echo "Starting port-forward in background → $LOG"
nohup "${CMD[@]}" >"$LOG" 2>&1 &
echo $! >"$PID_FILE"
sleep 1

if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "OK (PID $(cat "$PID_FILE"))"
  echo "  http://gateway.kind.cluster:${LOCAL_PORT}/mcp"
  echo "  http://keycloak.kind.cluster:${LOCAL_PORT}/realms/master/..."
  echo "Log: $LOG"
  echo "Stop: $0 --stop"
else
  echo "Port-forward failed. See $LOG" >&2
  rm -f "$PID_FILE"
  exit 1
fi
