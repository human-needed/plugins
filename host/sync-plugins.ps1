# Copies the host scripts into each plugin and builds each plugin's skill from
# SKILL.template.md (plugins are installed as standalone folders, so they can't reference
# ../../host). Run after editing anything in host/.
$root = Split-Path $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding $false
$nl = "`n"
$plugins = @{
    'claude'     = @{
        files = 'hn.ps1', 'hn-mcp.ps1', 'hn.sh', 'relay.sh'
        run   = 'The puck is driven by `${CLAUDE_PLUGIN_ROOT}/scripts/hn.ps1`. Run it with:' + $nl + $nl + '```' + $nl +
                'powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/hn.ps1" <command> [args]' + $nl + '```'
    }
    'claude-mac' = @{
        files = 'hn.sh', 'relay.sh', 'hn-mcp.sh', 'hn-mcp.py'
        run   = 'The puck is driven by `${CLAUDE_PLUGIN_ROOT}/scripts/hn.sh`. Run it with:' + $nl + $nl + '```' + $nl +
                'bash "${CLAUDE_PLUGIN_ROOT}/scripts/hn.sh" <command> [args]' + $nl + '```'
    }
}
foreach ($name in $plugins.Keys) {
    $dir = Join-Path $root "plugins\$name"
    $p = $plugins[$name]
    New-Item -ItemType Directory -Force "$dir\scripts", "$dir\skills\humanneeded" | Out-Null
    foreach ($f in $p.files) { Copy-Item "$PSScriptRoot\$f" "$dir\scripts\" -Force }
    $skill = ([IO.File]::ReadAllText("$PSScriptRoot\SKILL.template.md")).Replace('{{RUN}}', $p.run)
    [IO.File]::WriteAllText("$dir\skills\humanneeded\SKILL.md", $skill, $utf8)
}
