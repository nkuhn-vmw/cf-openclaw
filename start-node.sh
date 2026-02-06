#!/bin/bash
# OpenClaw Node - Cloud Foundry Startup Script
# Connects to the gateway via internal CF networking to provide system.run capabilities
set -e

GATEWAY_HOST="${OPENCLAW_GATEWAY_HOST:-openclaw.apps.internal}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-8081}"
GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
NODE_NAME="${OPENCLAW_NODE_NAME:-cf-node}"

echo "=== OpenClaw Node ==="
echo "Gateway: ${GATEWAY_HOST}:${GATEWAY_PORT}"
echo "Node Name: ${NODE_NAME}"

if [ -z "$GATEWAY_TOKEN" ]; then
    echo ""
    echo "ERROR: OPENCLAW_GATEWAY_TOKEN is required"
    echo "Get the token from the gateway logs:"
    echo "  cf logs openclaw --recent | grep 'Token:'"
    echo ""
    echo "Then set it:"
    echo "  cf set-env openclaw-node OPENCLAW_GATEWAY_TOKEN <token>"
    echo "  cf restage openclaw-node"
    exit 1
fi

# ============================================================
# Set up pre-registered device identity
# ============================================================
# If OPENCLAW_NODE_DEVICE_PRIVATE_KEY is set, write the device identity
# so the node connects with the same identity pre-registered in the gateway.
if [ -n "$OPENCLAW_NODE_DEVICE_PUBLIC_KEY" ] && [ -n "$OPENCLAW_NODE_DEVICE_PRIVATE_KEY" ]; then
    echo ""
    echo "Setting up pre-registered device identity..."

    IDENTITY_DIR="${HOME}/.openclaw/identity"
    mkdir -p "$IDENTITY_DIR"

    node -e "
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const publicKeyPem = process.env.OPENCLAW_NODE_DEVICE_PUBLIC_KEY;
const privateKeyPem = process.env.OPENCLAW_NODE_DEVICE_PRIVATE_KEY;

// Calculate deviceId from public key
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
try {
    const key = crypto.createPublicKey(publicKeyPem);
    const spki = key.export({ type: 'spki', format: 'der' });
    const rawKey = spki.subarray(ED25519_SPKI_PREFIX.length);
    const deviceId = crypto.createHash('sha256').update(rawKey).digest('hex');

    const identity = {
        version: 1,
        deviceId,
        publicKeyPem,
        privateKeyPem,
        createdAtMs: Date.now()
    };

    const identityPath = path.join(process.env.HOME, '.openclaw', 'identity', 'device.json');
    fs.mkdirSync(path.dirname(identityPath), { recursive: true });
    fs.writeFileSync(identityPath, JSON.stringify(identity, null, 2));
    fs.chmodSync(identityPath, 0o600);
    console.log('  Device ID: ' + deviceId);
    console.log('  Identity written to: ' + identityPath);
} catch (err) {
    console.error('  WARNING: Failed to write device identity: ' + err.message);
    process.exit(1);
}
" 2>&1
fi

# Wait for gateway to be reachable (container-to-container networking can take a moment)
echo ""
echo "Waiting for gateway to be reachable..."
MAX_WAIT=60
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if nc -z -w 2 "$GATEWAY_HOST" "$GATEWAY_PORT" 2>/dev/null; then
        echo "Gateway is reachable!"
        break
    fi
    echo "  Waiting for ${GATEWAY_HOST}:${GATEWAY_PORT}... (${WAITED}s)"
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ $WAITED -ge $MAX_WAIT ]; then
    echo ""
    echo "WARNING: Could not reach gateway at ${GATEWAY_HOST}:${GATEWAY_PORT}"
    echo "Ensure network policy is configured:"
    echo "  cf add-network-policy openclaw-node openclaw --port 8081 --protocol tcp"
    echo ""
    echo "Starting anyway - node will retry connection..."
fi

# Function to auto-approve our pairing request
auto_approve_pairing() {
    echo ""
    echo "Checking for pending pairing requests..."

    # Wait a moment for the pairing request to be registered
    sleep 3

    # List pending pairing requests using the OpenClaw CLI
    PENDING_JSON=$(node dist/index.js nodes list \
        --host "$GATEWAY_HOST" \
        --port "$GATEWAY_PORT" \
        --token "$GATEWAY_TOKEN" \
        --json 2>/dev/null || echo '{}')

    # Find our node's pairing request by display name
    REQUEST_ID=$(echo "$PENDING_JSON" | node -e "
        let data = '';
        process.stdin.on('data', chunk => data += chunk);
        process.stdin.on('end', () => {
            try {
                const parsed = JSON.parse(data);
                const pending = parsed.pending || [];
                const req = pending.find(r =>
                    r.displayName === '${NODE_NAME}' ||
                    r.nodeId?.includes('${NODE_NAME}')
                );
                if (req && req.requestId) {
                    console.log(req.requestId);
                }
            } catch (e) {}
        });
    " 2>/dev/null)

    if [ -n "$REQUEST_ID" ]; then
        echo "Found pairing request: $REQUEST_ID"
        echo "Auto-approving..."

        node dist/index.js nodes approve "$REQUEST_ID" \
            --host "$GATEWAY_HOST" \
            --port "$GATEWAY_PORT" \
            --token "$GATEWAY_TOKEN" 2>&1 || true

        echo "Pairing approved!"
    else
        echo "No pending pairing request found for ${NODE_NAME}"
        echo "Node may already be paired, or pairing request not yet registered."
    fi
}

echo ""
echo "Starting OpenClaw node..."

# Start node in background - it will connect and request pairing
node dist/index.js node run \
    --host "$GATEWAY_HOST" \
    --port "$GATEWAY_PORT" \
    --display-name "$NODE_NAME" &
NODE_PID=$!

# Give the node a moment to connect and request pairing
sleep 2

# Try to auto-approve the pairing request
auto_approve_pairing &

# Wait for the node process
wait $NODE_PID
