// Auto-brake: the BrakeAlarm (traffic far above normal) publishes to BrakeTopic, which invokes this.
// It lowers both API stages' throttles to BRAKE_RATE/s so a flood can't run up the bill.
// Undo with `sh relay/ops/relay-ops.sh normal` (or any stack deploy, which restores template values).
import { ApiGatewayV2Client, UpdateStageCommand } from '@aws-sdk/client-apigatewayv2';

const gw = new ApiGatewayV2Client({});
const { HTTP_API, WS_API, BRAKE_RATE = '3', BRAKE_BURST = '6' } = process.env;

export const handler = async (event) => {
  const msg = event?.Records?.[0]?.Sns?.Message || '';
  if (msg && !/"NewStateValue"\s*:\s*"ALARM"/.test(msg)) return; // ignore OK transitions
  const s = { ThrottlingRateLimit: Number(BRAKE_RATE), ThrottlingBurstLimit: Number(BRAKE_BURST) };
  await gw.send(new UpdateStageCommand({ ApiId: HTTP_API, StageName: '$default', DefaultRouteSettings: s }));
  await gw.send(new UpdateStageCommand({ ApiId: WS_API, StageName: 'v1', DefaultRouteSettings: s }));
  console.log(JSON.stringify({ brake: 'on', rate: s.ThrottlingRateLimit }));
};
