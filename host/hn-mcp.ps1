# HumanNeeded connector (MCP over stdio) for Windows PowerShell 5.1.
#
# The Claude desktop app runs this on the PC for the plugin. It does two things:
#  - Tool set_state: shows a state on the puck (Claude calls it when the user asks to test the
#    puck from a session that can't run hn.ps1 itself, such as a Cowork session).
#  - Cloud relay listener: cloud Claude sessions (Cowork, claude.ai/code) can't reach this PC, so
#    their hooks POST states to the HumanNeeded relay on AWS under this Claude account's key,
#    sha256("humanneeded-account:" + accountUuid)[:32]. The cloud VM's ~/.claude.json holds the
#    same accountUuid as this PC's, so this connector connects to the relay with that key and
#    passes the states that arrive to hn.ps1. No setup and nothing to pair.
# Each start, state and call adds a line to %USERPROFILE%\.humanneeded\hn.log.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = Join-Path $PSScriptRoot 'hn.ps1'
$logFile = Join-Path $env:USERPROFILE '.humanneeded\hn.log'
$relayWs = 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1'
$states = @('working', 'needs', 'done', 'idle', 'end')
$version = try { (Get-Content (Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { 'dev' }

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
        description = 'Shows a state on the HumanNeeded puck (the desk status light on the user''s computer). Call it when the user asks to test or preview the puck.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state = @{ type = 'string'; enum = $states }
                agent = @{ type = 'string' }
            }
            required   = @('state')
        }
    }
)

# Runs hn.ps1 in this process (no new PowerShell to start), its output captured so it can't
# reach the MCP stream. -SessionId keeps it from reading stdin, which is the MCP stream here.
function Invoke-SetState($arguments) {
    $state = "$($arguments.state)".ToLower()
    if ($states -notcontains $state) { return "unknown state '$state'" }
    $agent = if ($arguments.agent) { "$($arguments.agent)" -replace '[^A-Za-z0-9_-]', '' } else { 'claude' }
    Write-Log "set_state $state $agent"
    $null = & $hn $state $agent -SessionId default 2>&1
    return "The puck on $env:COMPUTERNAME now shows $state."
}

# The account key from .claude.json (read with a regex: the file can be large).
function Get-AccountKey {
    foreach ($dir in @($env:CLAUDE_CONFIG_DIR, $env:USERPROFILE)) {
        if (-not $dir) { continue }
        try {
            $m = [regex]::Match([IO.File]::ReadAllText((Join-Path $dir '.claude.json')), '"accountUuid"\s*:\s*"([0-9a-fA-F-]{36})"')
            if ($m.Success) {
                $sha = [Security.Cryptography.SHA256]::Create()
                $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('humanneeded-account:' + $m.Groups[1].Value))
                return (-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 32)
            }
        } catch {}
    }
    return ''
}

$relayListener = {
    param($key, $ws, $hn, $logFile, $states)
    function Log([string]$text) {
        try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), $text) } catch {}
    }

    # One listener per account: other connector instances wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, "Local\HumanNeededRelay-$($key.Substring(0, 12))"
    while ($true) {
        try { if ($mutex.WaitOne(30000)) { break } } catch [Threading.AbandonedMutexException] { break }
    }

    $backoff = 5
    while ($true) {
        $socket = New-Object Net.WebSockets.ClientWebSocket
        try {
            $uri = [Uri]("$($ws)?k=$key")
            $socket.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait(15000) | Out-Null
            if ($socket.State -ne 'Open') { throw "connect to $($uri.Host) failed ($($socket.State))" }
            Log 'connected'
            $backoff = 5
            $buffer = New-Object byte[] 4096
            $text = ''
            $receive = $null
            $lastPing = [DateTime]::UtcNow
            while ($socket.State -eq 'Open') {
                if (-not $receive) {
                    $receive = $socket.ReceiveAsync((New-Object ArraySegment[byte] (, $buffer)), [Threading.CancellationToken]::None)
                }
                if (-not $receive.Wait(1000)) {
                    # API Gateway drops idle sockets after 10 min; ping every 5.
                    if (([DateTime]::UtcNow - $lastPing).TotalMinutes -ge 5) {
                        $bytes = [Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                        $socket.SendAsync((New-Object ArraySegment[byte] (, $bytes)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
                        $lastPing = [DateTime]::UtcNow
                    }
                    continue
                }
                $r = $receive.Result
                $receive = $null
                if ($r.MessageType -eq 'Close') { break }
                $text += [Text.Encoding]::UTF8.GetString($buffer, 0, $r.Count)
                if (-not $r.EndOfMessage) { continue }
                $message = $text; $text = ''
                try {
                    # {"s":state,"h":account key,"u":session hash,"t":unix time,"a":agent}
                    $m = $message | ConvertFrom-Json
                    if ("$($m.h)" -ne $key) { Log 'dropped a state for another key'; continue }
                    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$m.t
                    if ([Math]::Abs($age) -gt 300) { Log "dropped a stale state ($age s old)"; continue }
                    $state = "$($m.s)".ToLower()
                    if ($states -notcontains $state) { continue }
                    $session = 'c-' + ("$($m.u)" -replace '[^0-9a-f]', '')
                    $agent = if ($m.a) { "$($m.a)" -replace '[^A-Za-z0-9_-]', '' } else { 'claude' }
                    Log "$state $session $agent ($age s)"
                    $null = & $hn $state $agent -SessionId $session 2>&1
                } catch { Log "bad message: $_" }
            }
            Log "disconnected ($($socket.State))"
        } catch {
            Log "error: $($_.Exception.GetBaseException().Message); retry in $backoff s"
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, 120)
        } finally {
            $socket.Dispose()
        }
    }
}

function Start-RelayListener {
    try {
        $key = Get-AccountKey
        if (-not $key) { Write-Log 'relay: no Claude account in .claude.json, so cloud sessions can''t reach the puck'; return }
        Write-Log "relay: cloud sessions of this Claude account go to the puck (key $($key.Substring(0, 6))...)"
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($relayListener).AddArgument($key).AddArgument($relayWs).AddArgument($hn).AddArgument($logFile).AddArgument($states)
        $script:relayHandle = $ps.BeginInvoke()
        $script:relayPs = $ps
    } catch { Write-Log "relay: could not start: $_" }
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
Start-RelayListener
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $line = $line.TrimStart([char]0xFEFF)
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
                $text = switch ($request.params.name) {
                    'set_state' { Invoke-SetState $request.params.arguments }
                    default { throw "unknown tool $($request.params.name)" }
                }
                $result = @{ content = @(@{ type = 'text'; text = $text }); isError = ($text -like 'unknown state*') }
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
# The relay listener runs on its own thread; end the process so it can't outlive the app.
[Environment]::Exit(0)
