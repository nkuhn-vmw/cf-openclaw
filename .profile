#!/bin/bash
# Cloud Foundry .profile script - runs before app starts
# Configures OpenClaw with GenAI service credentials, gateway auth, and SSO

OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
SSO_ENV_FILE="${HOME}/sso.env"

mkdir -p "$OPENCLAW_CONFIG_DIR"

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
                    api: 'openai-responses',
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
