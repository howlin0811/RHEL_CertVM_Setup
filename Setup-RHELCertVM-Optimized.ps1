<#
.SYNOPSIS
    為 Red Hat Enterprise Linux Certification 測試建立 Hyper-V VM 環境。

.DESCRIPTION
    流程：
        1. 從 ISO 目錄 (預設 C:\Users\Administrator\Downloads) 找出符合
           rhel-<X.Y>-x86_64-dvd*.iso 的檔案，由使用者挑選；檔名中的 X.Y
           即為要測試的 RHEL 版本 (例如 10.0、8.6)。
        2. 列出 host 上所有「wired」實體網路介面卡 (排除 Wi-Fi / wireless)，
           依 LinkSpeed 自動建立或沿用 VMSwitch：
              1 Gbps  → VMSwitch-1G
              10 Gbps → VMSwitch-10G
              25 Gbps → VMSwitch-25G
           至少需要 2 個不同速度的 Switch，否則中止。
        3. 決定 VM 檔案根目錄：預設 D:\Hyper-V；若 host 沒有 D: 槽，
           則在非系統磁碟中找一顆 offline / RAW 的磁碟、格式化為 NTFS
           並 assign drive letter = D，再繼續使用 D:\Hyper-V。
          4. 選擇 SUT VM 規格 profile；TestServer 預設固定使用 16 vCPU / 64 GB：
              Default - 16 vCPU / 64 GB
              Max     - RHEL 8  : 768  vCPU / 1152 GB
                        RHEL 9  : 1792 vCPU / 2688 GB
                        RHEL 10 : 1792 vCPU / 2688 GB
          5. 在 host 上掃描 offline 的 disk，由使用者明確挑選一顆，
              準備給 SUT 做 SCSI passthrough；預設不自動掛接。
        6. 經使用者確認後建立兩台 Gen2 VM：
              SUT        : RHEL_<X.Y>
                            - 2 張 NIC，分別繫結到「最快」與「第二快」的 Switch
                            - 額外新增一個 SCSI controller，掛接 passthrough disk
              TestServer : RHEL_<X.Y>_TestServer
                            - 1 張 NIC，繫結到「最快」的 Switch
           兩台 VM 皆掛上選定的 ISO，Secure Boot 套用
           MicrosoftUEFICertificateAuthority 模板 (RHEL 在 Gen2 需要)。

.NOTES
    - 需以系統管理員身分執行
    - 需要 Hyper-V 角色與 PowerShell 模組
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # 存放 RHEL ISO 的目錄
    [string]$IsoDirectory = 'C:\Users\Administrator\Downloads',

    # VM 檔案 (vhdx) 的存放根目錄；留空時自動：D: 存在 → D:\Hyper-V，否則讓使用者挑分割槽
    [string]$VmRoot       = '',

    # 每台 VM 的系統 VHDX 大小 (GB)
    [ValidateRange(1, 4096)]
    [int]   $VhdSizeGB    = 100,

    # 指定要掛給 SUT 的 offline disk number；未指定時會互動選擇，也可選擇不掛
    [int]   $PassthroughDiskNumber = -1,

    # 若指定，才更新 Hyper-V host 的預設 VM / VHD 路徑
    [switch]$UpdateHostDefaults,

    # 建立 VM 失敗時保留已產生的 VM / VHDX，方便手動除錯；預設會清理本次建立的殘件
    [switch]$KeepPartialOnFailure
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# 共用函式
# ============================================================================

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host " $Title"   -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Read-Choice {
    param(
        [Parameter(Mandatory)][string]   $Prompt,
        [Parameter(Mandatory)][string[]] $Valid,
        [string]                         $Default
    )
    do {
        $hint = if ($Default) { " [$Default]" } else { '' }
        $ans  = (Read-Host "$Prompt$hint").Trim()
        if ([string]::IsNullOrWhiteSpace($ans) -and $Default) { $ans = $Default }
        if ($Valid -notcontains $ans) {
            Write-Warning ("輸入不正確，請輸入: {0}" -f ($Valid -join ' / '))
        }
    } until ($Valid -contains $ans)
    return $ans
}

# 顯示腳本 banner
function Show-Banner {
    $banner = @'

  ____  _   _ _____ _        ____          _ __     ____  __
 |  _ \| | | | ____| |      / ___|___ _ __| |\ \   / /  \/  |
 | |_) | |_| |  _| | |     | |   / _ \ `__| | \ \ / /| |\/| |
 |  _ <|  _  | |___| |___  | |__|  __/ |  | |  \ V / | |  | |
 |_| \_\_| |_|_____|_____|  \____\___|_|  |_|   \_/  |_|  |_|

             RHEL Certification VM Setup for Hyper-V
             Create SUT + TestServer VM pair automatically

'@
    Write-Host $banner -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host ''
}

# 檢查 Hyper-V PowerShell 模組是否可用，不可用則詢問是否安裝 + 重啟
function Assert-HyperVAvailable {
    if (Get-Module -ListAvailable -Name Hyper-V) {
        return
    }

    Write-Warning 'Hyper-V PowerShell module was not found on this host.'

    $os       = Get-CimInstance Win32_OperatingSystem
    $isServer = $os.ProductType -ne 1   # 1 = Workstation，其余視為 Server / DC

    $install = Read-Choice -Prompt 'Install Hyper-V role/feature now? (Y/N)' `
                           -Valid  @('Y', 'N') -Default 'Y'
    if ($install -ne 'Y') {
        throw 'Hyper-V is required to run this script. Aborted by user.'
    }

    $rebootNeeded = $false
    if ($isServer) {
        Write-Host 'Installing Hyper-V role via Install-WindowsFeature (Server)...' -ForegroundColor Yellow
        $result       = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
        $rebootNeeded = $result.RestartNeeded -eq 'Yes'
    } else {
        Write-Host 'Enabling Hyper-V via Enable-WindowsOptionalFeature (Client)...' -ForegroundColor Yellow
        $result       = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        $rebootNeeded = [bool]$result.RestartNeeded
    }

    if (-not $rebootNeeded) {
        # 安裝完成且不需重啟—但 Hyper-V 這類 feature 幾乎一定要重啟才能用，依舊提醒
        Write-Warning 'Installer reported no restart required, but a reboot is strongly recommended before re-running this script.'
    }

    Write-Host ''
    Write-Host 'Hyper-V has been installed. The host MUST be restarted before this script can continue.' -ForegroundColor Yellow

    $reboot = Read-Choice -Prompt 'Restart this host now? (Y/N)' `
                          -Valid  @('Y', 'N') -Default 'Y'
    if ($reboot -eq 'Y') {
        Write-Host 'Restarting in 5 seconds... (press Ctrl+C to cancel)' -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
        # Restart-Computer 不一定立刻終止進程，進程被 Kill 前選擇退出
        exit 0
    } else {
        Write-Host 'Please restart the host manually, then re-run this script.' -ForegroundColor Yellow
        exit 0
    }
}

# ============================================================================
# Step 1: 從 ISO 檔名推導 RHEL 版本
# ============================================================================

function Select-RhelIso {
    Write-Section 'Step 1 - Select RHEL ISO'

    if (-not (Test-Path -Path $IsoDirectory)) {
        throw "ISO directory not found: $IsoDirectory"
    }

    # 比對 rhel-<major>.<minor>-x86_64-dvd*.iso，例如 rhel-10.0-x86_64-dvd.iso
    $pattern = '^rhel-(?<major>\d+)\.(?<minor>\d+)-x86_64-dvd.*\.iso$'

    $candidates = @(
        Get-ChildItem -Path $IsoDirectory -File -Filter '*.iso' |
            Where-Object { $_.Name -match $pattern } |
            ForEach-Object {
                $null = $_.Name -match $pattern
                [pscustomobject]@{
                    FileName = $_.Name
                    FullPath = $_.FullName
                    Major    = [int]$Matches.major
                    Minor    = [int]$Matches.minor
                    Version  = "$($Matches.major).$($Matches.minor)"
                }
            } | Sort-Object Major, Minor
    )

    if ($candidates.Count -eq 0) {
        throw "No matching 'rhel-<X.Y>-x86_64-dvd*.iso' file found in '$IsoDirectory'."
    }

    Write-Host "Found $($candidates.Count) RHEL ISO(s) in '$IsoDirectory':" -ForegroundColor Green
    $i = 0
    $rows = $candidates | ForEach-Object {
        $i++
        [pscustomobject]@{ Index = "[$i]"; Version = $_.Version; FileName = $_.FileName }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    $validIdx = 1..$candidates.Count | ForEach-Object { "$_" }
    $choice   = Read-Choice -Prompt 'Select ISO by index number (e.g. 1)' -Valid $validIdx
    $selected = $candidates[[int]$choice - 1]

    Write-Host "Selected ISO: $($selected.FileName)  (RHEL $($selected.Version))" -ForegroundColor Green
    return $selected
}

# ============================================================================
# Step 2: 依實體網卡 LinkSpeed 建立 / 沿用 VMSwitch (僅 wired)
# ============================================================================

# 把 LinkSpeed (例如 "1 Gbps" / "10 Gbps" / "25 Gbps" / "100 Mbps") 轉成
# Switch 命名後綴 (1G / 10G / 25G / 100M)
function Get-LinkSpeedLabel {
    param([Parameter(Mandatory)][string]$LinkSpeed)

    if ($LinkSpeed -match '^\s*(?<num>\d+(?:\.\d+)?)\s*(?<unit>[GMK])bps') {
        $num  = [double]$Matches.num
        switch ($Matches.unit) {
            'G' {
                $label = if ([math]::Abs($num - [math]::Round($num)) -lt 0.001) {
                    '{0:0}G' -f $num
                } else {
                    '{0:0.#}G' -f $num
                }
                return ($label -replace '\.', '_')
            }
            'M' {
                if ($num -ge 1000) { return ((('{0:0.#}G' -f ($num / 1000)) -replace '\.', '_')) }
                else               { return ('{0:0}M' -f $num) }
            }
            'K' { return ('{0:0}K' -f $num) }
        }
    }
    return ($LinkSpeed -replace '\s', '')
}

# 把 LinkSpeed 轉成 Mbps 整數值供排序用
function Get-LinkSpeedMbps {
    param([Parameter(Mandatory)][string]$LinkSpeed)
    if ($LinkSpeed -match '^\s*(?<num>\d+(?:\.\d+)?)\s*(?<unit>[GMK])bps') {
        $num = [double]$Matches.num
        switch ($Matches.unit) {
            'G' { return [int64]($num * 1000) }
            'M' { return [int64]$num }
            'K' { return [int64]($num / 1000) }
        }
    }
    return 0
}

function Initialize-CertVmSwitches {
    Write-Section 'Step 2 - Setup VMSwitches (wired only, named by link speed)'

    # MediaType '802.3' 才是 wired ethernet；Wi-Fi 是 'Native 802.11'
    $adapters = @(
        Get-NetAdapter -Physical |
            Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' }
    )
    if ($adapters.Count -eq 0) {
        throw 'No wired physical network adapter with Status=Up was found.'
    }

    $adapterRows = $adapters | ForEach-Object {
        [pscustomobject]@{
            Name        = $_.Name
            LinkSpeed   = $_.LinkSpeed
            SpeedLabel  = Get-LinkSpeedLabel -LinkSpeed $_.LinkSpeed
            SpeedMbps   = Get-LinkSpeedMbps  -LinkSpeed $_.LinkSpeed
            Description = $_.InterfaceDescription
        }
    }

    Write-Host 'Wired physical adapters (Status=Up):' -ForegroundColor Green
    $adapterRows | Select-Object Name, LinkSpeed, SpeedLabel, Description |
        Format-Table -AutoSize | Out-String | Write-Host

    # 同速度只建一個 Switch，取該速度下的第一張網卡
    $groups = $adapterRows |
        Group-Object SpeedLabel |
        ForEach-Object {
            $first = $_.Group | Select-Object -First 1
            [pscustomobject]@{
                SwitchName = "VMSwitch-$($first.SpeedLabel)"
                SpeedLabel = $first.SpeedLabel
                SpeedMbps  = $first.SpeedMbps
                Adapter    = $first.Name
            }
        } | Sort-Object SpeedMbps -Descending

    if ($groups.Count -lt 2) {
        throw "SUT requires NICs on 2 DIFFERENT VMSwitches, but only $($groups.Count) distinct link speed(s) detected. Please make sure the host has at least 2 wired NICs of different speeds connected."
    }

    $switchPlan = foreach ($g in $groups) {
        $existing = Get-VMSwitch -Name $g.SwitchName -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Action     = if ($existing) { 'Reuse' } else { 'Create' }
            SwitchName = $g.SwitchName
            SpeedLabel = $g.SpeedLabel
            SpeedMbps  = $g.SpeedMbps
            Adapter    = $g.Adapter
            SwitchType = if ($existing) { $existing.SwitchType } else { 'External' }
        }
    }

    Write-Host ''
    Write-Host 'VMSwitch plan:' -ForegroundColor Green
    $switchPlan | Select-Object Action, SwitchName, SpeedLabel, Adapter, SwitchType |
        Format-Table -AutoSize | Out-String | Write-Host

    $createCount = @($switchPlan | Where-Object Action -EQ 'Create').Count
    if ($createCount -gt 0) {
        Write-Warning 'Creating External VMSwitches can briefly interrupt host network connectivity, including RDP/WinRM.'
        $confirmSwitch = Read-Choice -Prompt 'Proceed to create missing VMSwitch(es)? (Y/N)' `
                                      -Valid  @('Y', 'N') -Default 'N'
        if ($confirmSwitch -ne 'Y') {
            throw 'Aborted by user before creating VMSwitches.'
        }
    }

    # 逐一建立或沿用
    $switches = foreach ($g in $groups) {
        $existing = Get-VMSwitch -Name $g.SwitchName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.SwitchType -ne 'External') {
                throw "VMSwitch '$($g.SwitchName)' already exists but is '$($existing.SwitchType)', not External. Rename or remove it before re-running."
            }
            Write-Host "VMSwitch '$($g.SwitchName)' already exists. Reusing." -ForegroundColor Green
            $sw = $existing
        } else {
            Write-Host "Creating new External VMSwitch '$($g.SwitchName)' bound to '$($g.Adapter)'..." -ForegroundColor Green
            $sw = New-VMSwitch -Name              $g.SwitchName `
                               -NetAdapterName    $g.Adapter `
                               -AllowManagementOS $true
        }
        [pscustomobject]@{
            Name       = $sw.Name
            SpeedLabel = $g.SpeedLabel
            SpeedMbps  = $g.SpeedMbps
            Adapter    = $g.Adapter
        }
    }

    Write-Host ''
    Write-Host 'Final VMSwitch list (sorted by link speed desc):' -ForegroundColor Green
    $switches | Select-Object Name, SpeedLabel, Adapter |
        Format-Table -AutoSize | Out-String | Write-Host

    return $switches
}

# ============================================================================
# Step 3: 解析 VHD 根目錄
# ============================================================================

function Resolve-VmRoot {
    param([string]$Preferred = '')

    Write-Section 'Step 3 - Resolve VM root folder'

    # 1) 使用者明確指定 -VmRoot
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        if (-not (Test-Path $Preferred)) {
            New-Item -ItemType Directory -Path $Preferred -Force | Out-Null
        }
        Write-Host "Using user-specified VmRoot: $Preferred" -ForegroundColor Green
        return $Preferred
    }

    # 2) 預設 D:\Hyper-V (若 D: 存在)
    if (Test-Path 'D:\') {
        $path = 'D:\Hyper-V'
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        Write-Host "Using default VmRoot: $path" -ForegroundColor Green
        return $path
    }

    # 3) 沒有 D: → 只列出「非系統 / 非開機」且 offline 或 RAW 的磁碟，讓使用者挑一顆來格式化成 D:
    Write-Host 'D: drive not found. Looking for non-system disks to provision as D:...' -ForegroundColor Yellow

    # 候選條件收窄：不是系統 / 開機磁碟，且必須是 offline 或 RAW，避免誤清掉已在線使用的資料碟。
    $candidates = @(
        Get-Disk |
            Where-Object {
                $_.IsBoot -ne $true -and
                $_.IsSystem -ne $true -and
                ($_.IsOffline -eq $true -or $_.PartitionStyle -eq 'RAW')
            } |
            Sort-Object Number
    )
    if ($candidates.Count -eq 0) {
        throw 'No safe disk candidate found for D:. Add an offline/RAW non-system disk and re-run, or pass -VmRoot explicitly.'
    }

    Write-Host 'Available offline/RAW non-system disks:' -ForegroundColor Green
    $rows = for ($i = 0; $i -lt $candidates.Count; $i++) {
        $d = $candidates[$i]
        [pscustomobject]@{
            Index             = "[$i]"
            Number            = $d.Number
            FriendlyName      = $d.FriendlyName
            SizeGB            = [math]::Round($d.Size / 1GB, 1)
            PartitionStyle    = $d.PartitionStyle
            OperationalStatus = $d.OperationalStatus
            BusType           = $d.BusType
            IsOffline         = $d.IsOffline
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    # 讓使用者用 index 挑，或輸入 N 中止
    $validChoices = @('N') + (0..($candidates.Count - 1) | ForEach-Object { "$_" })
    $pick = Read-Choice -Prompt 'Pick a disk index to format as D: (or N to abort)' `
                        -Valid  $validChoices -Default 'N'
    if ($pick -eq 'N') {
        throw 'Aborted by user.'
    }
    $target = $candidates[[int]$pick]

    Write-Warning ("Disk {0} ({1}, {2:N1} GB, {3}) will be formatted as NTFS and assigned drive letter D:" -f `
                    $target.Number, $target.FriendlyName, ($target.Size / 1GB), $target.PartitionStyle)
    Write-Warning "ALL EXISTING DATA on Disk $($target.Number) WILL BE LOST."

    $confirm = Read-Choice -Prompt 'Proceed to format this disk as D:? (Y/N)' `
                           -Valid  @('Y', 'N') -Default 'N'
    if ($confirm -ne 'Y') {
        throw 'Aborted by user.'
    }

    $formatToken = "FORMAT DISK $($target.Number)"
    $typedToken  = Read-Host "Type '$formatToken' to confirm destructive formatting"
    if ($typedToken -cne $formatToken) {
        throw 'Confirmation token did not match. Aborted before touching disk data.'
    }

    # 帶上線 + 解唯讀
    if ($target.IsOffline)  { Set-Disk -Number $target.Number -IsOffline  $false }
    if ($target.IsReadOnly) { Set-Disk -Number $target.Number -IsReadOnly $false }

    # 若已有分割，先清空才能重新 Initialize
    $current = Get-Disk -Number $target.Number
    if ($current.PartitionStyle -ne 'RAW') {
        Write-Host "Clearing existing partition table on Disk $($target.Number)..." -ForegroundColor Yellow
        Clear-Disk -Number $target.Number -RemoveData -RemoveOEM -Confirm:$false
    }

    Write-Host "Initializing Disk $($target.Number) as GPT..." -ForegroundColor Green
    Initialize-Disk -Number $target.Number -PartitionStyle GPT | Out-Null

    Write-Host 'Creating partition and formatting as NTFS, drive letter = D ...' -ForegroundColor Green
    New-Partition -DiskNumber $target.Number -UseMaximumSize -DriveLetter D |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'Hyper-V' -Confirm:$false | Out-Null

    $path = 'D:\Hyper-V'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Write-Host "Provisioned D: from Disk $($target.Number). Using VmRoot: $path" -ForegroundColor Green
    return $path
}

# ============================================================================
# Step 4: 選擇 SUT VM 規格 profile (Default / Max)
# ============================================================================

function Get-VmProfile {
    param([Parameter(Mandatory)][int]$RhelMajor)

    Write-Section 'Step 4 - Select SUT VM profile (CPU / Memory)'

    # 各 RHEL 主版本對應的 Max profile (CPU cores / Memory GB = cores * 1.5)
    $maxByVersion = @{
        8  = [pscustomobject]@{ Cpu = 768;  MemGB = [int64](768  * 1.5) }
        9  = [pscustomobject]@{ Cpu = 1792; MemGB = [int64](1792 * 1.5) }
        10 = [pscustomobject]@{ Cpu = 1792; MemGB = [int64](1792 * 1.5) }
    }

    $default = [pscustomobject]@{ Cpu = 16; MemGB = 64 }
    $max     = $maxByVersion[$RhelMajor]

    Write-Host 'Available SUT profiles:' -ForegroundColor Green
    Write-Host ("  (D) Default : {0,5} vCPU / {1,5} GB" -f $default.Cpu, $default.MemGB)
    if ($max) {
        Write-Host ("  (M) Max     : {0,5} vCPU / {1,5} GB   (RHEL {2} maximum)" -f $max.Cpu, $max.MemGB, $RhelMajor)
    } else {
        Write-Warning "No Max profile defined for RHEL $RhelMajor; only Default will be offered."
    }

    $valid  = if ($max) { @('D', 'M') } else { @('D') }
    $choice = Read-Choice -Prompt 'Select SUT profile' -Valid $valid -Default 'D'

    $picked = if ($choice -eq 'M' -and $max) { $max } else { $default }
    Write-Host ("Selected SUT profile: {0} vCPU / {1} GB" -f $picked.Cpu, $picked.MemGB) -ForegroundColor Cyan
    return $picked
}

# ============================================================================
# Step 5: 選擇 host 上的 offline disk (給 SUT 做 passthrough)
# ============================================================================

function Select-PassthroughDisk {
    param([int]$DiskNumber = -1)

    Write-Section 'Step 5 - Select offline disk for SUT passthrough'

    if ($DiskNumber -ge 0) {
        $selected = Get-Disk -Number $DiskNumber -ErrorAction Stop
        if ($selected.IsBoot -eq $true -or $selected.IsSystem -eq $true) {
            throw "Disk $DiskNumber is a boot/system disk and cannot be used as passthrough."
        }
        if ($selected.IsOffline -ne $true) {
            throw "Disk $DiskNumber is not offline. Put it offline first, or omit -PassthroughDiskNumber to skip/choose interactively."
        }

        Write-Host ("Using requested passthrough disk: Disk {0}  ({1}, {2:N1} GB)" -f `
                    $selected.Number, $selected.FriendlyName, ($selected.Size / 1GB)) -ForegroundColor Cyan
        return $selected
    }

    $offline = @(
        Get-Disk |
            Where-Object { $_.IsOffline -eq $true -and $_.IsBoot -ne $true -and $_.IsSystem -ne $true } |
            Sort-Object Number
    )
    if ($offline.Count -eq 0) {
        Write-Warning 'No offline disk found on the host. SUT will be created WITHOUT a passthrough disk.'
        return $null
    }

    Write-Host 'Offline disks on host:' -ForegroundColor Green
    $rows = for ($i = 0; $i -lt $offline.Count; $i++) {
        $d = $offline[$i]
        [pscustomobject]@{
            Index             = "[$i]"
            Number            = $d.Number
            FriendlyName      = $d.FriendlyName
            SizeGB            = [math]::Round($d.Size / 1GB, 1)
            PartitionStyle    = $d.PartitionStyle
            OperationalStatus = $d.OperationalStatus
            BusType           = $d.BusType
        }
    }
    $rows |
        Format-Table -AutoSize | Out-String | Write-Host

    $validChoices = @('N') + (0..($offline.Count - 1) | ForEach-Object { "$_" })
    $pick = Read-Choice -Prompt 'Pick a disk index for SUT passthrough (or N for none)' `
                        -Valid  $validChoices -Default 'N'
    if ($pick -eq 'N') {
        Write-Warning 'SUT will be created WITHOUT a passthrough disk.'
        return $null
    }

    $selected = $offline[[int]$pick]
    Write-Warning ("Disk {0} ({1}, {2:N1} GB) will be attached directly to SUT as passthrough." -f `
                    $selected.Number, $selected.FriendlyName, ($selected.Size / 1GB))
    $confirm = Read-Choice -Prompt 'Proceed with this passthrough disk? (Y/N)' `
                           -Valid  @('Y', 'N') -Default 'N'
    if ($confirm -ne 'Y') {
        Write-Warning 'SUT will be created WITHOUT a passthrough disk.'
        return $null
    }

    return $selected
}

# ============================================================================
# Step 6: 建立單一台 VM (供主流程呼叫兩次)
# ============================================================================

function New-CertVm {
    param(
        [Parameter(Mandatory)][string]   $Name,
        [Parameter(Mandatory)][string]   $VmRoot,
        [Parameter(Mandatory)][string]   $IsoPath,
        [Parameter(Mandatory)][int]      $ProcessorCount,
        [Parameter(Mandatory)][int64]    $MemoryGB,
        [Parameter(Mandatory)][int]      $VhdSizeGB,
        [Parameter(Mandatory)][string[]] $SwitchNames,
        [switch]                         $KeepPartialOnFailure
    )

    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        throw "VM '$Name' already exists. Remove it manually before re-running."
    }

    $vmDir   = Join-Path $VmRoot $Name
    $vhdPath = Join-Path $vmDir "$Name.vhdx"
    $createdVmDir = $false
    $createdVhd   = $false

    if (-not (Test-Path $vmDir)) {
        New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
        $createdVmDir = $true
    }
    if (Test-Path $vhdPath) {
        throw "VHDX already exists at '$vhdPath'."
    }

    try {
        Write-Host "Creating VHDX: $vhdPath ($VhdSizeGB GB, dynamic)" -ForegroundColor Green
        New-VHD -Path $vhdPath -SizeBytes ($VhdSizeGB * 1GB) -Dynamic | Out-Null
        $createdVhd = $true

        Write-Host "Creating VM: $Name  ($ProcessorCount vCPU / $MemoryGB GB RAM)" -ForegroundColor Green
        $vm = New-VM -Name               $Name `
                     -Generation         2 `
                     -MemoryStartupBytes ($MemoryGB * 1GB) `
                     -VHDPath            $vhdPath `
                     -Path               $vmDir `
                     -SwitchName         $SwitchNames[0]

        Set-VMProcessor -VM $vm -Count $ProcessorCount
        # Cert 測試通常使用靜態記憶體
        Set-VMMemory    -VM $vm -DynamicMemoryEnabled $false

        # New-VM 已建好第一張 NIC (繫結到 SwitchNames[0])，後續 NIC 用 Add-VMNetworkAdapter
        for ($i = 1; $i -lt $SwitchNames.Count; $i++) {
            Add-VMNetworkAdapter -VMName $Name -SwitchName $SwitchNames[$i] | Out-Null
            Write-Host "  + extra NIC bound to '$($SwitchNames[$i])'" -ForegroundColor DarkGray
        }

        # 掛上 ISO 並設為第一順位開機
        $dvd = Add-VMDvdDrive -VMName $Name -Path $IsoPath -Passthru
        Set-VMFirmware -VM $vm -FirstBootDevice $dvd

        # RHEL 在 Gen2 需要 MicrosoftUEFICertificateAuthority 模板
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'

        return (Get-VM -Name $Name)
    } catch {
        if (-not $KeepPartialOnFailure) {
            Write-Warning "Failed to create VM '$Name'. Cleaning up VM/VHDX created by this run."
            $partialVm = Get-VM -Name $Name -ErrorAction SilentlyContinue
            if ($partialVm) {
                Remove-VM -VM $partialVm -Force -ErrorAction SilentlyContinue
            }
            if ($createdVhd -and (Test-Path $vhdPath)) {
                Remove-Item -Path $vhdPath -Force -ErrorAction SilentlyContinue
            }
            if ($createdVmDir -and (Test-Path $vmDir)) {
                $remaining = @(Get-ChildItem -Path $vmDir -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) {
                    Remove-Item -Path $vmDir -Force -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Warning "Failed to create VM '$Name'. Partial VM/VHDX artifacts were kept because -KeepPartialOnFailure was specified."
        }
        throw
    }
}

# 給 SUT 加上額外的 SCSI controller 並掛接 passthrough disk
function Add-SutPassthroughDisk {
    param(
        [Parameter(Mandatory)][string] $VMName,
        [Parameter(Mandatory)]         $Disk    # 來自 Get-Disk
    )

    Write-Host "  + adding extra SCSI controller on '$VMName'" -ForegroundColor DarkGray
    Add-VMScsiController -VMName $VMName

    # 取剛新增的 SCSI controller (number 最大那個)
    $ctrl = Get-VMScsiController -VMName $VMName |
                Sort-Object ControllerNumber | Select-Object -Last 1

    Write-Host ("  + attaching passthrough Disk {0} to SCSI ctrl #{1}" -f $Disk.Number, $ctrl.ControllerNumber) -ForegroundColor DarkGray
    Add-VMHardDiskDrive -VMName            $VMName `
                        -ControllerType    SCSI `
                        -ControllerNumber  $ctrl.ControllerNumber `
                        -ControllerLocation 0 `
                        -DiskNumber        $Disk.Number | Out-Null
}

# ============================================================================
# 主流程
# ============================================================================

Clear-Host
Show-Banner

try {
    Assert-HyperVAvailable

    $iso       = Select-RhelIso
    $switches  = Initialize-CertVmSwitches
    $vmRootDir = Resolve-VmRoot -Preferred $VmRoot

    if ($UpdateHostDefaults) {
        # Opt-in only: this changes Hyper-V host-wide defaults, not just the VMs created by this script.
        try {
            Set-VMHost -VirtualMachinePath  $vmRootDir `
                       -VirtualHardDiskPath $vmRootDir -ErrorAction Stop
            Write-Host "Hyper-V host default paths set to: $vmRootDir" -ForegroundColor Green
        } catch {
            Write-Warning ("Failed to update Hyper-V host default paths: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Host 'Leaving Hyper-V host default VM/VHD paths unchanged. Use -UpdateHostDefaults to change them.' -ForegroundColor DarkGray
    }

    $sutProfile        = Get-VmProfile -RhelMajor $iso.Major
    $testServerProfile = [pscustomobject]@{ Cpu = 16; MemGB = 64 }
    $offDisk           = Select-PassthroughDisk -DiskNumber $PassthroughDiskNumber

    # SUT 用「最快」與「第二快」兩個 Switch；TestServer 用「最快」
    $fastest    = $switches[0]
    $secondFast = $switches[1]

    $sutName = "RHEL_$($iso.Version)"
    $tsName  = "RHEL_$($iso.Version)_TestServer"

    Write-Section 'Summary'
    $summary = [ordered]@{
        RhelVersion        = $iso.Version
        IsoPath            = $iso.FullPath
        VmRoot             = $vmRootDir
        SutProfile         = "$($sutProfile.Cpu) vCPU / $($sutProfile.MemGB) GB"
        TestServerProfile  = "$($testServerProfile.Cpu) vCPU / $($testServerProfile.MemGB) GB"
        VhdSizeGB          = $VhdSizeGB
        SUT                = "$sutName  ->  NICs: $($fastest.Name), $($secondFast.Name)"
        TestServer         = "$tsName  ->  NIC : $($fastest.Name) (fastest)"
        SutPassthroughDisk = if ($offDisk) {
                                 "Disk $($offDisk.Number)  ($($offDisk.FriendlyName), $([math]::Round($offDisk.Size/1GB,1)) GB)"
                             } else { '<none>' }
        SecureBootTemplate = 'MicrosoftUEFICertificateAuthority'
        UpdateHostDefaults = [bool]$UpdateHostDefaults
    }
    [pscustomobject]$summary | Format-List | Out-String | Write-Host

    $confirm = Read-Choice -Prompt 'Proceed to create the two VMs (SUT + TestServer)? (Y/N)' `
                           -Valid  @('Y', 'N') -Default 'Y'
    if ($confirm -ne 'Y') {
        Write-Host 'Aborted by user.' -ForegroundColor Yellow
        return
    }

    Write-Section 'Step 6 - Create VMs'

    # --- SUT: 兩張 NIC + 多一組 SCSI passthrough disk ---
    $sut = New-CertVm -Name           $sutName `
                      -VmRoot         $vmRootDir `
                      -IsoPath        $iso.FullPath `
                      -ProcessorCount $sutProfile.Cpu `
                      -MemoryGB       $sutProfile.MemGB `
                      -VhdSizeGB      $VhdSizeGB `
                      -SwitchNames    @($fastest.Name, $secondFast.Name) `
                      -KeepPartialOnFailure:$KeepPartialOnFailure

    if ($offDisk) {
        Add-SutPassthroughDisk -VMName $sutName -Disk $offDisk
    }

    # --- TestServer: 一張 NIC，最快的 Switch ---
    $testServer = New-CertVm -Name           $tsName `
                             -VmRoot         $vmRootDir `
                             -IsoPath        $iso.FullPath `
                             -ProcessorCount $testServerProfile.Cpu `
                             -MemoryGB       $testServerProfile.MemGB `
                             -VhdSizeGB      $VhdSizeGB `
                             -SwitchNames    @($fastest.Name) `
                             -KeepPartialOnFailure:$KeepPartialOnFailure

    Write-Host ''
    Write-Host 'Created VMs:' -ForegroundColor Green
    @($sut, $testServer) |
        Select-Object Name, State, Generation, ProcessorCount,
                      @{N = 'MemoryGB'; E = { [int]($_.MemoryStartup / 1GB) }},
                      @{N = 'NICs';     E = { (Get-VMNetworkAdapter -VMName $_.Name |
                                                Select-Object -ExpandProperty SwitchName) -join ', ' }} |
        Format-Table -AutoSize | Out-String | Write-Host

    Write-Host 'Done. You can now start the VMs from Hyper-V Manager or via Start-VM.' -ForegroundColor Cyan
}
catch {
    Write-Error $_
    exit 1
}
