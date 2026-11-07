# HumanNeeded local connector (MCP over stdio) for Windows PowerShell 5.1.
#
# The Claude desktop app runs this on the PC for the plugin. Its one tool, set_state, is
# called by the plugin's hooks module, including from cloud sessions linked to this PC,
# and passes the state to the puck through hn.ps1.
# Each start and call adds a line to %USERPROFILE%\.humanneeded\hn.log.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = Join-Path $PSScriptRoot 'hn.ps1'
$logFile = Join-Path $env:USERPROFILE '.humanneeded\hn.log'
$version = '0.1.5'

function Write-Log([string]$text) {
    try {
        New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null
        Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  mcp: {1}' -f (Get-Date), $text)
    } catch {}
}

function Send-Message($message) {
    [Console]::Out.Write(($message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    [Console]::Out.Flush()
}

$tools = @(
    @{
        name        = 'set_state'
        description = 'Shows a session state on the HumanNeeded puck. The plugin calls it itself; call it only when the user asks to test the puck connection.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state      = @{ type = 'string'; enum = @('working', 'needs', 'done', 'idle', 'end') }
                session_id = @{ type = 'string' }
                agent      = @{ type = 'string' }
            }
            required   = @('state')
        }
    }
)

# Runs hn.ps1 in its own process, its output captured so it can't reach the MCP stream.
function Invoke-SetState($arguments) {
    $state = "$($arguments.state)".ToLower()
    if (@('working', 'needs', 'done', 'idle', 'end') -notcontains $state) { return "unknown state '$state'" }
    $session = if ($arguments.session_id) { "$($arguments.session_id)" } else { 'default' }
    $agent = if ($arguments.agent) { "$($arguments.agent)" -replace '\s', '' } else { 'claude' }
    Write-Log "set_state $state $session $agent"
    $null = (@{ session_id = $session } | ConvertTo-Json -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hn $state $agent 2>&1
    return 'OK'
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
while ($null -ne ($line = [Console]::In.ReadLine())) {
    if (-not $line.Trim()) { continue }
    try { $request = $line | ConvertFrom-Json } catch { continue }
    $id = $request.id
    $result = $null
    try {
        switch ($request.method) {
            'initialize' {
                $protocol = if ($request.params.protocolVersion) { $request.params.protocolVersion } else { '2025-06-18' }
                $result = @{ protocolVersion = $protocol; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'humanneeded'; version = $version } }
            }
            'tools/list' { $result = @{ tools = $tools } }
            'tools/call' {
                if ($request.params.name -ne 'set_state') { throw "unknown tool $($request.params.name)" }
                $text = Invoke-SetState $request.params.arguments
                $result = @{ content = @(@{ type = 'text'; text = $text }); isError = ($text -ne 'OK') }
            }
            'ping' { $result = @{} }
            default {
                if ($null -ne $id) { Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = "no method $($request.method)" } } }
            }
        }
        if ($null -ne $id -and $null -ne $result) { Send-Message @{ jsonrpc = '2.0'; id = $id; result = $result } }
    } catch {
        if ($null -ne $id) { Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32603; message = "$_" } } }
    }
}
Write-Log 'stopped'
