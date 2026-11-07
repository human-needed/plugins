import type { EngineInterface, Register } from 'claude-code'

// Cloud sessions (Cowork, claude.ai/code) run the hooks in Anthropic's VM, where the
// shell hooks can't reach the puck. There this module sends each state to the
// plugin's local connector ("puck", scripts/hn-mcp.ps1), which the Claude desktop app
// runs on the linked PC. Local sessions keep using the shell hooks in hooks.json.

type State = 'working' | 'needs' | 'done' | 'end'

// Where set_state lives, as $.mcp.call takes it: the plugin's own server in a local
// session; in a cloud one, the desktop app's bridge ("remote-devices"), which lists it as
// mcp__remote-devices__plugin_humanneeded_puck__set_state.
type Target = { server: string; tool: string }

let target: Target | undefined
let lastSent: string | undefined
let reported = false
const BRIDGE: Target = { server: 'remote-devices', tool: 'plugin_humanneeded_puck__set_state' }

// Temporary: in cloud sessions, a log inside the VM that Claude can read back
// (cat /tmp/hn-module.log), to see whether the module runs and what it finds.
const lines: string[] = []
async function trace($: EngineInterface, text: string) {
  lines.push(`${new Date().toISOString()}  ${text}`)
  await $.fs.write('/tmp/hn-module.log', lines.slice(-200).join('\n') + '\n').catch(() => {})
}

// Found once per session.
async function findTarget($: EngineInterface): Promise<{ target?: Target; refused?: string }> {
  if (target) return { target }
  const listed = (await $.tool.list()).find(t => t.mcp && /humanneeded_puck/i.test(t.name) && t.name.endsWith('__set_state'))
  if (listed) {
    // mcp__<server>__<tool>: the server name holds no "__"; the tool's may.
    const [, server, ...tool] = listed.name.split('__')
    return { target: (target = { server: server!, tool: tool.join('__') }) }
  }
  const connected = await $.mcp.connect('puck')
  if (connected.isConnected) return { target: (target = { server: connected.server, tool: 'set_state' }) }
  // Cowork loads the bridge's tools on demand, so set_state may not be listed yet.
  if ((await $.env.get('CLAUDE_CODE_REMOTE')) === 'true') return { target: BRIDGE, refused: `${connected.reason}: ${connected.message}` }
  return { refused: `${connected.reason}: ${connected.message}` }
}

async function send($: EngineInterface, state: State, sessionId: string) {
  if ((await $.env.get('CLAUDE_CODE_REMOTE')) !== 'true') return
  const key = `${sessionId} ${state}`
  if (key === lastSent) return
  lastSent = key

  const started = Date.now()
  let outcome: string
  const found = await findTarget($)
  if (found.target) {
    try {
      const result = await $.mcp.call(found.target.server, found.target.tool, { state, session_id: sessionId, agent: 'claude' })
      outcome = `${result.isError ? 'error' : 'ok'}: ${result.content.map(c => c.text ?? c.type).join(' ')}`
    } catch (error) {
      outcome = `call failed: ${error}`
      if (found.target === BRIDGE) target = undefined
    }
  } else {
    outcome = `no connector (${found.refused})`
  }
  await trace($, `${state} ${sessionId} -> ${outcome} (${Date.now() - started} ms, via ${found.target ? `${found.target.server} / ${found.target.tool}` : 'none'}${found.refused ? `; connect: ${found.refused}` : ''})`)

  // Temporary: the first send of each session reports what it found, so a Cowork
  // test shows whether the cloud session reaches the PC. The model never reads it.
  if (!reported) {
    reported = true
    const servers = [...new Set((await $.tool.list()).filter(t => t.mcp).map(t => t.name.split('__')[1]))]
    const text = [
      `HumanNeeded check: ${state} -> ${outcome} (${Date.now() - started} ms)`,
      `connector: ${found.target ? `${found.target.server} / ${found.target.tool}` : 'not found'}`,
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

// Temporary: in cloud sessions, hands the module's trace to the model with each prompt,
// since the engine's /tmp may not be the one Claude's shell sees.
async function withReport<R extends { additionalContext?: string[] }>($: EngineInterface, sessionId: string, rest: Promise<R>) {
  const result = await relay($, 'working', sessionId, rest)
  if ((await $.env.get('CLAUDE_CODE_REMOTE')) !== 'true') return result
  const report = `HumanNeeded module 0.1.12 trace (session ${sessionId}):\n${lines.join('\n') || '(empty)'}`
  return { ...result, additionalContext: [...(result.additionalContext ?? []), report] }
}

// Each hook's .catch hands the event on unchanged if the hook fails.
export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if ((await $.env.get('CLAUDE_CODE_REMOTE')) === 'true') {
      const tools = await $.tool.list()
      const mcp = tools.filter(t => t.mcp)
      await trace($, `loaded 0.1.12: ${tools.length} tools, ${mcp.length} MCP; puck: ${mcp.filter(t => /puck|humanneeded/i.test(t.name)).map(t => t.name).join(', ') || 'none'}; servers: ${[...new Set(mcp.map(t => t.name.split('__')[1]))].join(', ') || 'none'}`)
    }
    return next(e)
  }).catch(($, e, next) => next(e))
  on('classic.UserPromptSubmit', ($, e, next) => withReport($, e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.PostToolUse', ($, e, next) => relay($, 'working', e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.Notification', ($, e, next) =>
    e.notification_type === 'permission_prompt' || e.notification_type === 'idle_prompt'
      ? relay($, 'needs', e.session_id, next(e))
      : next(e),
  ).catch(($, e, next) => next(e))
  on('classic.Stop', ($, e, next) => relay($, 'done', e.session_id, next(e))).catch(($, e, next) => next(e))
  on('classic.SessionEnd', ($, e, next) => relay($, 'end', e.session_id, next(e))).catch(($, e, next) => next(e))
}
