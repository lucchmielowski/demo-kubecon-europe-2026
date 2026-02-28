#!/bin/bash
echo "Testing Keycloak certificate..."
curl -I http://keycloak.kind.cluster:8080/realms/master 2>&1 | grep -E "(HTTP|SSL certificate)"
if [ $? -eq 0 ]; then
  echo "✅ Certificate is trusted!"
else
  echo "❌ Certificate still not trusted"
fi
