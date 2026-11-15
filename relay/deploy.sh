#!/bin/sh
# Deploys the hn-relay/1 stack (template.yaml) and prints its outputs.
#   sh relay/deploy.sh cert     request the ACM certificate and print the DNS validation records
#   sh relay/deploy.sh deploy   create/update the stack
# Env (optional; unset = keep the stack's previous value):
#   HN_CERT_ARN     validated ACM certificate ARN -> adds the custom domains
#   HN_ALERT_EMAIL  probe and budget alert address
#   AWS_PROFILE / AWS_REGION   default humanneeded / us-east-2
# Sign in first: aws login --profile humanneeded. No keys are kept in this repo.
set -e
export AWS_PROFILE="${AWS_PROFILE:-humanneeded}" AWS_REGION="${AWS_REGION:-us-east-2}"
STACK=hn-relay-v1
cd "$(dirname "$0")"

case "${1:-deploy}" in
cert)
  arn=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='relay.human-needed.com'].CertificateArn | [0]" --output text)
  if [ "$arn" = "None" ] || [ -z "$arn" ]; then
    arn=$(aws acm request-certificate --domain-name relay.human-needed.com \
      --subject-alternative-names relay-ws.human-needed.com --validation-method DNS \
      --query CertificateArn --output text)
    sleep 10
  fi
  echo "CertificateArn: $arn"
  aws acm describe-certificate --certificate-arn "$arn" \
    --query 'Certificate.[Status, DomainValidationOptions[].[DomainName, ResourceRecord.Name, ResourceRecord.Value]]' --output text
  ;;
deploy)
  account=$(aws sts get-caller-identity --query Account --output text)
  bucket="hn-relay-artifacts-$account-$AWS_REGION"
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    aws s3api create-bucket --bucket "$bucket" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    aws s3api put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration \
      '{"Rules":[{"ID":"expire","Status":"Enabled","Filter":{},"Expiration":{"Days":30}}]}'
  fi
  aws cloudformation package --template-file template.yaml --s3-bucket "$bucket" --s3-prefix "$STACK" \
    --output-template-file .packaged.yaml >/dev/null
  set --
  if ! aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
    set -- "$@" "ProbeSecret=$(python -c 'import secrets;print(secrets.token_hex(32))')"
  fi
  [ -n "$HN_CERT_ARN" ] && set -- "$@" "CertificateArn=$HN_CERT_ARN"
  [ -n "$HN_ALERT_EMAIL" ] && set -- "$@" "AlertEmail=$HN_ALERT_EMAIL"
  if [ $# -gt 0 ]; then po="--parameter-overrides"; else po=""; fi
  aws cloudformation deploy --stack-name "$STACK" --template-file .packaged.yaml \
    --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset $po "$@"
  rm -f .packaged.yaml
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text
  ;;
*) echo "usage: deploy.sh cert|deploy" >&2; exit 2 ;;
esac
