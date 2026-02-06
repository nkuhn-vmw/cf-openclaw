#!/bin/bash
# Cloud Foundry .profile script - runs before app starts
# Configures OpenClaw with GenAI service credentials, gateway auth, and SSO

OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
SSO_ENV_FILE="${HOME}/sso.env"

mkdir -p "$OPENCLAW_CONFIG_DIR"

# ============================================================
# 0. CredHub / Secrets Service Binding
# ============================================================
# If 'openclaw-secrets' user-provided service is bound, extract secrets
# and export them as env vars. These take precedence over manually-set env vars.
if [ -n "$VCAP_SERVICES" ]; then
    SECRETS_ENV=$(node -e "
const vcap = JSON.parse(process.env.VCAP_SERVICES || '{}');
const binding = (vcap['user-provided'] || []).find(s => s.name === 'openclaw-secrets')?.credentials
    || (vcap['credhub'] || []).find(s => s.name === 'openclaw-secrets')?.credentials;
if (binding) {
    const map = {
        gateway_token: 'OPENCLAW_GATEWAY_TOKEN',
        node_seed: 'OPENCLAW_NODE_SEED',
        cookie_secret: 'OPENCLAW_COOKIE_SECRET',
        node_max_instances: 'OPENCLAW_NODE_MAX_INSTANCES',
        pinned_version: 'OPENCLAW_PINNED_VERSION'
    };
    for (const [key, envVar] of Object.entries(map)) {
        if (binding[key]) {
            console.log('export ' + envVar + '=\"' + String(binding[key]).replace(/\"/g, '\\\\\"') + '\"');
        }
    }
}
" 2>/dev/null)

    if [ -n "$SECRETS_ENV" ]; then
        echo "=== Secrets loaded from openclaw-secrets service ==="
        eval "$SECRETS_ENV"
    fi
fi

# ============================================================
# 1. GenAI Service Configuration
# ============================================================
# Supports both credential formats:
#   - Deprecated (single-model): api_base, api_key, model_name at top level
#   - New (multi-model v10.2+): endpoint.api_base, endpoint.api_key, endpoint.config_url
# ============================================================

if [ -n "$VCAP_SERVICES" ]; then
    echo "=== OpenClaw CF Configuration ==="
    echo "Parsing VCAP_SERVICES for service bindings..."

    node -e "
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const vcap = JSON.parse(process.env.VCAP_SERVICES || '{}');

// --- GenAI Service ---
const genaiBinding = vcap.genai?.[0]?.credentials;
let genaiConfig = null;

if (genaiBinding) {
    // Extract credentials - handle both formats
    const apiBase = genaiBinding.api_base || genaiBinding.endpoint?.api_base;
    const apiKey = genaiBinding.api_key || genaiBinding.endpoint?.api_key;
    const configUrl = genaiBinding.endpoint?.config_url;
    let modelName = genaiBinding.model_name; // only in deprecated format
    const wireFormat = genaiBinding.wire_format || 'openai';

    if (!apiBase || !apiKey) {
        console.log('WARNING: GenAI service credentials incomplete (missing api_base or api_key)');
    } else {
        console.log('GenAI service detected:');
        console.log('  API Base: ' + apiBase);
        console.log('  Wire Format: ' + wireFormat);

        // If model_name not in credentials (new multi-model format),
        // discover models via the OpenAI-compatible models endpoint
        if (!modelName) {
            console.log('  Multi-model format detected - discovering available models...');
            try {
                const modelsUrl = apiBase.replace(/\\/+$/, '') + '/openai/v1/models';
                const curlCmd = 'curl -sf -H \"Authorization: Bearer ' + apiKey + '\" \"' + modelsUrl + '\"';
                const modelsResponse = execSync(curlCmd, { timeout: 10000 }).toString();
                const modelsData = JSON.parse(modelsResponse);

                if (modelsData.data && modelsData.data.length > 0) {
                    // Pick the first available model
                    modelName = modelsData.data[0].id;
                    console.log('  Discovered ' + modelsData.data.length + ' model(s):');
                    modelsData.data.forEach(m => console.log('    - ' + m.id));
                } else {
                    console.log('  WARNING: No models found via discovery endpoint');
                }
            } catch (err) {
                console.log('  WARNING: Model discovery failed: ' + (err.message || err));
                console.log('  Falling back to plan name from binding...');
                // Try to use the plan name from the binding as a fallback
                const planName = vcap.genai?.[0]?.plan;
                if (planName) {
                    modelName = planName;
                    console.log('  Using plan name as model: ' + planName);
                }
            }
        }

        if (modelName) {
            console.log('  Primary Model: ' + modelName);

            const providerName = 'tanzu-genai';
            const sanitizedModel = modelName.replace(/[^a-zA-Z0-9._-]/g, '-');
            const modelId = providerName + '/' + sanitizedModel;

            // Determine the correct base URL for OpenClaw
            // The GenAI proxy serves at \$API_BASE/openai/v1/...
            // OpenClaw needs the base URL pointing to the OpenAI-compatible endpoint
            let baseUrl = apiBase.replace(/\\/+$/, '');
            if (!baseUrl.endsWith('/v1')) {
                baseUrl = baseUrl + '/openai/v1';
            }

            genaiConfig = {
                providerName,
                modelId,
                provider: {
                    baseUrl: baseUrl,
                    apiKey: apiKey,
                    api: 'openai-completions',
                    models: [
                        {
                            id: sanitizedModel,
                            name: modelName,
                            reasoning: false,
                            input: ['text'],
                            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                            contextWindow: 32768,
                            maxTokens: 8192
                        }
                    ]
                }
            };
        } else {
            console.log('  WARNING: Could not determine model name - GenAI provider not configured');
        }
    }
} else {
    console.log('No GenAI service found in VCAP_SERVICES');
}

// --- Gateway Authentication ---
// Gateway token auth is always configured. When SSO is enabled, the token
// redirect proxy (in start.sh) auto-injects the token into the initial URL
// so the browser stores it for WebSocket auth.
const ssoEnabled = process.env.OPENCLAW_SSO_ENABLED === 'true';

let gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
if (!gatewayToken) {
    const crypto = require('crypto');
    gatewayToken = crypto.randomBytes(32).toString('hex');
    console.log('');
    console.log('=== Gateway Authentication ===');
    console.log('Auto-generated gateway token (no OPENCLAW_GATEWAY_TOKEN env var set):');
    console.log('  Token: ' + gatewayToken);
    if (ssoEnabled) {
        console.log('  Token will be auto-injected via SSO redirect proxy.');
    } else {
        console.log('  Set this in your client to connect to the gateway.');
        console.log('  To use a fixed token: cf set-env openclaw OPENCLAW_GATEWAY_TOKEN <your-token>');
    }
}

const config = {
    gateway: {
        auth: {
            mode: 'token',
            token: gatewayToken
        },
        // Allow Control UI (browser) to connect with token-only auth,
        // without requiring device pairing. Safe when SSO protects access.
        controlUi: {
            allowInsecureAuth: true
        },
        // Trust the local proxy chain (oauth2-proxy → token-inject → OpenClaw)
        trustedProxies: ['127.0.0.1']
    }
};

// Add GenAI provider if discovered
if (genaiConfig) {
    config.agents = {
        defaults: {
            model: {
                primary: genaiConfig.modelId
            }
        }
    };
    config.models = {
        providers: {
            [genaiConfig.providerName]: genaiConfig.provider
        }
    };
}

// --- SSO (p-identity) Credentials ---
const ssoBinding = vcap['p-identity']?.[0]?.credentials;
if (ssoBinding) {
    console.log('');
    console.log('=== SSO Service (p-identity) ===');
    console.log('  Auth Domain: ' + ssoBinding.auth_domain);
    console.log('  Client ID: ' + ssoBinding.client_id);
    console.log('  Issuer URI: ' + (ssoBinding.issuer_uri || 'not provided'));

    // Write SSO credentials to env file for start.sh to consume
    // Include the gateway token so start.sh can inject it into the proxy
    const ssoEnv = [
        'SSO_AUTH_DOMAIN=' + ssoBinding.auth_domain,
        'SSO_CLIENT_ID=' + ssoBinding.client_id,
        'SSO_CLIENT_SECRET=' + ssoBinding.client_secret,
        'SSO_ISSUER_URI=' + (ssoBinding.issuer_uri || ssoBinding.auth_domain + '/oauth/token'),
        'SSO_GATEWAY_TOKEN=' + gatewayToken,
        ''
    ].join('\\n');
    fs.writeFileSync(process.env.HOME + '/sso.env', ssoEnv);
    console.log('  SSO credentials written to ~/sso.env');
} else {
    console.log('');
    console.log('No SSO service (p-identity) found in VCAP_SERVICES');
}

// --- Merge and Write Config ---
const configPath = process.env.OPENCLAW_CONFIG_FILE || path.join(process.env.HOME, '.openclaw', 'openclaw.json');
const configDir = path.dirname(configPath);

// Load existing config if present
let existingConfig = {};
try {
    if (fs.existsSync(configPath)) {
        existingConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
} catch (e) {
    console.log('No existing config found, creating new one');
}

// Deep merge - our config takes precedence
const merged = {
    ...existingConfig,
    gateway: {
        ...existingConfig.gateway,
        ...config.gateway,
        auth: config.gateway.auth
    }
};

if (config.agents) {
    merged.agents = {
        ...existingConfig.agents,
        defaults: {
            ...existingConfig.agents?.defaults,
            model: config.agents.defaults.model
        }
    };
}

if (config.models) {
    merged.models = {
        ...existingConfig.models,
        providers: {
            ...existingConfig.models?.providers,
            ...config.models.providers
        }
    };
}

fs.mkdirSync(configDir, { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(merged, null, 2));
console.log('');
console.log('OpenClaw config written to: ' + configPath);
if (genaiConfig) {
    console.log('Primary model: ' + genaiConfig.modelId);
}
console.log('Gateway auth: token mode' + (ssoEnabled ? ' (auto-injected via SSO proxy)' : ''));
" 2>&1

    if [ $? -eq 0 ]; then
        echo ""
        echo "=== OpenClaw configured successfully ==="
    else
        echo ""
        echo "WARNING: OpenClaw configuration script failed"
    fi
fi

# Export config path for OpenClaw
export OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_FILE"

# ============================================================
# Version Detection & Pinning
# ============================================================
OPENCLAW_VERSION=""
if [ -f "package.json" ]; then
    OPENCLAW_VERSION=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('package.json','utf8')).version||'unknown')}catch(e){console.log('unknown')}" 2>/dev/null)
    echo ""
    echo "=== OpenClaw Version ==="
    echo "  Detected: v${OPENCLAW_VERSION}"

    if [ -n "$OPENCLAW_PINNED_VERSION" ]; then
        if [ "$OPENCLAW_VERSION" != "$OPENCLAW_PINNED_VERSION" ]; then
            echo "  WARNING: Version mismatch! Pinned: v${OPENCLAW_PINNED_VERSION}, Actual: v${OPENCLAW_VERSION}"
            echo "  The paired.json format or config schema may have changed."
            echo "  Update OPENCLAW_PINNED_VERSION if this is intentional."
        else
            echo "  Version matches pinned version."
        fi
    fi
fi
export OPENCLAW_VERSION

# ============================================================
# NFS Volume Detection (Persistent Storage)
# ============================================================
# If an NFS volume service is bound, auto-detect the mount path and use it
# for OPENCLAW_STATE_DIR so state persists across restages/restarts.
# Binding the service is the opt-in — no extra env var needed.
if [ -n "$VCAP_SERVICES" ]; then
    NFS_MOUNT=$(node -e "
const vcap = JSON.parse(process.env.VCAP_SERVICES || '{}');
const nfsBindings = vcap['nfs'] || vcap['smb'] || [];
const mount = nfsBindings[0]?.volume_mounts?.[0]?.container_dir;
if (mount) process.stdout.write(mount);
" 2>/dev/null)

    if [ -n "$NFS_MOUNT" ]; then
        echo ""
        echo "=== NFS Persistent Storage ==="
        echo "  Volume mount detected: ${NFS_MOUNT}"
        # Only override if OPENCLAW_STATE_DIR wasn't explicitly set by the user
        if [ "${OPENCLAW_STATE_DIR}" = "/home/vcap/app/data" ] || [ -z "${OPENCLAW_STATE_DIR_SET_BY_USER}" ]; then
            export OPENCLAW_STATE_DIR="${NFS_MOUNT}/openclaw"
            mkdir -p "$OPENCLAW_STATE_DIR"
            echo "  OPENCLAW_STATE_DIR set to: ${OPENCLAW_STATE_DIR}"
        else
            echo "  OPENCLAW_STATE_DIR already set to: ${OPENCLAW_STATE_DIR} (not overriding)"
        fi
    fi
fi

# Export the gateway token if it was auto-generated (make it available to start.sh)
if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    # Read the token back from the generated config
    if [ -f "$OPENCLAW_CONFIG_FILE" ]; then
        export OPENCLAW_GATEWAY_TOKEN=$(node -e "
            const cfg = JSON.parse(require('fs').readFileSync('$OPENCLAW_CONFIG_FILE', 'utf8'));
            if (cfg.gateway?.auth?.token) process.stdout.write(cfg.gateway.auth.token);
        " 2>/dev/null)
    fi
fi

# ============================================================
# Pre-register CF Node Device for auto-pairing
# ============================================================
# Two approaches supported:
#   1. OPENCLAW_NODE_SEED (recommended): Shared seed derives keypair deterministically.
#      Set the same seed on both gateway and node. Supports multi-instance scaling.
#   2. OPENCLAW_NODE_DEVICE_PUBLIC_KEY (legacy): PEM public key set explicitly.

if [ -n "$OPENCLAW_NODE_SEED" ]; then
    echo ""
    echo "=== Pre-registering Node Device (seed-based) ==="
    OPENCLAW_NODE_MAX_INSTANCES="${OPENCLAW_NODE_MAX_INSTANCES:-1}"
    echo "  Seed length: ${#OPENCLAW_NODE_SEED}"
    echo "  Max instances: ${OPENCLAW_NODE_MAX_INSTANCES}"
    echo "  State dir: ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

    node -e "
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const seed = process.env.OPENCLAW_NODE_SEED;
const maxInstances = parseInt(process.env.OPENCLAW_NODE_MAX_INSTANCES || '1', 10);
const stateDir = process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME, '.openclaw');
const devicesDir = path.join(stateDir, 'devices');
const pairedPath = path.join(devicesDir, 'paired.json');
const baseName = process.env.OPENCLAW_NODE_DEVICE_NAME || 'cf-node';

// Ed25519 DER format prefixes
const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function deriveDeviceFromSeed(seedStr) {
    const seedBytes = crypto.createHash('sha256').update(seedStr).digest();
    const pkcs8Der = Buffer.concat([ED25519_PKCS8_PREFIX, seedBytes]);
    const privateKey = crypto.createPrivateKey({ key: pkcs8Der, format: 'der', type: 'pkcs8' });
    const publicKey = crypto.createPublicKey(privateKey);
    const spki = publicKey.export({ type: 'spki', format: 'der' });
    const rawPublicKey = spki.subarray(ED25519_SPKI_PREFIX.length);
    const deviceId = crypto.createHash('sha256').update(rawPublicKey).digest('hex');
    const publicKeyBase64Url = rawPublicKey.toString('base64url');
    return { deviceId, publicKeyBase64Url };
}

// Load existing paired devices
let paired = {};
try {
    if (fs.existsSync(pairedPath)) {
        paired = JSON.parse(fs.readFileSync(pairedPath, 'utf8'));
    }
} catch (e) {}

const now = Date.now();
for (let i = 0; i < maxInstances; i++) {
    const instanceSeed = seed + ':' + i;
    const { deviceId, publicKeyBase64Url } = deriveDeviceFromSeed(instanceSeed);
    const displayName = baseName + '-' + i;

    paired[deviceId] = {
        deviceId,
        publicKey: publicKeyBase64Url,
        displayName,
        platform: 'linux',
        clientId: 'node-host',
        clientMode: 'node',
        role: 'node',
        roles: ['node'],
        scopes: [],
        createdAtMs: now,
        approvedAtMs: now
    };

    console.log('  Instance ' + i + ': deviceId=' + deviceId.substring(0, 16) + '... name=' + displayName);
}

fs.mkdirSync(devicesDir, { recursive: true });
fs.writeFileSync(pairedPath, JSON.stringify(paired, null, 2));
console.log('  Pre-paired ' + maxInstances + ' device(s) at: ' + pairedPath);
" 2>&1

    if [ $? -ne 0 ]; then
        echo "  Seed-based pre-registration script failed with exit code $?"
    fi

elif [ -n "$OPENCLAW_NODE_DEVICE_PUBLIC_KEY" ]; then
    # Legacy: Explicit PEM public key approach
    echo ""
    echo "=== Pre-registering Node Device (legacy PEM) ==="
    echo "  Public key env var length: ${#OPENCLAW_NODE_DEVICE_PUBLIC_KEY}"
    echo "  State dir: ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

    node -e "
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const stateDir = process.env.OPENCLAW_STATE_DIR || path.join(process.env.HOME, '.openclaw');
const devicesDir = path.join(stateDir, 'devices');
const pairedPath = path.join(devicesDir, 'paired.json');

const publicKeyPem = process.env.OPENCLAW_NODE_DEVICE_PUBLIC_KEY;
const displayName = process.env.OPENCLAW_NODE_DEVICE_NAME || 'cf-node';

console.log('  Display Name: ' + displayName);
console.log('  Public key first line: ' + (publicKeyPem || '').split('\\n')[0]);

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
try {
    const key = crypto.createPublicKey(publicKeyPem);
    const spki = key.export({ type: 'spki', format: 'der' });
    const rawKey = spki.subarray(ED25519_SPKI_PREFIX.length);
    const deviceId = crypto.createHash('sha256').update(rawKey).digest('hex');
    const publicKeyBase64Url = rawKey.toString('base64url');

    let paired = {};
    try {
        if (fs.existsSync(pairedPath)) {
            paired = JSON.parse(fs.readFileSync(pairedPath, 'utf8'));
        }
    } catch (e) {}

    const now = Date.now();
    paired[deviceId] = {
        deviceId,
        publicKey: publicKeyBase64Url,
        displayName,
        platform: 'linux',
        clientId: 'node-host',
        clientMode: 'node',
        role: 'node',
        roles: ['node'],
        scopes: [],
        createdAtMs: now,
        approvedAtMs: now
    };

    fs.mkdirSync(devicesDir, { recursive: true });
    fs.writeFileSync(pairedPath, JSON.stringify(paired, null, 2));
    console.log('  Device ID: ' + deviceId);
    console.log('  Public Key (base64url): ' + publicKeyBase64Url);
    console.log('  Pre-paired device registered at: ' + pairedPath);
} catch (err) {
    console.log('  ERROR: Failed to pre-register node device: ' + err.message);
    console.log('  Stack: ' + err.stack);
}
" 2>&1

    if [ $? -ne 0 ]; then
        echo "  PEM-based pre-registration script failed with exit code $?"
    fi
fi
