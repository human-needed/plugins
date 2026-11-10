# HumanNeeded TEST connector (test build, not for customers). Windows PowerShell 5.1, MCP over stdio.
#
# Tests the account-key design with one swap: the relay key is a random secret this computer
# makes once (device.key), instead of a hash of the account id.
#  1. The cloud VM's hook asks the model to call set_state once. That call crosses Anthropic's
#     bridge (remote-devices), which only this Claude account's linked computer can receive.
#  2. The reply carries a link code (hn2-<key>). The VM's PostToolUse hook reads it from the
#     tool reply and saves it.
#  3. From then on the VM hook POSTs states to the relay under that key; this connector listens
#     on it (one connection, however many chats).
# Log: %USERPROFILE%\.humanneeded\test\test.log. The key is never logged.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = Join-Path $PSScriptRoot 'hn.ps1'
$testDir = if ($env:HN_TEST_HOME) { $env:HN_TEST_HOME } else { Join-Path $env:USERPROFILE '.humanneeded\test' }
$logFile = Join-Path $testDir 'test.log'
$keyFile = Join-Path $testDir 'device.key'
$relayWs = if ($env:HN_TEST_WS) { $env:HN_TEST_WS } else { 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1' }
$mutexName = if ($env:HN_TEST_MUTEX) { $env:HN_TEST_MUTEX } else { 'Local\HumanNeededTestRelay' }
$states = @('working', 'needs', 'done', 'idle', 'end')
$version = try { (Get-Content (Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { 'dev' }
New-Item -ItemType Directory -Force $testDir | Out-Null

function Write-Log([string]$text) {
    try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  mcp: {1}' -f (Get-Date), $text) } catch {}
}

function Send-Message($message) {
    [Console]::Out.Write(($message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    [Console]::Out.Flush()
}

$tools = @(
    @{
        name        = 'set_state'
        description = 'Shows a state on the HumanNeeded puck (the desk status light on the user''s computer). Test build. Call it when the user asks to test the puck, or when a "HumanNeeded test" hook message asks you to.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state = @{ type = 'string'; enum = $states }
                agent = @{ type = 'string' }
                tag   = @{ type = 'string'; description = 'A test label from the user''s test prompt; logged on the computer.' }
            }
            required   = @('state')
        }
    }
)

function Get-DeviceKey {
    for ($try = 0; $try -lt 5; $try++) {
        try { $k = [IO.File]::ReadAllText($keyFile).Trim(); if ($k -match '^[0-9a-f]{32}$') { return $k } } catch {}
        try {
            $b = New-Object byte[] 16
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
            $fs = [IO.File]::Open($keyFile, 'CreateNew')   # fails if another instance got there first
            try { $bytes = $utf8.GetBytes((-join ($b | ForEach-Object { $_.ToString('x2') }))); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            Write-Log 'made a new device key'
        } catch { Start-Sleep -Milliseconds 100 }
    }
    throw 'could not read or create the device key'
}

function Invoke-SetState($arguments) {
    $state = "$($arguments.state)".ToLower()
    if ($states -notcontains $state) { return @{ err = $true; text = "unknown state '$state'" } }
    $agent = if ($arguments.agent) { ("$($arguments.agent)" -replace '[^A-Za-z0-9_-]', '') } else { 'claude' }
    if ($agent.Length -gt 16) { $agent = $agent.Substring(0, 16) }
    $tag = "$($arguments.tag)" -replace '[^A-Za-z0-9_.-]', ''
    if ($tag.Length -gt 80) { $tag = $tag.Substring(0, 80) }
    Write-Log "call: set_state $state agent=$agent tag=$tag (reply carries the link code)"
    $null = & $hn $state $agent -SessionId 'default' 2>&1
    @{ err = $false; text = "HumanNeeded test: the puck on $env:COMPUTERNAME shows $state. Link code hn2-$(Get-DeviceKey) (internal, used by the HumanNeeded hook; no need to repeat it)." }
}

# Listens on the device key's channel (one WebSocket) and passes on what arrives.
$listener = {
    param($ws, $hn, $logFile, $keyFile, $states, $mutexName)
    function Log([string]$text) { try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), $text) } catch {} }
    function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

    # One listener per PC user: other connector instances wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, $mutexName
    while ($true) { try { if ($mutex.WaitOne(30000)) { break } } catch [Threading.AbandonedMutexException] { break } }
    Log 'listener running'

    $sock = $null; $rx = $null; $next = 0; $backoff = 5; $text = ''; $ping = 0; $buf = New-Object byte[] 4096
    while ($true) {
        $now = Now
        if ($sock -and $sock.State -ne 'Open') { Log "disconnected ($($sock.State))"; try { $sock.Dispose() } catch {}; $sock = $null; $rx = $null; $next = $now + 2 }
        if (-not $sock -and $now -ge $next) {
            $key = try { [IO.File]::ReadAllText($keyFile).Trim() } catch { '' }
            if ($key -notmatch '^[0-9a-f]{32}$') { $next = $now + 5; Start-Sleep -Milliseconds 1000; continue }
            $s = New-Object Net.WebSockets.ClientWebSocket
            try {
                $s.ConnectAsync([Uri]("$($ws)?k=$key"), [Threading.CancellationToken]::None).Wait(10000) | Out-Null
                if ($s.State -ne 'Open') { throw "state $($s.State)" }
                $sock = $s; $backoff = 5; $ping = $now; $text = ''; Log 'connected'
            } catch {
                $s.Dispose()
                Log "connect failed: $($_.Exception.GetBaseException().Message -replace '[0-9a-f]{32}', '<key>'); retry in $backoff s"
                $next = $now + $backoff; $backoff = [Math]::Min($backoff * 2, 120)
            }
        }
        if (-not $sock) { Start-Sleep -Milliseconds 1000; continue }
        if (-not $rx) { $rx = $sock.ReceiveAsync((New-Object ArraySegment[byte] (, $buf)), [Threading.CancellationToken]::None) }
        if (($now - $ping) -ge 300) {   # API Gateway drops idle sockets after 10 min
            $b = [Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
            try { $sock.SendAsync((New-Object ArraySegment[byte] (, $b)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null } catch {}
            $ping = $now
        }
        $ready = $false
        try { $ready = $rx.Wait(1000) } catch { $ready = $true }
        if (-not $ready) { continue }
        $done = $rx; $rx = $null
        if ($done.IsFaulted -or $done.IsCanceled) { try { $sock.Dispose() } catch {}; $sock = $null; $next = (Now) + 2; Log 'receive failed'; continue }
        $r = $done.Result
        if ($r.MessageType -eq 'Close') { try { $sock.Dispose() } catch {}; $sock = $null; $next = (Now) + 2; Log 'closed by relay'; continue }
        $text += [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
        if ($text.Length -gt 2048) { $text = ''; Log 'REJECTED oversized message'; continue }
        if (-not $r.EndOfMessage) { continue }
        $raw = $text; $text = ''
        try {
            $m = $raw | ConvertFrom-Json
            $st = "$($m.s)"; $a = "$($m.a)"; $h = "$($m.h)"
            if ("$($m.v)" -ne '2' -or $states -notcontains $st -or $a -notmatch '^[A-Za-z0-9_-]{0,16}$' -or $h -notmatch '^[0-9a-f]{16}$') { Log 'REJECTED malformed message'; continue }
            if (-not $a) { $a = 'claude' }
            Log "received $st $a (chat $($h.Substring(0, 8)))"
            $null = & $hn $st $a -SessionId ('c-' + $h) 2>&1
        } catch { Log 'REJECTED unreadable message' }
    }
}

function Start-Listener {
    try {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($listener).AddArgument($relayWs).AddArgument($hn).AddArgument($logFile).AddArgument($keyFile).AddArgument($states).AddArgument($mutexName)
        $script:listenerHandle = $ps.BeginInvoke()
        $script:listenerPs = $ps
    } catch { Write-Log "could not start the listener: $_" }
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
$null = Get-DeviceKey
Start-Listener
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
                $result = @{ protocolVersion = $protocol; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'humanneeded-test'; version = $version } }
            }
            'tools/list' { $result = @{ tools = $tools } }
            'tools/call' {
                if ($request.params.name -ne 'set_state') { throw "unknown tool $($request.params.name)" }
                $r = Invoke-SetState $request.params.arguments
                $result = @{ content = @(@{ type = 'text'; text = $r.text }); isError = $r.err }
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
[Environment]::Exit(0)
