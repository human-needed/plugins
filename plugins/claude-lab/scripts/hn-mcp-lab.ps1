# HumanNeeded LAB connector (test build, not for customers). Windows PowerShell 5.1, MCP over stdio.
#
# Tests a cloud link that needs no account key and no setup:
#  1. The cloud VM's hook makes a random 32-byte secret S for its session and asks the model to
#     call set_state once with pair=S. That call crosses Anthropic's own bridge (remote-devices),
#     which only this Claude account's linked computer can receive.
#  2. Both sides derive  channel = HMAC(S, "hn-lab-channel")[:32]  and  mac key = HMAC(S, "hn-lab-mac").
#  3. The VM signs every state with the mac key and POSTs it to the relay under the channel. This
#     connector listens on that channel and accepts only messages with a valid signature, a time
#     within 5 minutes and a nonce it hasn't seen. The relay only ever sees the channel.
# Every call and every accepted or rejected message adds a line to %USERPROFILE%\.humanneeded\lab\lab.log.
# The secret itself is never logged.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$hn = Join-Path $PSScriptRoot 'hn.ps1'
$labDir = if ($env:HN_LAB_HOME) { $env:HN_LAB_HOME } else { Join-Path $env:USERPROFILE '.humanneeded\lab' }
$logFile = Join-Path $labDir 'lab.log'
$pairsFile = Join-Path $labDir 'pairs.json'
$relayWs = if ($env:HN_LAB_WS) { $env:HN_LAB_WS } else { 'wss://r9k4y2qgz5.execute-api.us-east-2.amazonaws.com/v1' }
$states = @('working', 'needs', 'done', 'idle', 'end')
$maxPairs = 8
$pairHours = 24
$version = try { (Get-Content (Join-Path $PSScriptRoot '..\.claude-plugin\plugin.json') -Raw | ConvertFrom-Json).version } catch { 'dev' }
New-Item -ItemType Directory -Force $labDir | Out-Null

function Write-Log([string]$text) {
    try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  mcp: {1}' -f (Get-Date), $text) } catch {}
}

function Send-Message($message) {
    [Console]::Out.Write(($message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    [Console]::Out.Flush()
}

$crypto = {
    function ConvertFrom-Hex([string]$h) {
        $b = New-Object byte[] ($h.Length / 2)
        for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
        , $b
    }
    function Get-Hmac([string]$keyHex, [string]$text) {
        $m = [Security.Cryptography.HMACSHA256]::new((ConvertFrom-Hex $keyHex))
        try { -join ($m.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) } finally { $m.Dispose() }
    }
    function Test-Equal([string]$a, [string]$b) {   # constant time for equal lengths
        if ($a.Length -ne $b.Length) { return $false }
        $d = 0; for ($i = 0; $i -lt $a.Length; $i++) { $d = $d -bor ([int]$a[$i] -bxor [int]$b[$i]) }
        $d -eq 0
    }
}
. $crypto

$tools = @(
    @{
        name        = 'set_state'
        description = 'Shows a state on the HumanNeeded puck (the desk status light on the user''s computer). LAB test build. Call it when the user asks to test the puck, or when a "HumanNeeded lab" hook message asks you to pair: then pass its pair code exactly.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                state = @{ type = 'string'; enum = $states }
                agent = @{ type = 'string' }
                pair  = @{ type = 'string'; description = 'The 64-character pairing code from a "HumanNeeded lab" hook message, exactly as given.' }
                tag   = @{ type = 'string'; description = 'A test label from the user''s test prompt; logged on the computer.' }
            }
            required   = @('state')
        }
    }
)

function Read-Pairs {
    $pairs = @{}
    try {
        $o = [IO.File]::ReadAllText($pairsFile) | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) { $pairs[$p.Name] = $p.Value }
    } catch {}
    $pairs
}

function Add-Pair([string]$channel, [string]$macKey) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    for ($try = 0; $try -lt 5; $try++) {
        try {
            $pairs = Read-Pairs
            $keep = [ordered]@{}
            $pairs.GetEnumerator() | Where-Object { [long]$_.Value.exp -gt $now -and $_.Key -ne $channel } |
                Sort-Object { [long]$_.Value.at } -Descending | Select-Object -First ($maxPairs - 1) |
                ForEach-Object { $keep[$_.Key] = $_.Value }
            $keep[$channel] = @{ k = $macKey; at = $now; exp = $now + $pairHours * 3600 }
            $tmp = "$pairsFile.tmp"
            [IO.File]::WriteAllText($tmp, ($keep | ConvertTo-Json -Compress), $utf8)
            Move-Item -Force $tmp $pairsFile
            return
        } catch { Start-Sleep -Milliseconds 100 }
    }
    throw 'could not save the pairing'
}

function Invoke-SetState($arguments) {
    $state = "$($arguments.state)".ToLower()
    if ($states -notcontains $state) { return @{ err = $true; text = "unknown state '$state'" } }
    $agent = if ($arguments.agent) { ("$($arguments.agent)" -replace '[^A-Za-z0-9_-]', '') } else { 'claude' }
    if ($agent.Length -gt 16) { $agent = $agent.Substring(0, 16) }
    $tag = "$($arguments.tag)" -replace '[^A-Za-z0-9_.-]', ''
    if ($tag.Length -gt 80) { $tag = $tag.Substring(0, 80) }
    $pair = "$($arguments.pair)".Trim().ToLower()
    $session = 'default'; $note = ''; $pairLog = '-'
    if ($pair) {
        if ($pair -notmatch '^[0-9a-f]{64}$') {
            Write-Log "call: set_state $state tag=$tag pair=INVALID (length $($pair.Length))"
            return @{ err = $true; text = 'HumanNeeded lab: the pair code must be exactly 64 hex characters, as given in the hook message.' }
        }
        $channel = (Get-Hmac $pair 'hn-lab-channel').Substring(0, 32)
        Add-Pair $channel (Get-Hmac $pair 'hn-lab-mac')
        $session = 'c-' + $channel.Substring(0, 16)
        $pairLog = 'channel ' + $channel.Substring(0, 8)
        $note = ' This cloud session is now paired with it.'
    }
    Write-Log "call: set_state $state agent=$agent tag=$tag pair=$pairLog"
    $null = & $hn $state $agent -SessionId $session 2>&1
    @{ err = $false; text = "HumanNeeded lab: the puck on $env:COMPUTERNAME shows $state.$note" }
}

# Listens on every paired channel (one WebSocket each) and verifies what arrives.
$listener = {
    param($ws, $hn, $logFile, $pairsFile, $states, $crypto)
    . ([ScriptBlock]::Create($crypto))
    function Log([string]$text) { try { Add-Content $logFile ('{0:yyyy-MM-dd HH:mm:ss}  relay: {1}' -f (Get-Date), $text) } catch {} }
    function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

    # One listener per PC user: other connector instances wait for the mutex.
    $mutex = New-Object Threading.Mutex $false, 'Local\HumanNeededLabRelay'
    while ($true) { try { if ($mutex.WaitOne(30000)) { break } } catch [Threading.AbandonedMutexException] { break } }
    Log 'listener running'

    $conns = @{}; $pairs = @{}; $stamp = -1
    while ($true) {
        $s = try { (Get-Item $pairsFile -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { 0 }
        if ($s -ne $stamp) {
            $stamp = $s; $pairs = @{}
            try { $o = [IO.File]::ReadAllText($pairsFile) | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $pairs[$p.Name] = $p.Value } } catch {}
        }
        $now = Now
        foreach ($ch in @($conns.Keys)) {
            if (-not $pairs.ContainsKey($ch) -or [long]$pairs[$ch].exp -lt $now) {
                try { $conns[$ch].sock.Dispose() } catch {}
                $conns.Remove($ch); Log "channel $($ch.Substring(0, 8)) closed (expired or replaced)"
            }
        }
        foreach ($ch in @($pairs.Keys)) {
            if (-not $conns.ContainsKey($ch) -and [long]$pairs[$ch].exp -gt $now -and $ch -match '^[0-9a-f]{32}$') {
                $conns[$ch] = @{ sock = $null; rx = $null; next = 0; backoff = 5; seen = @{}; mk = "$($pairs[$ch].k)"; text = ''
                    buf = (New-Object byte[] 4096); ping = $now }
            }
        }

        $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
        foreach ($ch in @($conns.Keys)) {
            $c = $conns[$ch]; $short = $ch.Substring(0, 8)
            if ($c.sock -and $c.sock.State -ne 'Open') {
                Log "channel $short disconnected ($($c.sock.State))"
                try { $c.sock.Dispose() } catch {}
                $c.sock = $null; $c.rx = $null; $c.next = $now + 2
            }
            if (-not $c.sock -and $now -ge $c.next) {
                $sock = New-Object Net.WebSockets.ClientWebSocket
                try {
                    $sock.ConnectAsync([Uri]("$($ws)?k=$ch"), [Threading.CancellationToken]::None).Wait(10000) | Out-Null
                    if ($sock.State -ne 'Open') { throw "state $($sock.State)" }
                    $c.sock = $sock; $c.backoff = 5; $c.ping = $now; $c.text = ''
                    Log "channel $short connected"
                } catch {
                    $sock.Dispose()
                    Log "channel $short connect failed: $($_.Exception.GetBaseException().Message); retry in $($c.backoff) s"
                    $c.next = $now + $c.backoff; $c.backoff = [Math]::Min($c.backoff * 2, 120)
                }
            }
            if ($c.sock -and -not $c.rx) { $c.rx = $c.sock.ReceiveAsync((New-Object ArraySegment[byte] (, $c.buf)), [Threading.CancellationToken]::None) }
            if ($c.rx) { $tasks.Add($c.rx) }
            if ($c.sock -and ($now - $c.ping) -ge 300) {   # API Gateway drops idle sockets after 10 min
                $b = [Text.Encoding]::UTF8.GetBytes('{"action":"ping"}')
                try { $c.sock.SendAsync((New-Object ArraySegment[byte] (, $b)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null } catch {}
                $c.ping = $now
            }
        }
        if ($tasks.Count) { [void][Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 1000) } else { Start-Sleep -Milliseconds 1000 }

        foreach ($ch in @($conns.Keys)) {
            $c = $conns[$ch]; $short = $ch.Substring(0, 8)
            if (-not $c.rx -or -not $c.rx.IsCompleted) { continue }
            $rx = $c.rx; $c.rx = $null
            if ($rx.IsFaulted -or $rx.IsCanceled) { try { $c.sock.Dispose() } catch {}; $c.sock = $null; $c.next = (Now) + 2; Log "channel $short receive failed"; continue }
            $r = $rx.Result
            if ($r.MessageType -eq 'Close') { try { $c.sock.Dispose() } catch {}; $c.sock = $null; $c.next = (Now) + 2; Log "channel $short closed by relay"; continue }
            $c.text += [Text.Encoding]::UTF8.GetString($c.buf, 0, $r.Count)
            if ($c.text.Length -gt 2048) { $c.text = ''; Log "channel $short REJECTED oversized message"; continue }
            if (-not $r.EndOfMessage) { continue }
            $raw = $c.text; $c.text = ''
            try {
                $m = $raw | ConvertFrom-Json
                $st = "$($m.s)"; $t = "$($m.t)"; $n = "$($m.n)"; $a = "$($m.a)"; $sig = "$($m.m)"
                if ("$($m.v)" -ne '1' -or $states -notcontains $st -or $t -notmatch '^\d{1,12}$' -or $n -notmatch '^[0-9a-f]{16}$' -or
                    $a -notmatch '^[A-Za-z0-9_-]{0,16}$' -or $sig -notmatch '^[0-9a-f]{64}$') { Log "channel $short REJECTED malformed message"; continue }
                $expect = Get-Hmac $c.mk "hn-lab-v1|$ch|$st|$t|$n|$a"
                if (-not (Test-Equal $expect $sig)) { Log "channel $short REJECTED bad signature ($st)"; continue }
                $now = Now; $age = $now - [long]$t
                if ([Math]::Abs($age) -gt 300) { Log "channel $short REJECTED stale ($age s old)"; continue }
                if ($c.seen.ContainsKey($n)) { Log "channel $short REJECTED replay ($st)"; continue }
                $c.seen[$n] = $now
                foreach ($k in @($c.seen.Keys)) { if ($now - $c.seen[$k] -gt 600) { $c.seen.Remove($k) } }
                if (-not $a) { $a = 'claude' }
                Log "channel $short verified $st $a ($age s)"
                $null = & $hn $st $a -SessionId ('c-' + $ch.Substring(0, 16)) 2>&1
            } catch { Log "channel $short REJECTED unreadable message" }
        }
    }
}

function Start-Listener {
    try {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($listener).AddArgument($relayWs).AddArgument($hn).AddArgument($logFile).AddArgument($pairsFile).AddArgument($states).AddArgument($crypto.ToString())
        $script:listenerHandle = $ps.BeginInvoke()
        $script:listenerPs = $ps
    } catch { Write-Log "could not start the listener: $_" }
}

Write-Log "started $version (pid $PID, $PSScriptRoot)"
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
                $result = @{ protocolVersion = $protocol; capabilities = @{ tools = @{} }; serverInfo = @{ name = 'humanneeded-lab'; version = $version } }
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
