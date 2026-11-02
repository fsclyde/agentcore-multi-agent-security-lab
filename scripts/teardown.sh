#!/usr/bin/env bash
# Delete everything the lab created. EKS, the NAT gateway and the agents cost money while they run.
set -euo pipefail
terraform -chdir=infra destroy -var deploy_agents=true
rm -rf .local
