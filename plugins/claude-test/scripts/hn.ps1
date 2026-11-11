# HumanNeeded host script for Windows (Windows PowerShell 5.1, no installs).
#
#   hn.ps1 <working|needs|done|idle|end> [agent]   reads hook JSON on stdin for session_id
#   & hn.ps1 <state> [agent] -SessionId <id>       (the connector, in its own process: no stdin)
#   hn.ps1 set <key> <value> | get <key|all> | mute <minutes> | test <state> | hello | status
#
# Always exits 0 within ~2 s and is silent for agent events, so a missing puck never
# disturbs the agent. Other commands print the puck's reply.
# Every run adds a line to %USERPROFILE%\.humanneeded\hn.log (for troubleshooting).

# -SessionId is by name only: "hn.ps1 working claude" must put "claude" in $Rest (the agent).
param([Parameter(Position = 0)][string]$Command = 'hello', [string]$SessionId = '', [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @())

$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
$budgetMs = 2000
$cacheFile = Join-Path $env:USERPROFILE '.humanneeded\port'
$logFile = Join-Path $env:USERPROFILE '.humanneeded\hn.log'
$states = 'working', 'needs', 'done', 'idle', 'end'

# COM ports of plugged-in pucks: USB devices whose serial number starts with "HN".
function Find-PuckPorts {
    $present = [IO.Ports.SerialPort]::GetPortNames()
    $usb = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
    foreach ($device in Get-ChildItem $usb) {
        foreach ($instance in Get-ChildItem $device.PSPath | Where-Object { $_.PSChildName -like 'HN*' }) {
            $prefix = (Get-ItemProperty $instance.PSPath).ParentIdPrefix
            if (-not $prefix) { continue }
            # The CDC serial interface is a child device named "<VID&PID>&MI_xx\<prefix>&xxxx".
            Get-ChildItem $usb | Where-Object { $_.PSChildName -like "$($device.PSChildName)&MI_*" } |
                ForEach-Object { Get-ChildItem $_.PSPath } |
                Where-Object { $_.PSChildName -like "$prefix&*" } |
                ForEach-Object { (Get-ItemProperty "$($_.PSPath)\Device Parameters" -ErrorAction SilentlyContinue).PortName } |
                Where-Object { $present -contains $_ }
        }
    }
}

# Sends one line and returns the reply line, or $null.
function Send-Line([string]$port, [string]$line) {
    $sp = New-Object IO.Ports.SerialPort $port, 115200
    $sp.NewLine = "`n"
    $sp.DtrEnable = $true
    $sp.ReadTimeout = [Math]::Max(100, $budgetMs - $clock.ElapsedMilliseconds)
    try {
        $sp.Open()
        $sp.WriteLine($line)
        return $sp.ReadLine().Trim()
    } finally {
        $sp.Dispose()
    }
}

# Tries the cached port, then re-discovers. Retries briefly if the port is busy
# (e.g. the settings page has it open).
function Send-ToPuck([string]$line) {
    $cached = if (Test-Path $cacheFile) { (Get-Content $cacheFile -Raw).Trim() }
    while ($clock.ElapsedMilliseconds -lt $budgetMs) {
        $ports = @($cached) + @(Find-PuckPorts) | Where-Object { $_ } | Select-Object -Unique
        if (-not $ports) { return $null }  # not plugged in
        foreach ($port in $ports) {
            try {
                $reply = Send-Line $port $line
                if ($port -ne $cached) {
                    New-Item -ItemType Directory -Force (Split-Path $cacheFile) | Out-Null
                    Set-Content $cacheFile $port
                }
                return $reply
            } catch {
                if ($port -eq $cached) { $cached = $null }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

# One line per run: time, what was sent, the reply, and where the script ran from
# (shows which app's plugin copy called it). Keeps the last 200 lines.
function Write-Log([string]$sent, [string]$reply) {
    try {
        New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null
        $entry = '{0:yyyy-MM-dd HH:mm:ss}  {1}  -> {2}  ({3} ms, {4})' -f (Get-Date), $sent,
            $(if ($reply) { $reply } else { 'no puck' }), $clock.ElapsedMilliseconds, $PSScriptRoot
        Add-Content $logFile $entry
        if ((Get-Item $logFile).Length -gt 64KB) {
            Set-Content $logFile (Get-Content $logFile | Select-Object -Last 200)
        }
    } catch {}
}

# session_id from the hook's JSON on stdin, or "default".
function Read-SessionId {
    if ($SessionId) { return ($SessionId -replace '\s', '') }
    if (-not [Console]::IsInputRedirected) { return 'default' }
    try {
        $id = ([Console]::In.ReadToEnd() | ConvertFrom-Json).session_id
        if ($id) { return ($id -replace '\s', '') }
    } catch {}
    return 'default'
}

try {
    $Command = $Command.ToLower()
    if ($states -contains $Command) {
        $agent = if ($Rest.Count -gt 0) { $Rest[0] } else { 'claude' }
        $line = "EV $Command $(Read-SessionId) $agent"
        Write-Log $line (Send-ToPuck $line)
    } else {
        $line = switch ($Command) {
            'set'    { "SET $($Rest[0]) $($Rest[1])" }
            'get'    { "GET $(if ($Rest.Count) { $Rest[0] } else { 'all' })" }
            'mute'   { "MUTE $($Rest[0])" }
            'test'   { "TEST $($Rest[0])" }
            'hello'  { 'HELLO' }
            'status' { 'STATUS' }
            'clear'  { 'CLEAR' }
            default  { $null }
        }
        if (-not $line) {
            'usage: hn <working|needs|done|idle|end> [agent] | set <k> <v> | get <k|all> | mute <min> | test <state> | hello | status | clear'
        } else {
            $reply = Send-ToPuck $line
            Write-Log $line $reply
            if ($reply) { $reply } else { 'HumanNeeded puck not found (is it plugged in?)' }
        }
    }
} catch {}
exit 0
