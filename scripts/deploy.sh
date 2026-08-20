#!/usr/bin/env bash

# Stop execution immediately if any command fails
set -eo pipefail

# 1. Environment Validation
TARGET_ENV="${1:-dev}"
echo "=========================================="
echo "🚀 Starting Deployment for Environment: ${TARGET_ENV}"
echo "=========================================="

if [[ ! "$TARGET_ENV" =~ ^(dev|test|prod)$ ]]; then
  echo "❌ Error: Invalid environment '$TARGET_ENV'. Must be one of: dev, test, prod"
  exit 1
fi

# 2. Build Frontend Assets (Node.js)
if [ -d "frontend" ]; then
  echo "📦 Building Frontend application..."
  cd frontend
  npm ci
  npm run build --if-present
  cd ..
else
  echo "⚠️ No 'frontend' directory found, skipping Node build."
fi

# 3. Setup Python Virtual Environment (using uv)
if [ -f "pyproject.toml" ] || [ -f "requirements.txt" ]; then
  echo "🐍 Setting up Python environment with uv..."
  uv venv .venv
  source .venv/bin/activate
  
  if [ -f "pyproject.toml" ]; then
    uv pip install .
  elif [ -f "requirements.txt" ]; then
    uv pip install -r requirements.txt
  fi
fi

# 4. Terraform Workspace Selection & Deployment
echo "🏗️ Running Terraform Provisioning..."
cd terraform

# Ensure backend initialization
terraform init -input=false

# Select workspace or create it if it doesn't exist
terraform workspace select "$TARGET_ENV" 2>/dev/null || terraform workspace new "$TARGET_ENV"

# Execute Terraform Plan and Apply
terraform plan -var-file="${TARGET_ENV}.tfvars" -out="tfplan-${TARGET_ENV}" -input=false 2>/dev/null || terraform plan -out="tfplan-${TARGET_ENV}" -input=false
terraform apply -input=false "tfplan-${TARGET_ENV}"

# 5. Sync Frontend Build Artifacts to S3 Bucket
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket 2>/dev/null || echo "")

if [ -n "$FRONTEND_BUCKET" ] && [ -d "../frontend/dist" ]; then
  echo "📤 Uploading frontend build to S3 Bucket: s3://${FRONTEND_BUCKET}..."
  aws s3 sync ../frontend/dist "s3://${FRONTEND_BUCKET}" --delete
elif [ -n "$FRONTEND_BUCKET" ] && [ -d "../frontend/build" ]; then
  echo "📤 Uploading frontend build to S3 Bucket: s3://${FRONTEND_BUCKET}..."
  aws s3 sync ../frontend/build "s3://${FRONTEND_BUCKET}" --delete
else
  echo "ℹ️ Skipping S3 sync (Bucket output or frontend build directory not found)."
fi

cd ..

echo "=========================================="
echo "✅ Script execution finished successfully!"
echo "=========================================="