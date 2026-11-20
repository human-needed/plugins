#!/bin/sh
# Fast relay controls (see relay/RUNBOOK.md). Needs: aws login --profile humanneeded
#   sh relay/ops/relay-ops.sh status            throttles, function concurrency, alarm states
#   sh relay/ops/relay-ops.sh brake [rate]      throttle both APIs to <rate>/s (default 3)
#   sh relay/ops/relay-ops.sh normal            back to template values (20/s, burst 40)
#   sh relay/ops/relay-ops.sh kill              relay OFF: APIs throttled to 0 + function disabled
#   sh relay/ops/relay-ops.sh revive            undo kill (then 'normal')
set -e
export AWS_PROFILE="${AWS_PROFILE:-humanneeded}" AWS_REGION="${AWS_REGION:-us-east-2}" MSYS_NO_PATHCONV=1
STACK=hn-relay-v1
res() { aws cloudformation describe-stack-resource --stack-name $STACK --logical-resource-id "$1" \
  --query StackResourceDetail.PhysicalResourceId --output text; }
HTTP=$(res HttpApi); WS=$(res WsApi); FN=$(res RelayFunction)
throttle() {
  aws apigatewayv2 update-stage --api-id "$HTTP" --stage-name '$default' \
    --default-route-settings "ThrottlingRateLimit=$1,ThrottlingBurstLimit=$2" >/dev/null
  aws apigatewayv2 update-stage --api-id "$WS" --stage-name v1 \
    --default-route-settings "ThrottlingRateLimit=$1,ThrottlingBurstLimit=$2" >/dev/null
  echo "throttle: $1/s burst $2 on POST and WebSocket"
}
case "$1" in
status)
  for a in "$HTTP \$default" "$WS v1"; do set -- $a
    aws apigatewayv2 get-stage --api-id "$1" --stage-name "$2" \
      --query "['$2', DefaultRouteSettings.ThrottlingRateLimit, DefaultRouteSettings.ThrottlingBurstLimit]" --output text; done
  echo "function reserved concurrency: $(aws lambda get-function-concurrency --function-name "$FN" --query ReservedConcurrentExecutions --output text)"
  aws cloudwatch describe-alarms --alarm-name-prefix $STACK --query 'MetricAlarms[].[StateValue,AlarmName]' --output text ;;
brake)  r="${2:-3}"; throttle "$r" $(( r * 2 )) ;;
normal) throttle 20 40 ;;
kill)
  throttle 0 0
  aws lambda put-function-concurrency --function-name "$FN" --reserved-concurrent-executions 0 >/dev/null
  echo "relay function disabled (reserved concurrency 0)" ;;
revive)
  aws lambda delete-function-concurrency --function-name "$FN"
  echo "relay function enabled; now run: sh relay/ops/relay-ops.sh normal" ;;
*) sed -n 2,8p "$0"; exit 2 ;;
esac
