#!/bin/bash
# OpenClaw Cloud Foundry Startup Script
# Handles two modes:
#   1. Direct: OpenClaw listens on $PORT (default)
#   2. SSO:    oauth2-proxy on $PORT → OpenClaw on localhost:8081
set -e

OPENCLAW_PORT="${PORT:-8080}"
OPENCLAW_INTERNAL_PORT=8081
OAUTH2_PROXY_VERSION="7.8.1"
DATA_DIR="${OPENCLAW_STATE_DIR:-/home/vcap/app/data}"

mkdir -p "$DATA_DIR"

# ============================================================
# SSO Mode: oauth2-proxy in front of OpenClaw
# ============================================================
if [ "${OPENCLAW_SSO_ENABLED}" = "true" ] && [ -f "${HOME}/sso.env" ]; then
    echo "=== SSO Mode Enabled ==="

    # Load SSO credentials written by .profile
    source "${HOME}/sso.env"

    if [ -z "$SSO_CLIENT_ID" ] || [ -z "$SSO_CLIENT_SECRET" ] || [ -z "$SSO_AUTH_DOMAIN" ]; then
        echo "WARNING: SSO credentials incomplete. Falling back to direct mode."
        echo "  Ensure p-identity service is bound: cf bind-service openclaw openclaw-sso"
        exec node dist/index.js gateway --allow-unconfigured --port "$OPENCLAW_PORT" --bind lan
    fi

    # Download oauth2-proxy if not cached
    PROXY_BIN="${DATA_DIR}/oauth2-proxy"
    if [ ! -x "$PROXY_BIN" ]; then
        echo "Downloading oauth2-proxy v${OAUTH2_PROXY_VERSION}..."
        PROXY_URL="https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${OAUTH2_PROXY_VERSION}/oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-amd64.tar.gz"
        curl -sfL "$PROXY_URL" | tar xz -C "$DATA_DIR" --strip-components=1 "oauth2-proxy-v${OAUTH2_PROXY_VERSION}.linux-amd64/oauth2-proxy"
        chmod +x "$PROXY_BIN"
        echo "oauth2-proxy downloaded and cached at ${PROXY_BIN}"
    else
        echo "Using cached oauth2-proxy at ${PROXY_BIN}"
    fi

    # Generate cookie secret if not provided
    COOKIE_SECRET="${OPENCLAW_COOKIE_SECRET:-$(openssl rand -base64 32)}"

    # Determine the OIDC issuer URL
    # CF UAA has a split architecture: login.sys.* serves the OIDC discovery
    # endpoint but reports uaa.sys.* as the issuer. oauth2-proxy strict issuer
    # checking will fail, so we use --insecure-oidc-skip-issuer-verification.
    # Use auth_domain as the discovery base URL.
    OIDC_ISSUER="${SSO_AUTH_DOMAIN}"
    if [[ "$OIDC_ISSUER" == */oauth/token ]]; then
        OIDC_ISSUER="${OIDC_ISSUER%/oauth/token}"
    fi

    # Determine the redirect URL based on the app route
    VCAP_APP=$(echo "$VCAP_APPLICATION" | python3 -c "import sys,json; app=json.load(sys.stdin); print(app.get('application_uris',['localhost'])[0])" 2>/dev/null || echo "localhost")
    REDIRECT_URL="https://${VCAP_APP}/oauth2/callback"

    echo "Starting OpenClaw on internal port ${OPENCLAW_INTERNAL_PORT}..."
    node dist/index.js gateway --allow-unconfigured --port "$OPENCLAW_INTERNAL_PORT" --bind lan &
    OPENCLAW_PID=$!

    # Give OpenClaw a moment to start
    sleep 2

    echo "Starting oauth2-proxy on port ${OPENCLAW_PORT}..."
    echo "  OIDC Issuer: ${OIDC_ISSUER}"
    echo "  Redirect URL: ${REDIRECT_URL}"
    echo "  Upstream: http://localhost:${OPENCLAW_INTERNAL_PORT}"

    "$PROXY_BIN" \
        --provider=oidc \
        --oidc-issuer-url="${OIDC_ISSUER}" \
        --insecure-oidc-skip-issuer-verification=true \
        --client-id="${SSO_CLIENT_ID}" \
        --client-secret="${SSO_CLIENT_SECRET}" \
        --redirect-url="${REDIRECT_URL}" \
        --upstream="http://localhost:${OPENCLAW_INTERNAL_PORT}" \
        --http-address="0.0.0.0:${OPENCLAW_PORT}" \
        --cookie-secret="${COOKIE_SECRET}" \
        --cookie-secure=true \
        --email-domain="*" \
        --pass-access-token=true \
        --pass-authorization-header=true \
        --skip-provider-button=true \
        --reverse-proxy=true &
    PROXY_PID=$!

    echo "=== SSO proxy started (PID: ${PROXY_PID}), OpenClaw (PID: ${OPENCLAW_PID}) ==="

    # Wait for either process to exit
    wait -n "$OPENCLAW_PID" "$PROXY_PID" 2>/dev/null || true
    EXIT_CODE=$?

    echo "A process exited with code ${EXIT_CODE}. Shutting down..."
    kill "$OPENCLAW_PID" "$PROXY_PID" 2>/dev/null || true
    exit "$EXIT_CODE"

else
    # ============================================================
    # Direct Mode: OpenClaw serves directly on $PORT
    # ============================================================
    echo "=== Direct Mode (no SSO) ==="
    echo "Starting OpenClaw on port ${OPENCLAW_PORT}..."
    exec node dist/index.js gateway --allow-unconfigured --port "$OPENCLAW_PORT" --bind lan
fi
