import type { EngineInterface, Register } from 'claude-code'

// Cloud sessions (Cowork, claude.ai/code) run the hooks in Anthropic's VM, where the
// shell hooks can't reach the puck. There this module sends each state to the
// plugin's local connector ("puck", scripts/hn-mcp.ps1), which the Claude desktop app
// runs on the linked PC. Local sessions keep using the shell hooks in hooks.json.

type State = 'working' | 'needs' | 'done' | 'end'

let server: string | undefined
let lastSent: string | undefined
let reported = false

// The connector's name as $.mcp.call takes it, found once per session.
async function findServer($: EngineInterface): Promise<{ server?: string; refused?: string }> {
  if (server) return { server }
  const connected = await $.mcp.connect('puck')
  if (connected.isConnected) return { server: (server = connected.server) }
  const tool = (await $.tool.list()).find(t => t.mcp && /puck|humanneeded/i.test(t.name) && t.name.endsWith('__set_state'))
  if (tool) return { server: (server = tool.name.slice('mcp__'.length, -'__set_state'.length)) }
  return { refused: `${connected.reason}: ${connected.message}` }
}

async function send($: EngineInterface, state: State, sessionId: string) {
  if ((await $.env.get('CLAUDE_CODE_REMOTE')) !== 'true') return
  const key = `${sessionId} ${state}`
  if (key === lastSent) return
  lastSent = key

  const started = Date.now()
  let outcome: string
  const found = await findServer($)
  if (found.server) {
    try {
      const result = await $.mcp.call(found.server, 'set_state', { state, session_id: sessionId, agent: 'claude' })
      outcome = `${result.isError ? 'error' : 'ok'}: ${result.content.map(c => c.text ?? c.type).join(' ')}`
    } catch (error) {
      outcome = `call failed: ${error}`
    }
  } else {
    outcome = `no connector (${found.refused})`
  }

  // Temporary: the first send of each session reports what it found, so a Cowork
  // test shows whether the cloud session reaches the PC. The model never reads it.
  if (!reported) {
    reported = true
    const servers = [...new Set((await $.tool.list()).filter(t => t.mcp).map(t => t.name.split('__')[1]))]
    const text = [
      `HumanNeeded check: ${state} -> ${outcome} (${Date.now() - started} ms)`,
      `connector: ${found.server ?? 'not found'}`,
      `entrypoint: ${await $.env.get('CLAUDE_CODE_ENTRYPOINT')}`,
      `MCP servers: ${servers.join(', ') || 'none'}`,
    ].join('\n')
    await $.session.append({ message: { type: 'system', content: [{ type: 'text', text }] } }).catch(() => {})
  }
}

// Sends alongside the rest of the chain; a failed send never fails it.
async function relay<R>($: EngineInterface, state: State, sessionId: string, rest: Promise<R>) {
  const [result] = await Promise.all([rest, send($, state, sessionId).catch(() => {})])
  return result
}

// Each hook's .catch hands the event on unchanged if the hook fails.
export const register: Register = on => {
  on('classic.UserPromptSubmit', ($, e, next) => relay($, 'working', e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.PostToolUse', ($, e, next) => relay($, 'working', e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.Notification', ($, e, next) =>
    e.notification_type === 'permission_prompt' || e.notification_type === 'idle_prompt'
      ? relay($, 'needs', e.session_id, next(e))
      : next(e),
  ).catch(($, e, next) => next(e))
  on('classic.Stop', ($, e, next) => relay($, 'done', e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.SessionEnd', ($, e, next) => relay($, 'end', e.session_id, next(e))).catch(($, e, next) => next(e))
}
