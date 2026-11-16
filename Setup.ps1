# 一键准备：生成本地快捷方式（可选：开机自启）
# 用法：  powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
#         powershell -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1 -Autostart

[CmdletBinding()]
param(
    [switch]$Autostart
)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$argLine = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $dir 'PerfWidget.ps1') + '"'

function New-PerfShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($Path)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = $argLine
    $lnk.WorkingDirectory = $dir
    $lnk.WindowStyle      = 7
    $lnk.Description      = '此刻 · 性能监视'
    $icon = Join-Path $dir 'perf.ico'
    if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon + ',0' }
    $lnk.Save()
}

$localLnk = Join-Path $dir '此刻性能监视.lnk'
New-PerfShortcut $localLnk
"已生成快捷方式： $localLnk"

if ($Autostart) {
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '此刻性能监视.lnk'
    New-PerfShortcut $startupLnk
    "已加入开机自启： $startupLnk"
}

"双击「启动性能.bat」或上面生成的快捷方式即可运行。"
