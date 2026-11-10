# HumanNeeded TEST connector (test build, not for customers). Windows PowerShell 5.1, MCP over stdio.
#
# Tests the account-key design with one swap: the relay key is a random secret this computer
# makes once (device.key), instead of a hash of the account id.
#  1. The cloud VM's hook asks the model to call the "link" tool once. That call crosses
#     Anthropic's bridge (remote-devices), which only this Claude account's linked computer
#     can receive. It does not light the puck.
#  2. The reply carries a link code (hn2-<key>). The VM's PostToolUse hook reads it from the
#     tool reply and saves it.
#  3. From then on the VM hook POSTs states to the relay under that key; this connector listens
#     on it (one connection, however many chats) and drops states that arrive out of order.
# Log: %USERPROFILE%\.humanneeded\test\test.log. The key is never logged.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = if ($env:HN_TEST_HN) { $env:HN_TEST_HN } else { Join-Path $PSScriptRoot 'hn.ps1' }
$testDir = if ($env:HN_TEST_HOME) { $env:HN_TEST_HOME } else { Join-Path $env:USERPROFILE '.humanneeded\test' }
$logFile = Join-Path $testDir 'test.log'
$keyFile = Join-Path $testDir 'device.key'
$relayWs = if ($env:HN_TEST_WS) { $env:HN_TEST_WS } else { 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1' }
$mutexName = if ($env:HN_TEST_MUTEX) { $env:HN_TEST_MUTEX } else { 'Local\HumanNeededTestRelay' }
$states = @('working', 'needs', 'done', 'idle', 'end')
$version = try { (Get-Content (Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { 'dev' }
New-Item -ItemType Directory -Force $testDir | Out-Null

$logLine = @'
function Add-LogLine([string]$file, [string]$line) {   # several connector processes share this file
    for ($i = 0; $i -lt 6; $i++) {
        try {
            $fs = New-Object IO.FileStream $file, 'Append', 'Write', 'ReadWrite'
            try { $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds 15 }
    }
}
'@
. ([ScriptBlock]::Create($logLine))
function Write-Log([string]$text) { Add-LogLine $logFile ('{0:yyyy-MM-dd HH:mm:ss}  mcp: {1}' -f (Get-Date), $text) }

function Send-Message($message) {
    [Console]::Out.Write(($message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    [Console]::Out.Flush()
}

$tools = @(
    @{
        name        = 'set_state'
        description = 'Shows a state on the HumanNeeded puck (the desk status light on the user''s computer). Test build. Call it only when the user asks to test the puck.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state = @{ type = 'string'; enum = $states }
                agent = @{ type = 'string' }
            }
            required   = @('state')
        }
    },
    @{
        name        = 'link'
        description = 'Links a cloud session to the HumanNeeded puck on the user''s computer. Takes no arguments and does not change the light. Call it only when a "HumanNeeded" hook message asks you to.'
        inputSchema = @{ type = 'object'; properties = @{} }
    }
)

function Get-DeviceKey {
    for ($try = 0; $try -lt 8; $try++) {
        try { $k = [IO.File]::ReadAllText($keyFile).Trim(); if ($k -cmatch '^[0-9a-f]{32}$') { return $k } } catch {}
        try {
            # Missing, empty or damaged: make a new one. CreateNew fails if another instance got there first.
            if ((Test-Path $keyFile) -and $try -ge 2) { Remove-Item -Force $keyFile; Write-Log 'the device key file was damaged; replacing it' }
            $b = New-Object byte[] 16
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
            $fs = [IO.File]::Open($keyFile, 'CreateNew')
            try { $bytes = $utf8.GetBytes((-join ($b | ForEach-Object { $_.ToString('x2') }))); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            Write-Log 'made a new device key'
        } catch { Start-Sleep -Milliseconds 100 }
    }
    throw 'could not read or create the device key'
}

function Invoke-SetState($arguments) {
    $state = if ($arguments.state -is [string]) { $arguments.state.ToLower() } else { '' }
    if ($states -notcontains $state) { return @{ err = $true; text = "unknown state '$($state -replace '[^a-z0-9_-]', '?')'" } }
    $agent = if ($arguments.agent) { ("$($arguments.agent)" -replace '[^A-Za-z0-9_-]', '') } else { 'claude' }
    if (-not $agent) { $agent = 'claude' }
    if ($agent.Length -gt 16) { $agent = $agent.Substring(0, 16) }
    Write-Log "call: set_state $state agent=$agent"
    $null = & $hn $state $agent -SessionId 'default' 2>&1
    @{ err = $false; text = "HumanNeeded test: the puck on $env:COMPUTERNAME shows $state." }
}

function Invoke-Link {
    $key = Get-DeviceKey
    Write-Log 'call: link (reply carries the link code)'
    @{ err = $false; text = "HumanNeeded: this session is linked to the puck on $env:COMPUTERNAME. Link code hn2-$key (internal: the HumanNeeded hook reads it. Don't repeat or mention it.)" }
}

# Listens on the device key's channel (one WebSocket) and passes on what arrives.
$listener = {
    param($ws, $hn, $logFile, $keyFile, $states, $mutexName, $logLine)
    . ([ScriptBlock]::Create($logLine))
    function Log([string]$text) { Add-LogLine $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), ($text -replace '[0-9a-f]{32}', '<key>')) }
    function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    function Close-Sock($s) { if ($s) { try { if ($s.State -eq 'Open') { $s.CloseOutputAsync('NormalClosure', '', [Threading.CancellationToken]::None).Wait(2000) | Out-Null } } catch {}; try { $s.Dispose() } catch {} } }
    function Read-Key { try { $k = [IO.File]::ReadAllText($keyFile).Trim(); if ($k -cmatch '^[0-9a-f]{32}$') { return $k } } catch {}; '' }

    # One listener per PC user: other connector instances wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, $mutexName
    while ($true) { try { if ($mutex.WaitOne(30000)) { break } } catch [Threading.AbandonedMutexException] { break } }
    Log "listener running (pid $PID)"

    $sock = $null; $rx = $null; $next = 0; $backoff = 5; $text = ''; $ping = 0; $buf = New-Object byte[] 4096
    $key = ''; $keyCheck = 0; $last = @{}; $tick = Now; $trim = 0
    while ($true) {
        try {
            $now = Now
            if ($sock -and ($now - $tick) -gt 30) { Log 'the clock jumped (sleep?); reconnecting'; try { $sock.Dispose() } catch {}; $sock = $null; $rx = $null; $next = $now }
            $tick = $now
            if (($now - $keyCheck) -ge 5) {
                $keyCheck = $now; $k = Read-Key
                if ($k -ne $key) {
                    if ($sock) { Log 'the device key changed; reconnecting'; Close-Sock $sock; $sock = $null; $rx = $null }
                    $key = $k; $next = $now
                }
            }
            if (($now - $trim) -ge 60) {
                $trim = $now
                try { if ((Get-Item $logFile).Length -gt 512KB) { $keep = Get-Content $logFile -Tail 2000; Set-Content $logFile $keep } } catch {}
            }
            if ($sock -and $sock.State -ne 'Open') { Log "disconnected ($($sock.State))"; try { $sock.Dispose() } catch {}; $sock = $null; $rx = $null; $next = $now + 2 }
            if (-not $sock) {
                if (-not $key -or $now -lt $next) { Start-Sleep -Milliseconds 1000; continue }
                $s = New-Object Net.WebSockets.ClientWebSocket
                try {
                    $s.ConnectAsync([Uri]("$($ws)?k=$key"), [Threading.CancellationToken]::None).Wait(10000) | Out-Null
                    if ($s.State -ne 'Open') { throw "state $($s.State)" }
                    $sock = $s; $backoff = 5; $ping = $now; $text = ''; Log 'connected'
                } catch {
                    $s.Dispose()
                    Log "connect failed: $($_.Exception.GetBaseException().Message); retry in $backoff s"
                    $next = $now + $backoff; $backoff = [Math]::Min($backoff * 2, 120)
                    continue
                }
            }
            if (-not $rx) { $rx = $sock.ReceiveAsync((New-Object ArraySegment[byte] (, $buf)), [Threading.CancellationToken]::None) }
            if (($now - $ping) -ge 240) {   # API Gateway drops idle sockets after 10 min
                $b = [Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                try { $sock.SendAsync((New-Object ArraySegment[byte] (, $b)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null } catch {}
                $ping = $now
            }
            $ready = $false
            try { $ready = $rx.Wait(1000) } catch { $ready = $true }
            if (-not $ready) { continue }
            $done = $rx; $rx = $null
            if ($done.IsFaulted -or $done.IsCanceled) { try { $sock.Dispose() } catch {}; $sock = $null; $next = (Now) + 2; Log 'receive failed; reconnecting'; continue }
            $r = $done.Result
            if ($r.MessageType -eq 'Close') { try { $sock.Dispose() } catch {}; $sock = $null; $next = (Now) + 2; Log 'closed by the relay; reconnecting'; continue }
            $text += [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
            if ($text.Length -gt 2048) { $text = ''; Log 'REJECTED oversized message'; continue }
            if (-not $r.EndOfMessage) { continue }
            $raw = $text; $text = ''
            $m = $null
            try { $m = $raw | ConvertFrom-Json } catch {}
            if ($null -eq $m -or $m -isnot [Management.Automation.PSCustomObject]) { Log 'REJECTED unreadable message'; continue }
            $st = "$($m.s)"; $a = "$($m.a)"; $h = "$($m.h)"; $t = "$($m.t)"
            if ($m.s -isnot [string] -or $m.h -isnot [string] -or ($null -ne $m.a -and $m.a -isnot [string]) -or "$($m.v)" -ne '2' -or $states -cnotcontains $st -or
                $a -notmatch '^[A-Za-z0-9_-]{0,16}$' -or $h -cnotmatch '^[0-9a-f]{16}$' -or $t -notmatch '^\d{0,16}$') { Log 'REJECTED malformed message'; continue }
            if (-not $a) { $a = 'claude' }
            $short = $h.Substring(0, 8)
            if ($t) {   # hooks run side by side, so states can overtake each other
                $tv = [long]$t
                if ($last.ContainsKey($h) -and $tv -lt $last[$h] -and ($last[$h] - $tv) -lt 30000) { Log "dropped late $st (chat $short, $($last[$h] - $tv) ms behind)"; continue }
                if ($last.Count -gt 500) { $last.Clear() }
                $last[$h] = $tv
            }
            Log "received $st $a (chat $short)"
            try { $null = & $hn $st $a -SessionId ('c-' + $h) 2>&1 } catch { Log "puck script failed: $($_.Exception.Message)" }
        } catch {
            Log "listener error: $($_.Exception.GetBaseException().Message)"
            try { if ($sock) { $sock.Dispose() } } catch {}
            $sock = $null; $rx = $null; $next = (Now) + 5
            Start-Sleep -Milliseconds 1000
        }
    }
}

function Start-Listener {
    try {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($listener).AddArgument($relayWs).AddArgument($hn).AddArgument($logFile).AddArgument($keyFile).AddArgument($states).AddArgument($mutexName).AddArgument($logLine)
        $script:listenerHandle = $ps.BeginInvoke()
        $script:listenerPs = $ps
    } catch { Write-Log "could not start the listener: $_" }
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
try { $null = Get-DeviceKey } catch { Write-Log "device key: $_" }
Start-Listener
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $line = $line.TrimStart([char]0xFEFF)
    if (-not $line.Trim()) { continue }
    try { $request = $line | ConvertFrom-Json } catch { continue }
    if ($request -isnot [Management.Automation.PSCustomObject]) { continue }
    $id = $request.id
    $result = $null
    try {
        switch ("$($request.method)") {
            'initialize' {
                $protocol = if ($request.params.protocolVersion) { $request.params.protocolVersion } else { '2025-06-18' }
                $result = @{ protocolVersion = $protocol; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'humanneeded-test'; version = $version } }
            }
            'tools/list' { $result = @{ tools = $tools } }
            'tools/call' {
                $r = switch ("$($request.params.name)") {
                    'set_state' { Invoke-SetState $request.params.arguments }
                    'link' { Invoke-Link }
                    default { throw "unknown tool $("$($request.params.name)" -replace '[^A-Za-z0-9_-]', '?')" }
                }
                $result = @{ content = @(@{ type = 'text'; text = $r.text }); isError = $r.err }
            }
            'ping' { $result = @{} }
            default {
                if ($null -ne $id) { Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = 'no such method' } } }
            }
        }
        if ($null -ne $id -and $null -ne $result) { Send-Message @{ jsonrpc = '2.0'; id = $id; result = $result } }
    } catch {
        if ($null -ne $id) { Send-Message @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32603; message = "$_" } } }
    }
}
Write-Log 'stopped'
[Environment]::Exit(0)
