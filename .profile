#!/bin/bash
# Cloud Foundry .profile script - runs before app starts
# Configures OpenClaw with GenAI service credentials and gateway auth

OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"

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
                    // Filter out embedding models (not usable for chat)
                    allModels = modelsData.data.filter(m => !(/embed/i.test(m.id)));
                    console.log('  Discovered ' + modelsData.data.length + ' model(s) (' + allModels.length + ' chat-capable):');
                    modelsData.data.forEach(m => {
                        const skip = /embed/i.test(m.id) ? ' (embedding, skipped)' : '';
                        console.log('    - ' + m.id + skip);
                    });
                    // Prefer model set via OPENCLAW_PREFERRED_MODEL env var, or pick
                    // the largest model (prefer names containing size hints like '120b')
                    const preferred = process.env.OPENCLAW_PREFERRED_MODEL;
                    if (preferred) {
                        const match = allModels.find(m => m.id === preferred || m.id.includes(preferred));
                        if (match) modelName = match.id;
                        else console.log('  WARNING: Preferred model "' + preferred + '" not found');
                    }
                    if (!modelName && allModels.length > 0) {
                        // Heuristic: prefer models with larger parameter counts
                        const sorted = [...allModels].sort((a, b) => {
                            const sizeOf = id => { const m = id.match(/(\\d+)[bB]/); return m ? parseInt(m[1]) : 0; };
                            return sizeOf(b.id) - sizeOf(a.id);
                        });
                        modelName = sorted[0].id;
                    }
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
            // Only strip '/' from model ID (conflicts with provider/model path format).
            // Preserve colons and other chars — the id is sent as the 'model' param in
            // the API request and must match what the GenAI proxy expects.
            const apiModelId = modelName.replace(/\\//g, '-');
            const modelId = providerName + '/' + apiModelId;

            // Determine the correct base URL for OpenClaw
            // The GenAI proxy serves at \$API_BASE/openai/v1/...
            // OpenClaw needs the base URL pointing to the OpenAI-compatible endpoint
            let baseUrl = apiBase.replace(/\\/+$/, '');
            if (!baseUrl.endsWith('/v1')) {
                baseUrl = baseUrl + '/openai/v1';
            }

            // Build model entries for all discovered chat models
            const modelCompat = {
                maxTokensField: 'max_tokens',
                supportsDeveloperRole: false,
                supportsStore: false
            };
            const modelEntries = (allModels || [{ id: modelName }]).map(m => ({
                id: m.id.replace(/\\//g, '-'),
                name: m.id,
                reasoning: false,
                input: ['text'],
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                contextWindow: 32768,
                maxTokens: 8192,
                compat: modelCompat
            }));
            // Ensure primary model is first in the list
            modelEntries.sort((a, b) => (a.id === apiModelId ? -1 : b.id === apiModelId ? 1 : 0));
            console.log('  Registered ' + modelEntries.length + ' model(s) with OpenClaw');

            genaiConfig = {
                providerName,
                modelId,
                provider: {
                    baseUrl: baseUrl,
                    apiKey: apiKey,
                    api: 'openai-completions',
                    models: modelEntries
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
let gatewayToken = process.env.OPENCLAW_GATEWAY_TOKEN;
if (!gatewayToken) {
    const crypto = require('crypto');
    gatewayToken = crypto.randomBytes(32).toString('hex');
    console.log('');
    console.log('=== Gateway Authentication ===');
    console.log('Auto-generated gateway token (no OPENCLAW_GATEWAY_TOKEN env var set):');
    console.log('  Token: ' + gatewayToken);
    console.log('  Set this in your client to connect to the gateway.');
    console.log('  To use a fixed token: cf set-env openclaw OPENCLAW_GATEWAY_TOKEN <your-token>');
}

const config = {
    gateway: {
        auth: {
            mode: 'token',
            token: gatewayToken
        },
        controlUi: {
            allowInsecureAuth: true
        }
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
console.log('Gateway auth: token mode');
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
# S3 Storage Detection (Persistent Storage)
# ============================================================
# Search VCAP_SERVICES for S3-compatible credentials across service types:
# seaweedfs, s3, aws-s3, minio, ceph, or user-provided.
# Writes ~/s3.env for start.sh to source before launching OpenClaw.
if [ -n "$VCAP_SERVICES" ]; then
    S3_DETECTED=$(node -e "
const vcap = JSON.parse(process.env.VCAP_SERVICES || '{}');
const serviceTypes = ['seaweedfs', 's3', 'aws-s3', 'minio', 'ceph', 'user-provided'];
let creds = null;
let svcName = '';
for (const type of serviceTypes) {
    for (const svc of (vcap[type] || [])) {
        const c = svc.credentials || {};
        // Support both naming conventions: access_key_id/secret_access_key (AWS)
        // and access_key/secret_key (SeaweedFS, MinIO)
        const accessKey = c.access_key_id || c.access_key;
        const secretKey = c.secret_access_key || c.secret_key;
        if (accessKey && secretKey && c.bucket) {
            creds = { ...c, _accessKey: accessKey, _secretKey: secretKey };
            svcName = svc.name;
            break;
        }
    }
    if (creds) break;
}
if (creds) {
    const lines = [
        'export S3_ACCESS_KEY_ID=\"' + creds._accessKey + '\"',
        'export S3_SECRET_ACCESS_KEY=\"' + creds._secretKey + '\"',
        'export S3_BUCKET=\"' + creds.bucket + '\"',
    ];
    const endpoint = creds.endpoint_url || creds.endpoint;
    if (endpoint) {
        // Ensure endpoint has a protocol prefix
        const ep = endpoint.match(/^https?:\/\//) ? endpoint : 'https://' + endpoint;
        lines.push('export S3_ENDPOINT=\"' + ep + '\"');
    }
    if (creds.region) lines.push('export S3_REGION=\"' + creds.region + '\"');
    require('fs').writeFileSync(process.env.HOME + '/s3.env', lines.join('\n') + '\n');
    console.log('found:' + svcName);
}
" 2>/dev/null)

    if [ -n "$S3_DETECTED" ]; then
        echo ""
        echo "=== S3 Persistent Storage ==="
        echo "  Service: ${S3_DETECTED#found:}"
        echo "  Credentials written to ~/s3.env"
        echo "  State will be synced to/from S3 by start.sh"
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
