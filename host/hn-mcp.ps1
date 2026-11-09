# HumanNeeded local connector (MCP over stdio) for Windows PowerShell 5.1.
#
# The Claude desktop app runs this on the PC for the plugin. Its one tool, set_state, is
# called by the model when testing the puck, and cloud sessions reach it through the relay below;
# and passes the state to the puck through hn.ps1.
# Each start and call adds a line to %USERPROFILE%\.humanneeded\hn.log.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = Join-Path $PSScriptRoot 'hn.ps1'
$logFile = Join-Path $env:USERPROFILE '.humanneeded\hn.log'
$version = '0.1.17'

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
    return "HumanNeeded check: the puck connector on $env:COMPUTERNAME got set_state $state for session $session"
}

# --- Cloud relay listener (test, 0.1.17) ---
# Cloud Claude sessions can't reach this PC, so their hooks POST signed states to the
# HumanNeeded relay on AWS, which forwards them over a WebSocket this connector holds open.
# The channel and HMAC secret live in %USERPROFILE%\.humanneeded\relay.json as the token
# "hn1.<channel>.<secret>" (created on first start); the same token goes into the plugin's
# "relay" option so the cloud hook can sign. The relay never sees the secret: each message is
# checked here (signature, timestamp within 5 min, no replays) before it reaches hn.ps1.
$relayWs = 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1'
$relayFile = Join-Path $env:USERPROFILE '.humanneeded\relay.json'

function Get-RelayConfig {
    $config = $null
    if (Test-Path $relayFile) { try { $config = Get-Content $relayFile -Raw | ConvertFrom-Json } catch {} }
    if (-not $config -or "$($config.token)" -notmatch '^hn1\.[0-9a-f]{32}\.[0-9a-f]{64}$') {
        $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
        $hex = { param($n) $b = New-Object byte[] $n; $rng.GetBytes($b); -join ($b | ForEach-Object { $_.ToString('x2') }) }
        $config = [pscustomobject]@{ token = "hn1.$(& $hex 16).$(& $hex 32)"; ws = $relayWs; enabled = $true }
        New-Item -ItemType Directory -Force (Split-Path $relayFile) | Out-Null
        [IO.File]::WriteAllText($relayFile, ($config | ConvertTo-Json), $utf8)
        Write-Log 'relay: created a new channel token in relay.json'
    }
    if (-not $config.ws) { $config | Add-Member ws $relayWs -Force }
    return $config
}

$relayListener = {
    param($config, $hn, $logFile)
    function Log([string]$text) {
        try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), $text) } catch {}
    }
    $parts = "$($config.token)".Split('.')
    $channel = $parts[1]
    $key = [byte[]]($parts[2] -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, $key)
    $seen = @{}

    # One listener per Windows user: other connector instances wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, 'Local\HumanNeededRelayListener'
    while ($true) {
        try { if ($mutex.WaitOne(30000)) { break } } catch [Threading.AbandonedMutexException] { break }
    }

    $backoff = 5
    while ($true) {
        $socket = New-Object Net.WebSockets.ClientWebSocket
        try {
            $uri = [Uri]("$($config.ws)?ch=$channel")
            $socket.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait(15000) | Out-Null
            if ($socket.State -ne 'Open') { throw "connect to $($uri.Host) failed ($($socket.State))" }
            Log "connected, channel $($channel.Substring(0, 6))..."
            $backoff = 5
            $buffer = New-Object byte[] 4096
            $text = ''
            $receive = $null
            $lastPing = [DateTime]::UtcNow
            while ($socket.State -eq 'Open') {
                if (-not $receive) {
                    $receive = $socket.ReceiveAsync((New-Object ArraySegment[byte] (, $buffer)), [Threading.CancellationToken]::None)
                }
                if (-not $receive.Wait(30000)) {
                    # API Gateway drops idle sockets after 10 min; ping every 5.
                    if (([DateTime]::UtcNow - $lastPing).TotalMinutes -ge 5) {
                        $ping = [Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                        $socket.SendAsync((New-Object ArraySegment[byte] (, $ping)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
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
                    $envelope = $message | ConvertFrom-Json
                    $body = "$($envelope.b)"
                    $sig = "$($envelope.sig)".ToLower()
                    $expected = -join ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)) | ForEach-Object { $_.ToString('x2') })
                    $diff = $sig.Length -bxor $expected.Length
                    for ($i = 0; $i -lt [Math]::Min($sig.Length, $expected.Length); $i++) { $diff = $diff -bor ([int][char]$sig[$i] -bxor [int][char]$expected[$i]) }
                    if ($diff -ne 0) { Log 'dropped a message with a bad signature'; continue }
                    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    foreach ($old in @($seen.Keys)) { if ($now - $seen[$old] -gt 600) { $seen.Remove($old) } }
                    if ($seen.ContainsKey($sig)) { Log 'dropped a replayed message'; continue }
                    $seen[$sig] = $now
                    $m = $body | ConvertFrom-Json
                    if ([Math]::Abs($now - [long]$m.t) -gt 300) { Log "dropped a stale message ($($now - [long]$m.t) s old)"; continue }
                    $state = "$($m.s)".ToLower()
                    if (@('working', 'needs', 'done', 'idle', 'end') -notcontains $state) { continue }
                    $session = 'c-' + ("$($m.h)" -replace '[^0-9a-f]', '')
                    $agent = if ($m.a) { "$($m.a)" -replace '[^A-Za-z0-9_-]', '' } else { 'claude' }
                    Log "$state $session $agent ($($now - [long]$m.t) s)"
                    $null = (@{ session_id = $session } | ConvertTo-Json -Compress) |
                        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hn $state $agent 2>&1
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
        $config = Get-RelayConfig
        if ($config.enabled -eq $false -or "$($config.ws)" -like '*REPLACE_AFTER_DEPLOY*') { return }
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($relayListener).AddArgument($config).AddArgument($hn).AddArgument($logFile)
        $script:relayHandle = $ps.BeginInvoke()
        $script:relayPs = $ps
    } catch { Write-Log "relay: could not start: $_" }
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
Start-RelayListener
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
