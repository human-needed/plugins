# Copies the host scripts into each plugin (plugins are installed as standalone folders,
# so they can't reference ../../host). Run after editing anything in host/.
$root = Split-Path $PSScriptRoot
foreach ($plugin in Get-ChildItem "$root\plugins" -Directory) {
    New-Item -ItemType Directory -Force "$($plugin.FullName)\scripts" | Out-Null
    Copy-Item "$PSScriptRoot\hn.ps1" "$($plugin.FullName)\scripts\" -Force
    if (Test-Path "$PSScriptRoot\hn.sh") { Copy-Item "$PSScriptRoot\hn.sh" "$($plugin.FullName)\scripts\" -Force }
}
