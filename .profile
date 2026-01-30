#!/bin/bash
# Cloud Foundry .profile script - runs before app starts
# Extracts GenAI service credentials from VCAP_SERVICES and configures OpenClaw

OPENCLAW_CONFIG_DIR="${HOME}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"

mkdir -p "$OPENCLAW_CONFIG_DIR"

if [ -n "$VCAP_SERVICES" ]; then
    echo "Parsing VCAP_SERVICES for GenAI configuration..."

    # Generate OpenClaw config file with GenAI provider using Node.js
    node -e "
const fs = require('fs');
const path = require('path');

const vcap = JSON.parse(process.env.VCAP_SERVICES || '{}');
const genai = vcap.genai?.[0]?.credentials;

if (!genai) {
    console.log('No GenAI service found in VCAP_SERVICES');
    process.exit(0);
}

const apiBase = genai.api_base || genai.endpoint?.api_base;
const apiKey = genai.api_key || genai.endpoint?.api_key;
const modelName = genai.model_name;
const wireFormat = genai.wire_format || 'openai';

if (!apiBase || !apiKey || !modelName) {
    console.log('GenAI service credentials incomplete');
    process.exit(0);
}

console.log('GenAI service detected:');
console.log('  Model: ' + modelName);
console.log('  API Base: ' + apiBase);
console.log('  Wire Format: ' + wireFormat);

// Create a provider name from the model (e.g., 'tanzu-qwen')
const providerName = 'tanzu-genai';
const modelId = providerName + '/' + modelName.replace(/[^a-zA-Z0-9-]/g, '-');

// Build OpenClaw config with the GenAI provider
const config = {
    agents: {
        defaults: {
            model: {
                primary: modelId
            }
        }
    },
    models: {
        providers: {
            [providerName]: {
                baseUrl: apiBase,
                apiKey: apiKey,
                api: 'openai-responses',  // Use OpenAI-compatible API
                models: [
                    {
                        id: modelName.replace(/[^a-zA-Z0-9-]/g, '-'),
                        name: modelName,
                        reasoning: false,
                        input: ['text'],
                        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
                        contextWindow: 32768,
                        maxTokens: 8192
                    }
                ]
            }
        }
    }
};

const configPath = process.env.OPENCLAW_CONFIG_FILE || path.join(process.env.HOME, '.openclaw', 'openclaw.json');
const configDir = path.dirname(configPath);

// Load existing config if present and merge
let existingConfig = {};
try {
    if (fs.existsSync(configPath)) {
        existingConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    }
} catch (e) {
    console.log('No existing config found, creating new one');
}

// Deep merge - GenAI config takes precedence
const merged = {
    ...existingConfig,
    agents: {
        ...existingConfig.agents,
        defaults: {
            ...existingConfig.agents?.defaults,
            model: config.agents.defaults.model
        }
    },
    models: {
        ...existingConfig.models,
        providers: {
            ...existingConfig.models?.providers,
            ...config.models.providers
        }
    }
};

fs.mkdirSync(configDir, { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(merged, null, 2));
console.log('OpenClaw config written to: ' + configPath);
console.log('Primary model set to: ' + modelId);
" 2>&1

    if [ $? -eq 0 ]; then
        echo "OpenClaw configured to use Tanzu GenAI service"
    else
        echo "Warning: Failed to configure GenAI service"
    fi
fi

# Export config path for OpenClaw
export OPENCLAW_CONFIG_PATH="$OPENCLAW_CONFIG_FILE"
