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
$version = '0.1.23'

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
        description = 'Shows a session state on the HumanNeeded puck (the desk status light on the user''s PC). Call it when the user asks to test the puck, or when a "HumanNeeded" hook message in a cloud session asks you to: pass that session_id. It only sets the light and links the session to it; nothing is stored in the session.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state      = @{ type = 'string'; enum = @('working', 'needs', 'done', 'idle', 'end') }
                session_id = @{ type = 'string'; description = 'For a cloud session: the exact session_id given in the HumanNeeded hook message. Required to link the session; without it only the light changes.' }
                agent      = @{ type = 'string' }
            }
            required   = @('state')
        }
    }
)

# First 32 hex digits of sha256(session_id); the cloud hook computes the same.
function Get-SessionHash([string]$id) {
    $sha = [Security.Cryptography.SHA256]::Create()
    (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($id)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 32)
}

# Claimed cloud sessions, shared by every connector instance through claims.json
# ({hash: expiry}); the instance holding the relay WebSocket sends them to the relay.
$claimsFile = Join-Path $env:USERPROFILE '.humanneeded\claims.json'
function Add-RelayClaim([string]$h) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $claims = @{}
            if (Test-Path $claimsFile) {
                $old = Get-Content $claimsFile -Raw | ConvertFrom-Json
                foreach ($p in $old.PSObject.Properties) { if ([long]$p.Value -gt $now) { $claims[$p.Name] = [long]$p.Value } }
            }
            $claims[$h] = $now + 86400
            New-Item -ItemType Directory -Force (Split-Path $claimsFile) | Out-Null
            [IO.File]::WriteAllText($claimsFile, ($claims | ConvertTo-Json -Compress), $utf8)
            Write-Log "relay: claimed cloud session $($h.Substring(0, 6))..."
            return
        } catch { Start-Sleep -Milliseconds 100 }
    }
}

# Runs hn.ps1 in its own process, its output captured so it can't reach the MCP stream.
function Invoke-SetState($arguments) {
    $state = "$($arguments.state)".ToLower()
    if (@('working', 'needs', 'done', 'idle', 'end') -notcontains $state) { return "unknown state '$state'" }
    $raw = try { $arguments | ConvertTo-Json -Compress } catch { "$arguments" }
    Write-Log "set_state args: $("$raw".Substring(0, [Math]::Min(300, "$raw".Length)))"
    $id = $arguments.session_id
    if (-not $id) { $id = $arguments.sessionId }
    if (-not $id) { $id = $arguments.session }
    $session = if ($id) { "$id".Trim() } else { 'default' }
    $agent = if ($arguments.agent) { "$($arguments.agent)" -replace '\s', '' } else { 'claude' }
    if ($session -ne 'default') {
        # Claim this session at the relay so its cloud hook's states reach this PC, and show it
        # under the same name the relayed states use.
        $h = Get-SessionHash $session
        Add-RelayClaim $h
        $session = 'c-' + $h.Substring(0, 16)
    }
    Write-Log "set_state $state $session $agent"
    $null = (@{ session_id = $session } | ConvertTo-Json -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hn $state $agent 2>&1
    if ($session -eq 'default') {
        return "HumanNeeded check: the puck connector on $env:COMPUTERNAME set the light to $state, but no session_id arrived, so no cloud session was linked. To link one, call set_state again with session_id set to the id from the HumanNeeded hook message."
    }
    return "HumanNeeded check: the puck connector on $env:COMPUTERNAME got set_state $state and linked session $session"
}

# --- Cloud relay listener (test, 0.1.23) ---
# Cloud Claude sessions can't reach this PC, so their hooks POST signed states to the
# HumanNeeded relay on AWS, which forwards them over a WebSocket this connector holds open.
# The channel and HMAC secret live in %USERPROFILE%\.humanneeded\relay.json as the token
# "hn1.<channel>.<secret>" (created on first start). Two ways in:
#  - cloud sessions without a key (Cowork): the hook asks Claude to call set_state with the
#    session id once; this PC then claims sha256(session_id)[:32] at the relay, and the hook's
#    unsigned states for that hash come here. Accepted only for hashes claimed here.
#  - with the token in HN_RELAY (claude.ai/code env): signed states on the channel.
# Every message must be under 5 min old and not a replay before it reaches hn.ps1.
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

# The account key: sha256("humanneeded-account:" + Claude accountUuid)[:32]. The cloud VM's
# ~/.claude.json holds the same accountUuid, so its hook posts there and this PC claims it
# without any step in the session. Read with a regex: .claude.json can be large.
function Get-AccountKey {
    foreach ($dir in @($env:CLAUDE_CONFIG_DIR, $env:USERPROFILE)) {
        if (-not $dir) { continue }
        $f = Join-Path $dir '.claude.json'
        try {
            $m = [regex]::Match([IO.File]::ReadAllText($f), '"accountUuid"\s*:\s*"([0-9a-fA-F-]{36})"')
            if ($m.Success) { return Get-SessionHash ('humanneeded-account:' + $m.Groups[1].Value) }
        } catch {}
    }
    return ''
}

$relayListener = {
    param($config, $hn, $logFile, $claimsFile, $accountKey)
    function Log([string]$text) {
        try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), $text) } catch {}
    }
    $parts = "$($config.token)".Split('.')
    $channel = $parts[1]
    $key = [byte[]]($parts[2] -split '(..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
    $hmac = New-Object Security.Cryptography.HMACSHA256 (, $key)
    $seen = @{}
    # Unexpired claimed session hashes from claims.json (written by set_state in any instance).
    function Read-Claims {
        $c = @{}
        try {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $o = Get-Content $claimsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { if ([long]$p.Value -gt $now) { $c[$p.Name] = [long]$p.Value } }
        } catch {}
        if ($accountKey) { $c[$accountKey] = [long]::MaxValue }   # this PC's Claude account, always
        return $c
    }
    function Send-Text($socket, [string]$text) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $socket.SendAsync((New-Object ArraySegment[byte] (, $bytes)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    }
    $claims = @{}

    # One listener per channel: other connector instances with the same token wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, "Local\HumanNeededRelay-$($channel.Substring(0, 12))"
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
            $claimsStamp = -1   # forces a claim of every session on each new connection
            while ($socket.State -eq 'Open') {
                if (-not $receive) {
                    $receive = $socket.ReceiveAsync((New-Object ArraySegment[byte] (, $buffer)), [Threading.CancellationToken]::None)
                }
                if (-not $receive.Wait(1000)) {
                    # New claims from set_state: send them all (the relay just refreshes them).
                    $stamp = try { (Get-Item $claimsFile -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { 0 }
                    if ($stamp -ne $claimsStamp) {
                        $claimsStamp = $stamp
                        $claims = Read-Claims
                        $list = @($claims.Keys | Select-Object -First 16)
                        if ($list.Count) {
                            Send-Text $socket (@{ action = 'claim'; h = $list } | ConvertTo-Json -Compress)
                            Log "claimed $($list.Count) cloud session(s) at the relay"
                        }
                    }
                    # API Gateway drops idle sockets after 10 min; ping every 5.
                    if (([DateTime]::UtcNow - $lastPing).TotalMinutes -ge 5) {
                        Send-Text $socket '{"action":"ping"}'
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
                    $m = $body | ConvertFrom-Json
                    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    $signer = $hmac
                    if (-not $sig) {
                        # Unsigned state for a claimed cloud session (POST /h/{hash}).
                        $h = "$($envelope.h)"
                        if ($h -notmatch '^[0-9a-f]{32}$' -or "$($m.h)" -ne $h) { Log 'dropped an unsigned message with a bad session hash'; continue }
                        if (-not $claims.ContainsKey($h)) { $claims = Read-Claims }
                        if (-not $claims.ContainsKey($h)) { Log "dropped a state for unclaimed session $($h.Substring(0, 6))..."; continue }
                        $replayKey = $body
                    } else {
                    if ($null -ne $m.x) {
                        # hn2 key from relay_pair: HMAC(secret, "hn2:<expiry>"), valid until expiry.
                        $expiry = [long]$m.x
                        if ($expiry -lt $now -or $expiry -gt $now + 8 * 86400) { Log 'dropped a message with an expired pairing key'; continue }
                        $subKey = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("hn2:$expiry"))
                        $signer = New-Object Security.Cryptography.HMACSHA256 (, $subKey)
                    }
                    $expected = -join ($signer.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)) | ForEach-Object { $_.ToString('x2') })
                    $diff = $sig.Length -bxor $expected.Length
                    for ($i = 0; $i -lt [Math]::Min($sig.Length, $expected.Length); $i++) { $diff = $diff -bor ([int][char]$sig[$i] -bxor [int][char]$expected[$i]) }
                    if ($diff -ne 0) { Log 'dropped a message with a bad signature'; continue }
                    $replayKey = $sig
                    }
                    foreach ($old in @($seen.Keys)) { if ($now - $seen[$old] -gt 600) { $seen.Remove($old) } }
                    if ($seen.ContainsKey($replayKey)) { Log 'dropped a replayed message'; continue }
                    $seen[$replayKey] = $now
                    if ([Math]::Abs($now - [long]$m.t) -gt 300) { Log "dropped a stale message ($($now - [long]$m.t) s old)"; continue }
                    $state = "$($m.s)".ToLower()
                    if (@('working', 'needs', 'done', 'idle', 'end') -notcontains $state) { continue }
                    # Account-routed states carry the session's own short hash in "u".
                    $hh = if ("$($m.u)" -match '^[0-9a-f]{16}$') { "$($m.u)" } else { "$($m.h)" -replace '[^0-9a-f]', '' }
                    $session = 'c-' + $hh.Substring(0, [Math]::Min(16, $hh.Length))
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
        $accountKey = Get-AccountKey
        Write-Log $(if ($accountKey) { "relay: cloud sessions of this PC's Claude account go to the puck (key $($accountKey.Substring(0, 6))...)" } else { 'relay: no Claude account found in .claude.json; cloud sessions need linking' })
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($relayListener).AddArgument($config).AddArgument($hn).AddArgument($logFile).AddArgument($claimsFile).AddArgument($accountKey)
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
