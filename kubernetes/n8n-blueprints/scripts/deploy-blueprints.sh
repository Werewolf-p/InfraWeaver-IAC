#!/bin/bash
set -euo pipefail

# N8N Blueprint Deployment Script
# Deploys workflow blueprints to n8n via REST API

usage() {
  cat << USAGE
Usage: $0 [OPTIONS]

Options:
  --n8n-url URL              n8n instance URL (default: https://n8n.${BASE_DOMAIN})
  --n8n-token TOKEN          n8n admin API token (default: from N8N_ADMIN_TOKEN env)
  --blueprints DIR           Directory containing blueprint JSON files (default: ./templates)
  --dry-run                  Show what would be deployed without making changes
  --help                     Show this help message

Examples:
  $0 --n8n-url https://n8n.${BASE_DOMAIN} --n8n-token abc123
  $0 --blueprints ./templates --dry-run
USAGE
  exit 0
}

# Defaults
N8N_URL="${N8N_URL:-https://n8n.${BASE_DOMAIN}}"
N8N_TOKEN="${N8N_ADMIN_TOKEN:-}"
BLUEPRINTS_DIR="./templates"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --n8n-url) N8N_URL="$2"; shift 2 ;;
    --n8n-token) N8N_TOKEN="$2"; shift 2 ;;
    --blueprints) BLUEPRINTS_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate requirements
if [[ -z "$N8N_TOKEN" ]]; then
  echo "❌ Error: N8N_ADMIN_TOKEN not set and --n8n-token not provided"
  exit 1
fi

if [[ ! -d "$BLUEPRINTS_DIR" ]]; then
  echo "❌ Error: Blueprints directory not found: $BLUEPRINTS_DIR"
  exit 1
fi

echo "📋 N8N Blueprint Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "N8N URL: $N8N_URL"
echo "Blueprints: $BLUEPRINTS_DIR"
echo "Dry Run: $DRY_RUN"
echo ""

# Check n8n connectivity
echo "🔍 Checking n8n connectivity..."
if ! curl -s -H "X-N8N-API-KEY: $N8N_TOKEN" "$N8N_URL/api/v1/health" > /dev/null; then
  echo "❌ Cannot connect to n8n at $N8N_URL"
  exit 1
fi
echo "✅ Connected to n8n"

# Deploy each blueprint
deployed=0
failed=0

for blueprint in "$BLUEPRINTS_DIR"/*.json; do
  if [[ ! -f "$blueprint" ]]; then
    continue
  fi
  
  name=$(basename "$blueprint" .json)
  echo ""
  echo "📦 Deploying: $name"
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   [DRY RUN] Would import: $blueprint"
    ((deployed++))
  else
    # Import workflow via n8n API
    response=$(curl -s -X POST \
      -H "X-N8N-API-KEY: $N8N_TOKEN" \
      -H "Content-Type: application/json" \
      -d @"$blueprint" \
      "$N8N_URL/api/v1/workflows")
    
    if echo "$response" | grep -q '"id"'; then
      workflow_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
      echo "   ✅ Deployed as workflow ID: $workflow_id"
      ((deployed++))
    else
      echo "   ❌ Failed to deploy"
      echo "   Response: $response"
      ((failed++))
    fi
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Summary: $deployed deployed, $failed failed"

if [[ $failed -gt 0 ]]; then
  exit 1
fi
