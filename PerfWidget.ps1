#Requires -Version 5.1
<#
    此刻 · 性能监视  (PerfWidget)
    ------------------------------------------------------------
    透明浮层，实时显示 CPU / 内存 / GPU 占用。

    · 点「内存」行  打开本机电脑管家（自动识别厂商）
    · 点 CPU / GPU  打开任务管理器
    · 拖动          移动位置（自动记住）
    · 滚轮          调整不透明度
    · 右键          主题 / 尺寸 / 透明度 / 置顶 / 开机自启 / 退出

    依赖：Windows 自带 .NET (WPF)；GPU 读取用系统自带 nvidia-smi（N 卡）。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

trap {
    $detail = "ERROR: " + $_.Exception.Message + "`r`n" + $_.InvocationInfo.PositionMessage + "`r`n" + $_.ScriptStackTrace
    try { [System.IO.File]::AppendAllText((Join-Path $PSScriptRoot 'perf.log'), $detail + "`r`n", [System.Text.Encoding]::UTF8) } catch { }
    Write-Host $detail
    break
}

$script:Dir          = $PSScriptRoot
$script:SettingsPath = Join-Path $script:Dir 'perf-settings.json'
$script:LogPath      = Join-Path $script:Dir 'perf.log'
$script:GpuTmp       = Join-Path $env:TEMP 'perf_gpu.txt'
$script:GpuErr       = Join-Path $env:TEMP 'perf_gpu.err'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $script:LogPath -Value (('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)) -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------- 单实例
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DSH.PerfWidget')
try {
    if (-not $script:Mutex.WaitOne(0)) { return }
} catch [System.Threading.AbandonedMutexException] { } catch { }

# ---------------------------------------------------------------- 设置
$script:Config = [ordered]@{
    left     = $null
    top      = $null
    theme    = 'glass'
    scale    = 1.0
    opacity  = 1.0
    desktop  = $false
    showHint = $true
}

if (Test-Path -LiteralPath $script:SettingsPath) {
    try {
        $saved = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Config.Keys)) {
            $prop = $saved.PSObject.Properties[$key]
            if ($null -ne $prop -and $null -ne $prop.Value) { $script:Config[$key] = $prop.Value }
        }
    } catch { Write-Log "读取设置失败: $_" }
}

# ---------------------------------------------------------------- 系统信息
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PerfNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME { public uint dwLowDateTime; public uint dwHighDateTime; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    public static ulong ToUInt64(FILETIME ft) {
        return ((ulong)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    }
}
'@

$script:LastIdle   = $null
$script:LastKernel = $null
$script:LastUser   = $null

function Get-CpuPercent {
    $idle = New-Object PerfNative+FILETIME
    $kern = New-Object PerfNative+FILETIME
    $user = New-Object PerfNative+FILETIME
    if (-not [PerfNative]::GetSystemTimes([ref]$idle, [ref]$kern, [ref]$user)) { return $null }

    $i = [PerfNative]::ToUInt64($idle)
    $k = [PerfNative]::ToUInt64($kern)
    $u = [PerfNative]::ToUInt64($user)

    $pct = $null
    if ($null -ne $script:LastIdle) {
        $di = [double]($i - $script:LastIdle)
        $dk = [double]($k - $script:LastKernel)
        $du = [double]($u - $script:LastUser)
        $total = $dk + $du
        if ($total -gt 0) { $pct = (($total - $di) / $total) * 100.0 }
    }
    $script:LastIdle = $i
    $script:LastKernel = $k
    $script:LastUser = $u
    return $pct
}

function Get-MemoryInfo {
    $m = New-Object PerfNative+MEMORYSTATUSEX
    $m.dwLength = [System.Runtime.InteropServices.Marshal]::SizeOf($m)
    if (-not [PerfNative]::GlobalMemoryStatusEx([ref]$m)) { return $null }
    return @{
        Percent = [double]$m.dwMemoryLoad
        AvailGB = [math]::Round($m.ullAvailPhys / 1GB, 1)
        TotalGB = [math]::Round($m.ullTotalPhys / 1GB, 1)
    }
}

# ---------------------------------------------------------------- GPU（异步 nvidia-smi）
$script:NvSmi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$script:HasGpu = Test-Path -LiteralPath $script:NvSmi
$script:GpuProc = $null
$script:GpuValue = $null

function Start-GpuSample {
    if (-not $script:HasGpu -or $null -ne $script:GpuProc) { return }
    try {
        Remove-Item -LiteralPath $script:GpuTmp, $script:GpuErr -ErrorAction SilentlyContinue
        $script:GpuProc = Start-Process -FilePath $script:NvSmi `
            -ArgumentList @('--query-gpu=utilization.gpu', '--format=csv,noheader,nounits') `
            -RedirectStandardOutput $script:GpuTmp -RedirectStandardError $script:GpuErr `
            -WindowStyle Hidden -PassThru
    } catch {
        $script:HasGpu = $false
        Write-Log "nvidia-smi 启动失败: $_"
    }
}

function Read-GpuSample {
    if ($null -eq $script:GpuProc) { return }
    if (-not $script:GpuProc.HasExited) { return }

    try {
        if (Test-Path -LiteralPath $script:GpuTmp) {
            $raw = (Get-Content -LiteralPath $script:GpuTmp -Raw -ErrorAction SilentlyContinue)
            if ($raw) {
                $first = ($raw.Trim() -split "`r?`n")[0].Trim()
                if ($first -match '^\d+') { $script:GpuValue = [double]$first }
            }
        }
    } catch { }
    $script:GpuProc = $null
}

# ---------------------------------------------------------------- 界面
$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="PerfWindow"
        Title="此刻 · 性能监视"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="{x:Null}"
        Topmost="True"
        ShowInTaskbar="False"
        ShowActivated="False"
        ResizeMode="NoResize"
        SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True">
    <Grid x:Name="RootGrid" Margin="40">
        <Border x:Name="Card" CornerRadius="22" Background="#00000000" BorderBrush="#00000000" BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="30" ShadowDepth="8" Direction="270" Opacity="0" Color="#000000"/>
            </Border.Effect>
        </Border>
        <StackPanel x:Name="Content" Margin="22,14,22,14" MinWidth="210">
            <Grid Margin="3,0,3,6">
                <TextBlock x:Name="HeaderText" Text="性能"
                           FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#B3D9CFC0" VerticalAlignment="Center"/>
                <TextBlock x:Name="MemHint" Text=""
                           FontFamily="Microsoft YaHei UI" FontSize="10.5"
                           Foreground="#80D9CFC0" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>

            <Grid x:Name="RowCpu" Height="27" Background="Transparent">
                <TextBlock x:Name="CpuLabel" Text="CPU" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#B3D9CFC0" VerticalAlignment="Center" Margin="3,0,0,0"/>
                <Border x:Name="CpuTrack" Height="5" CornerRadius="3" Background="#26FFFFFF"
                        Margin="48,0,54,0" VerticalAlignment="Center">
                    <Border x:Name="CpuFill" Width="0" HorizontalAlignment="Left" CornerRadius="3" Background="#FFF2C87E"/>
                </Border>
                <TextBlock x:Name="CpuValue" Text="--" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#FFF2E8DC" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,3,0"/>
            </Grid>

            <Grid x:Name="RowMem" Height="27" Background="Transparent">
                <TextBlock x:Name="MemLabel" Text="内存" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#B3D9CFC0" VerticalAlignment="Center" Margin="3,0,0,0"/>
                <Border x:Name="MemTrack" Height="5" CornerRadius="3" Background="#26FFFFFF"
                        Margin="48,0,54,0" VerticalAlignment="Center">
                    <Border x:Name="MemFill" Width="0" HorizontalAlignment="Left" CornerRadius="3" Background="#FFF2C87E"/>
                </Border>
                <TextBlock x:Name="MemValue" Text="--" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#FFF2E8DC" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,3,0"/>
            </Grid>

            <Grid x:Name="RowGpu" Height="27" Background="Transparent">
                <TextBlock x:Name="GpuLabel" Text="GPU" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#B3D9CFC0" VerticalAlignment="Center" Margin="3,0,0,0"/>
                <Border x:Name="GpuTrack" Height="5" CornerRadius="3" Background="#26FFFFFF"
                        Margin="48,0,54,0" VerticalAlignment="Center">
                    <Border x:Name="GpuFill" Width="0" HorizontalAlignment="Left" CornerRadius="3" Background="#FFF2C87E"/>
                </Border>
                <TextBlock x:Name="GpuValue" Text="--" FontFamily="Microsoft YaHei UI" FontSize="12.5"
                           Foreground="#FFF2E8DC" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,3,0"/>
            </Grid>

            <TextBlock x:Name="HintText" Text="" FontFamily="Microsoft YaHei UI" FontSize="10.5"
                       Foreground="#80D9CFC0" Margin="3,6,3,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
    </Grid>
</Window>
'@

try {
    $xmlReader = New-Object System.Xml.XmlTextReader (New-Object System.IO.StringReader $script:Xaml)
    $Root = [Windows.Markup.XamlReader]::Load($xmlReader)
} catch {
    Write-Log "XAML 加载失败: $_"
    [Windows.MessageBox]::Show("界面加载失败：`n$_", '此刻 · 性能监视', 'OK', 'Error') | Out-Null
    exit 1
}

$RootGrid  = $Root.FindName('RootGrid')
$Card      = $Root.FindName('Card')
$CardShadow = $Card.Effect
$HeaderText = $Root.FindName('HeaderText')
$MemHint   = $Root.FindName('MemHint')
$RowCpu    = $Root.FindName('RowCpu')
$CpuTrack  = $Root.FindName('CpuTrack')
$CpuFill   = $Root.FindName('CpuFill')
$CpuValue  = $Root.FindName('CpuValue')
$RowMem    = $Root.FindName('RowMem')
$MemTrack  = $Root.FindName('MemTrack')
$MemFill   = $Root.FindName('MemFill')
$MemValue  = $Root.FindName('MemValue')
$RowGpu    = $Root.FindName('RowGpu')
$GpuTrack  = $Root.FindName('GpuTrack')
$GpuFill   = $Root.FindName('GpuFill')
$GpuValueText = $Root.FindName('GpuValue')
$HintText  = $Root.FindName('HintText')

# ---------------------------------------------------------------- 配色
$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Hex) {
    return [Windows.Media.SolidColorBrush]$script:BrushConverter.ConvertFromString($Hex)
}

$script:Themes = [ordered]@{
    dark = @{
        Label  = '深色玻璃'; Card = '#E6101319'; Border = '#26FFFFFF'; BorderHover = '#4DFFFFFF'
        Text = '#F0FFFFFF'; Muted = '#A6FFFFFF'; Accent = '#FF59C2FF'; Track = '#26FFFFFF'
        Shadow = 0.55; TextShadow = $false
    }
    light = @{
        Label  = '浅色玻璃'; Card = '#F2FFFFFF'; Border = '#1F000000'; BorderHover = '#42000000'
        Text = '#F20B1220'; Muted = '#990B1220'; Accent = '#FF0A84FF'; Track = '#22000000'
        Shadow = 0.16; TextShadow = $false
    }
    glass = @{
        Label  = '透明'; Card = '#00000000'; Border = '#00000000'; BorderHover = '#00000000'
        Text = '#FFF2E8DC'; Muted = '#B3D9CFC0'; Accent = '#FFF2C87E'; Track = '#24FFFFFF'
        Shadow = 0.0; TextShadow = $true
    }
}

$script:TextShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:TextShadow.BlurRadius  = 14
$script:TextShadow.ShadowDepth = 0
$script:TextShadow.Opacity     = 0.7
$script:TextShadow.Color       = [Windows.Media.Colors]::Black

$script:TextAll = @($HeaderText, $MemHint, $CpuValue, $MemValue, $GpuValueText, $HintText,
                    $Root.FindName('CpuLabel'), $Root.FindName('MemLabel'), $Root.FindName('GpuLabel'))

function Apply-Theme([string]$Name) {
    if (-not $script:Themes.Contains($Name)) { $Name = 'glass' }
    $t = $script:Themes[$Name]
    $script:Config.theme = $Name

    $Card.Background    = Get-Brush $t.Card
    $Card.BorderBrush   = Get-Brush $t.Border
    $CardShadow.Opacity = [double]$t.Shadow

    foreach ($tb in $script:TextAll) {
        if ($tb) { $tb.Foreground = Get-Brush $t.Muted }
    }
    $CpuValue.Foreground = Get-Brush $t.Text
    $MemValue.Foreground = Get-Brush $t.Text
    $GpuValueText.Foreground = Get-Brush $t.Text
    $HeaderText.Foreground = Get-Brush $t.Muted

    foreach ($track in @($CpuTrack, $MemTrack, $GpuTrack)) { $track.Background = Get-Brush $t.Track }
    $CpuFill.Background = Get-Brush $t.Accent
    $MemFill.Background = Get-Brush $t.Accent
    $GpuFill.Background = Get-Brush $t.Accent

    foreach ($tb in $script:TextAll) {
        if ($tb) { $tb.Effect = if ($t.TextShadow) { $script:TextShadow } else { $null } }
    }
}

function Apply-Scale([double]$Scale) {
    if ($Scale -lt 0.6 -or $Scale -gt 2.0) { $Scale = 1.0 }
    $script:Config.scale = $Scale
    $RootGrid.LayoutTransform = New-Object System.Windows.Media.ScaleTransform($Scale, $Scale)
    Refresh-Bars
}

function Get-FillBrush([double]$Pct) {
    $t = $script:Themes[$script:Config.theme]
    if ($Pct -ge 90) { return (Get-Brush '#FFFF7A6B') }
    if ($Pct -ge 75) { return (Get-Brush '#FFFFB86B') }
    return (Get-Brush $t.Accent)
}

function Set-Row($Pct, $Fill, $Value, $Track) {
    try { $p = [double]$Pct } catch {
        Write-Log ("Set-Row 参数异常: Pct=" + $Pct.GetType().Name + " Fill=" + $Fill.GetType().Name)
        return
    }
    $p = [math]::Max(0, [math]::Min(100, $p))
    $Value.Text = '{0:0}%' -f $p
    $w = $Track.ActualWidth * ($p / 100.0)
    if ([double]::IsNaN($w) -or $w -lt 0) { $w = 0 }
    $Fill.Width = $w
    $Fill.Background = Get-FillBrush $p
}

function Refresh-Bars {
    $w = $CpuTrack.ActualWidth
    if ($w -le 0) { return }
    foreach ($pair in @(
        @{ Fill = $CpuFill; Value = $CpuValue },
        @{ Fill = $MemFill; Value = $MemValue },
        @{ Fill = $GpuFill; Value = $GpuValueText }
    )) {
        $pctText = ($pair.Value.Text -replace '%', '')
        $pct = 0.0
        [void][double]::TryParse($pctText, [ref]$pct)
        if ($pct -gt 0) { $pair.Fill.Width = $w * ($pct / 100.0) }
    }
}

function Send-ToBottom {
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Root)).Handle
        if ($h -ne [IntPtr]::Zero) {
            [void][PerfNativeNs.PerfWin32]::SetWindowPos($h, [IntPtr](1), 0, 0, 0, 0, 0x0013)
        }
    } catch { }
}

function Set-DesktopMode([bool]$On) {
    $script:Config.desktop = $On
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($Root)).Handle
        if ($h -ne [IntPtr]::Zero) {
            $ex = [PerfNativeNs.PerfWin32]::GetWindowLong($h, -20)
            if ($On) { $ex = $ex -bor 0x08000000; $Root.Topmost = $false }
            else { $ex = $ex -band (-bnot 0x08000000); $Root.Topmost = $true }
            [void][PerfNativeNs.PerfWin32]::SetWindowLong($h, -20, $ex)
        }
    } catch { }
    if ($On) { Send-ToBottom }
}

function Save-Settings {
    try {
        if ($null -ne $Root -and -not [double]::IsNaN($Root.Left)) {
            $script:Config.left = [double]$Root.Left
            $script:Config.top  = [double]$Root.Top
        }
        $json = $script:Config | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log "保存设置失败: $_" }
}

function Restore-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $w  = if ($Root.ActualWidth  -gt 0) { $Root.ActualWidth }  else { 300 }
    $h  = if ($Root.ActualHeight -gt 0) { $Root.ActualHeight } else { 190 }

    $valid = $false
    if ($null -ne $script:Config.left -and $null -ne $script:Config.top) {
        $l = [double]$script:Config.left
        $t = [double]$script:Config.top
        if ($l -gt ($wa.Left - 60) -and $l -lt ($wa.Right - 90) -and
            $t -gt ($wa.Top - 60) -and $t -lt ($wa.Bottom - 70)) { $valid = $true }
    }
    if (-not $valid) {
        $l = $wa.Left + 70
        $t = $wa.Top + 180
    }
    $Root.Left = [double]$l
    $Root.Top  = [double]$t
}

# ---------------------------------------------------------------- 联想电脑管家
$script:PcManagerCache = $null

function Get-PcManagerInfo {
    if ($null -ne $script:PcManagerCache) { return $script:PcManagerCache }

    $result = @{ Name = ''; Exe = $null }

    # 1) 从卸载注册表里找常见电脑管家
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $patterns = '电脑管家|PC ?Manager|PCManager|QQPCMgr|安全卫士|HipsMain'

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $prop = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $prop -or [string]::IsNullOrWhiteSpace($prop.DisplayName)) { continue }
            if ($prop.DisplayName -notmatch $patterns) { continue }

            $exe = $null
            if ($prop.DisplayIcon) {
                $cand = ([string]$prop.DisplayIcon -split ',')[0].Trim('"')
                if ($cand -match '\.exe$' -and (Test-Path -LiteralPath $cand)) { $exe = $cand }
            }
            if (-not $exe -and $prop.InstallLocation) {
                foreach ($n in @('PcManager.exe', 'PCManager.exe', 'LenovoPcManager.exe', 'QQPCMgr.exe', '360Safe.exe', 'HipsMain.exe')) {
                    $cand = Join-Path ([string]$prop.InstallLocation) $n
                    if (Test-Path -LiteralPath $cand) { $exe = $cand; break }
                }
            }
            if (-not $exe) { continue }

            $name = [string]$prop.DisplayName
            if ($name -match '联想|Lenovo') { $name = '联想电脑管家' }
            elseif ($name -match '华为|Huawei') { $name = '华为电脑管家' }
            elseif ($name -match '荣耀|Honor') { $name = '荣耀电脑管家' }
            elseif ($name -match '小米|Xiaomi') { $name = '小米电脑管家' }
            elseif ($name -match '腾讯|QQ') { $name = '腾讯电脑管家' }
            elseif ($name -match '360') { $name = '360安全卫士' }
            elseif ($name -match '火绒') { $name = '火绒安全' }

            $result.Exe = $exe
            $result.Name = $name
            $script:PcManagerCache = $result
            return $result
        }
    }

    # 2) 常见固定路径兜底
    $known = @(
        @{ N = '联想电脑管家'; P = 'C:\Program Files (x86)\Lenovo\PCManager\LenovoPcManager.exe' },
        @{ N = '联想电脑管家'; P = 'C:\Program Files\Lenovo\PCManager\LenovoPcManager.exe' },
        @{ N = '华为电脑管家'; P = 'C:\Program Files\Huawei\PCManager\PCManager.exe' },
        @{ N = '荣耀电脑管家'; P = 'C:\Program Files\Honor\PCManager\PCManager.exe' },
        @{ N = '小米电脑管家'; P = 'C:\Program Files\Xiaomi\PCManager\PCManager.exe' }
    )
    foreach ($item in $known) {
        if (Test-Path -LiteralPath $item.P) {
            $result.Exe = $item.P
            $result.Name = $item.N
            break
        }
    }

    $script:PcManagerCache = $result
    return $result
}

function Open-PcManager {
    $info = Get-PcManagerInfo
    if ($info.Exe) {
        try { Start-Process -FilePath $info.Exe; return } catch { Write-Log "启动电脑管家失败: $_" }
    }
    Start-Process taskmgr.exe
}

$script:ManagerName = (Get-PcManagerInfo).Name

# ---------------------------------------------------------------- 开机自启
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '此刻性能监视.lnk'

function Test-Autostart { return (Test-Path -LiteralPath $script:StartupLnk) }

function Set-Autostart([bool]$Enable) {
    try {
        if ($Enable) {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($script:StartupLnk)
            $lnk.TargetPath       = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $lnk.Arguments        = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $script:Dir 'PerfWidget.ps1') + '"'
            $lnk.WorkingDirectory = $script:Dir
            $lnk.WindowStyle      = 7
            $lnk.Description      = '此刻 · 性能监视'
            $icon = Join-Path $script:Dir 'perf.ico'
            if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = $icon + ',0' }
            $lnk.Save()
        } elseif (Test-Path -LiteralPath $script:StartupLnk) {
            Remove-Item -LiteralPath $script:StartupLnk -Force
        }
        return $true
    } catch {
        Write-Log "设置开机自启失败: $_"
        return $false
    }
}

# ---------------------------------------------------------------- 右键菜单
$script:MenuShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:MenuShadow.BlurRadius  = 30
$script:MenuShadow.ShadowDepth = 10
$script:MenuShadow.Opacity     = 0.55
$script:MenuShadow.Color       = [Windows.Media.Colors]::Black

$script:MenuBorder = New-Object System.Windows.Controls.Border
$script:MenuBorder.Background      = Get-Brush '#F5161B24'
$script:MenuBorder.BorderBrush     = Get-Brush '#2EFFFFFF'
$script:MenuBorder.BorderThickness = New-Object System.Windows.Thickness(1)
$script:MenuBorder.CornerRadius    = New-Object System.Windows.CornerRadius(12)
$script:MenuBorder.Padding         = New-Object System.Windows.Thickness(6)
$script:MenuBorder.MinWidth        = 224
$script:MenuBorder.Effect          = $script:MenuShadow
$script:MenuBorder.Focusable       = $true

$script:MenuPanel = New-Object System.Windows.Controls.StackPanel
$script:MenuBorder.Child = $script:MenuPanel

$script:MenuHost = New-Object System.Windows.Controls.Grid
$script:MenuHost.Margin = New-Object System.Windows.Thickness(18)
[void]$script:MenuHost.Children.Add($script:MenuBorder)

$script:MenuWindow = New-Object System.Windows.Window
$script:MenuWindow.WindowStyle           = 'None'
$script:MenuWindow.AllowsTransparency    = $true
$script:MenuWindow.Background            = [Windows.Media.Brushes]::Transparent
$script:MenuWindow.ShowInTaskbar         = $false
$script:MenuWindow.ShowActivated         = $true
$script:MenuWindow.Topmost               = $true
$script:MenuWindow.ResizeMode            = 'NoResize'
$script:MenuWindow.SizeToContent         = 'WidthAndHeight'
$script:MenuWindow.WindowStartupLocation = 'Manual'
$script:MenuWindow.Content               = $script:MenuHost
$script:MenuWindow.Add_Deactivated({ try { $script:MenuWindow.Hide() } catch { } })

function Hide-Menu {
    try { if ($script:MenuWindow.IsVisible) { $script:MenuWindow.Hide() } } catch { }
}

$script:MenuTextBrush   = Get-Brush '#F2F6EFE3'
$script:MenuMutedBrush  = Get-Brush '#80EFE6D8'
$script:MenuAccentBrush = Get-Brush '#FFF2C87E'
$script:MenuHoverBrush  = Get-Brush '#1FFFFFFF'

function Add-MenuRow([string]$Text, [scriptblock]$OnClick, [bool]$Checked = $false) {
    $prefix = if ($Checked) { '✓  ' } else { '     ' }

    $row = New-Object System.Windows.Controls.Border
    $row.CornerRadius = New-Object System.Windows.CornerRadius(7)
    $row.Padding      = New-Object System.Windows.Thickness(9, 7, 12, 7)
    $row.Background   = [Windows.Media.Brushes]::Transparent
    $row.Cursor       = [System.Windows.Input.Cursors]::Hand
    $row.Tag          = $OnClick

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text       = $prefix + $Text
    $tb.FontFamily = 'Microsoft YaHei UI'
    $tb.FontSize   = 12.5
    $tb.Foreground = $script:MenuTextBrush
    $row.Child     = $tb

    $row.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
    $row.Add_MouseLeave({ param($s, $e) $s.Background = [Windows.Media.Brushes]::Transparent })
    $row.Add_MouseLeftButtonUp({ param($s, $e) & $s.Tag; Hide-Menu })

    [void]$script:MenuPanel.Children.Add($row)
}

function Add-MenuSeparator {
    $line = New-Object System.Windows.Controls.Border
    $line.Height     = 1
    $line.Margin     = New-Object System.Windows.Thickness(9, 5, 9, 5)
    $line.Background = Get-Brush '#26FFFFFF'
    [void]$script:MenuPanel.Children.Add($line)
}

function Add-MenuSegments([string]$Label, $Options, [scriptblock]$OnPick) {
    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = New-Object System.Windows.Thickness(9, 6, 9, 8)

    $lab = New-Object System.Windows.Controls.TextBlock
    $lab.Text       = $Label
    $lab.FontFamily = 'Microsoft YaHei UI'
    $lab.FontSize   = 10.5
    $lab.Foreground = $script:MenuMutedBrush
    $lab.Margin     = New-Object System.Windows.Thickness(0, 0, 0, 6)
    [void]$wrap.Children.Add($lab)

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'

    foreach ($opt in $Options) {
        $chip = New-Object System.Windows.Controls.Border
        $chip.CornerRadius = New-Object System.Windows.CornerRadius(5)
        $chip.Padding      = New-Object System.Windows.Thickness(8, 3, 8, 3)
        $chip.Margin       = New-Object System.Windows.Thickness(0, 0, 6, 0)
        $chip.Cursor       = [System.Windows.Input.Cursors]::Hand
        $chip.Tag          = @{ Action = $OnPick; Value = $opt.Value }

        if ($opt.Active) { $chip.Background = Get-Brush '#33F2C87E' } else { $chip.Background = Get-Brush '#12FFFFFF' }

        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text       = $opt.Label
        $tb.FontFamily = 'Microsoft YaHei UI'
        $tb.FontSize   = 11.5
        $tb.Foreground = if ($opt.Active) { $script:MenuAccentBrush } else { $script:MenuMutedBrush }
        $chip.Child = $tb

        if (-not $opt.Active) {
            $chip.Add_MouseEnter({ param($s, $e) $s.Background = $script:MenuHoverBrush })
            $chip.Add_MouseLeave({ param($s, $e) $s.Background = Get-Brush '#12FFFFFF' })
        }
        $chip.Add_MouseLeftButtonUp({ param($s, $e) $a = $s.Tag; & $a.Action $a.Value; Hide-Menu })

        [void]$row.Children.Add($chip)
    }

    [void]$wrap.Children.Add($row)
    [void]$script:MenuPanel.Children.Add($wrap)
}

function Build-ThemeOptions {
    $opts = @()
    foreach ($key in @('dark', 'light', 'glass')) {
        $opts += @{ Label = $script:Themes[$key].Label; Value = $key; Active = ($key -eq $script:Config.theme) }
    }
    return $opts
}

function Build-ScaleOptions {
    $current = [double]$script:Config.scale
    $opts = @()
    foreach ($pair in @(@('0.85', '小'), @('1.0', '标准'), @('1.15', '大'), @('1.35', '特大'))) {
        $val = [double]$pair[0]
        $opts += @{ Label = $pair[1]; Value = $val; Active = ([math]::Abs($val - $current) -lt 0.001) }
    }
    return $opts
}

function Build-OpacityOptions {
    $current = [double]$script:Config.opacity
    $opts = @()
    foreach ($v in @(1.0, 0.85, 0.7, 0.55)) {
        $opts += @{ Label = ('{0}%' -f [int]($v * 100)); Value = $v; Active = ([math]::Abs($v - $current) -lt 0.001) }
    }
    return $opts
}

function Show-Menu {
    $script:MenuPanel.Children.Clear()

    Add-MenuRow '立即刷新' { Update-Stats $true }
    Add-MenuRow $(if ($script:ManagerName) { '打开' + $script:ManagerName } else { '打开任务管理器' }) { Open-PcManager }
    Add-MenuRow '打开任务管理器' { Start-Process taskmgr.exe }

    Add-MenuSeparator

    Add-MenuSegments '外观主题' (Build-ThemeOptions) {
        param($value)
        Apply-Theme ([string]$value)
        Save-Settings
    }

    Add-MenuSegments '显示尺寸' (Build-ScaleOptions) {
        param($value)
        Apply-Scale ([double]$value)
        Save-Settings
    }

    Add-MenuSegments '不透明度' (Build-OpacityOptions) {
        param($value)
        $script:Config.opacity = [double]$value
        $Root.Opacity = [double]$value
        Save-Settings
    }

    Add-MenuSeparator

    Add-MenuRow '置于底层' {
        Set-DesktopMode (-not [bool]$script:Config.desktop)
        Save-Settings
    } ([bool]$script:Config.desktop)

    Add-MenuRow '开机自动启动' {
        $want = -not (Test-Autostart)
        if (-not (Set-Autostart $want)) {
            [Windows.MessageBox]::Show('无法写入开机启动项。可以把「此刻性能监视.lnk」的副本放进启动文件夹（Win+R 输入 shell:startup）。',
                '此刻 · 性能监视', 'OK', 'Warning') | Out-Null
        }
    } (Test-Autostart)

    Add-MenuRow '回到默认位置' {
        $script:Config.left = $null
        $script:Config.top  = $null
        Restore-Position
        Save-Settings
    }

    Add-MenuSeparator

    Add-MenuRow '退出' { $Root.Close() }

    $pos = [System.Windows.Input.Mouse]::GetPosition($Root)
    $script:MenuWindow.Left = $Root.Left + $pos.X
    $script:MenuWindow.Top  = $Root.Top + $pos.Y

    $script:MenuWindow.Show()
    $script:MenuWindow.Activate()
    $script:MenuBorder.Focus() | Out-Null

    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($script:MenuWindow.Left + $script:MenuWindow.ActualWidth - 36 -gt $wa.Right) {
        $script:MenuWindow.Left = $wa.Right - $script:MenuWindow.ActualWidth
    }
    if ($script:MenuWindow.Top + $script:MenuWindow.ActualHeight - 36 -gt $wa.Bottom) {
        $script:MenuWindow.Top = $wa.Bottom - $script:MenuWindow.ActualHeight
    }
}

$script:MenuBorder.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Escape') { Hide-Menu; $e.Handled = $true }
})

# ---------------------------------------------------------------- 采样与刷新
function Update-Stats([bool]$force = $false) {
    $cpu = Get-CpuPercent
    if ($null -ne $cpu) {
        $p = [math]::Max(0.0, [math]::Min(100.0, [double]$cpu))
        $CpuValue.Text = '{0:0}%' -f $p
        $CpuFill.Width = $CpuTrack.ActualWidth * $p / 100.0
        $CpuFill.Background = Get-FillBrush $p
    }

    $mem = Get-MemoryInfo
    if ($null -ne $mem) {
        $p = [math]::Max(0.0, [math]::Min(100.0, [double]$mem.Percent))
        $MemValue.Text = '{0:0}%' -f $p
        $MemFill.Width = $MemTrack.ActualWidth * $p / 100.0
        $MemFill.Background = Get-FillBrush $p
        $MemHint.Text = '可用 {0:0.0}G' -f $mem.AvailGB
    }

    Read-GpuSample
    if ($script:HasGpu) {
        if ($null -ne $script:GpuValue) {
            $p = [math]::Max(0.0, [math]::Min(100.0, [double]$script:GpuValue))
            $GpuValueText.Text = '{0:0}%' -f $p
            $GpuFill.Width = $GpuTrack.ActualWidth * $p / 100.0
            $GpuFill.Background = Get-FillBrush $p
        }
        Start-GpuSample
    } else {
        $RowGpu.Visibility = 'Collapsed'
    }
}

# ---------------------------------------------------------------- 交互
$Root.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    try {
        $Root.DragMove()
        if ([bool]$script:Config.desktop) { Send-ToBottom }
        Save-Settings
    } catch { }
})

$Root.Add_MouseRightButtonUp({
    param($sender, $e)
    Show-Menu
    $e.Handled = $true
})

$Root.Add_MouseWheel({
    param($sender, $e)
    $step = if ($e.Delta -gt 0) { 0.05 } else { -0.05 }
    $val  = [Math]::Round([Math]::Min(1.0, [Math]::Max(0.3, $Root.Opacity + $step)), 2)
    $Root.Opacity = $val
    $script:Config.opacity = $val
    Save-Settings
    $e.Handled = $true
})

$Root.Add_MouseEnter({ $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].BorderHover })
$Root.Add_MouseLeave({ $Card.BorderBrush = Get-Brush $script:Themes[$script:Config.theme].Border })

# 行交互：悬停提示 + 点击动作
$RowCpu.Add_MouseEnter({ $HintText.Text = '点击打开任务管理器' })
$RowCpu.Add_MouseLeave({ $HintText.Text = '' })
$RowCpu.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Process taskmgr.exe })

$RowMem.Add_MouseEnter({ $HintText.Text = if ($script:ManagerName) { '点击打开' + $script:ManagerName + '清理内存' } else { '点击打开任务管理器' } })
$RowMem.Add_MouseLeave({ $HintText.Text = '' })
$RowMem.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Open-PcManager })

$RowGpu.Add_MouseEnter({ $HintText.Text = '点击打开任务管理器' })
$RowGpu.Add_MouseLeave({ $HintText.Text = '' })
$RowGpu.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Process taskmgr.exe })

# 鼠标悬停时行背景轻微高亮；行内按下不触发窗口拖动
foreach ($row in @($RowCpu, $RowMem, $RowGpu)) {
    $row.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $row.Add_MouseEnter({ param($s, $e) $s.Background = Get-Brush $script:Themes[$script:Config.theme].BorderHover })
    $row.Add_MouseLeave({ param($s, $e) $s.Background = [Windows.Media.Brushes]::Transparent })
}

# 工具窗口 + 置顶
Add-Type -Namespace PerfNativeNs -Name PerfWin32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
'@

$Root.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
        $style  = [PerfNativeNs.PerfWin32]::GetWindowLong($helper.Handle, -20)
        [void][PerfNativeNs.PerfWin32]::SetWindowLong($helper.Handle, -20, ($style -bor 0x00000080))
        if ([bool]$script:Config.desktop) { Set-DesktopMode $true }
    } catch { Write-Log "设置工具窗口样式失败: $_" }
})

$Root.Add_Deactivated({
    if ([bool]$script:Config.desktop) { Send-ToBottom }
})

$Root.Add_Activated({
    if (-not [bool]$script:Config.desktop) {
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
            [void][PerfNativeNs.PerfWin32]::SetWindowPos($helper.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
        } catch { }
    }
})

# ---------------------------------------------------------------- 启动
Apply-Theme $script:Config.theme
Apply-Scale ([double]$script:Config.scale)
$Root.Opacity = [double]$script:Config.opacity
$Root.Topmost = -not [bool]$script:Config.desktop

$RootGrid.Opacity = 0.0

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(1500)
$script:Timer.Add_Tick({ try { Update-Stats } catch { Write-Log ("tick err line=" + $_.InvocationInfo.ScriptLineNumber + ": " + $_.Exception.Message) } })
$script:Timer.Start()

$Root.Add_Loaded({
    Restore-Position

    if (-not [bool]$script:Config.desktop) {
        try {
            $helper = New-Object System.Windows.Interop.WindowInteropHelper($Root)
            [void][PerfNativeNs.PerfWin32]::SetWindowPos($helper.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
        } catch { }
    }

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From     = 0.0
    $fade.To       = 1.0
    $fade.Duration = [System.Windows.Duration][TimeSpan]::FromMilliseconds(260)
    $RootGrid.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    try { Update-Stats $true } catch { Write-Log ("loaded err line=" + $_.InvocationInfo.ScriptLineNumber + ": " + $_.Exception.Message) }
})

$Root.Add_Closing({
    $script:Timer.Stop()
    Save-Settings
    try { $script:Mutex.ReleaseMutex() } catch { }
})

try {
    $script:App = New-Object System.Windows.Application
    $script:App.ShutdownMode = 'OnMainWindowClose'
    [void]$script:App.Run($Root)
} catch {
    Write-Log "运行失败: $_"
    [Windows.MessageBox]::Show("运行失败：`n$_", '此刻 · 性能监视', 'OK', 'Error') | Out-Null
} finally {
    try { $script:Mutex.ReleaseMutex() } catch { }
}
