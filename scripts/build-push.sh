#!/usr/bin/env bash
# Build the three agent images for ARM64 and push them to ECR.
# Usage: ./scripts/build-push.sh [tag]   (run from the repo root)
set -euo pipefail

TAG="${1:-v1}"
REGION="$(terraform -chdir=infra output -raw region)"
REGISTRY="$(terraform -chdir=infra output -json ecr_repositories | jq -r '.triage' | cut -d/ -f1)"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for agent in triage holmes operator; do
  repo="$(terraform -chdir=infra output -json ecr_repositories | jq -r ".${agent}")"
  echo "==> ${agent} -> ${repo}:${TAG}"
  docker buildx build --platform linux/arm64 -f "agents/${agent}/Dockerfile" -t "${repo}:${TAG}" --push agents
done
