#!/bin/sh
# Deploys or updates the HumanNeeded relay stack and prints its URLs.
#   sh relay/deploy.sh [profile] [region]      (defaults: humanneeded us-east-2)
# Sign in first with: aws login --profile humanneeded. No keys are kept in this repo.
set -e
profile="${1:-humanneeded}"; region="${2:-us-east-2}"
cd "$(dirname "$0")"
aws cloudformation deploy --stack-name humanneeded-relay --template-file template.yaml \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --profile "$profile" --region "$region"
aws cloudformation describe-stacks --stack-name humanneeded-relay --profile "$profile" --region "$region" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
