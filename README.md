# RHEL CertVM Setup

在 Hyper-V host 上一鍵建立 Red Hat Enterprise Linux Certification 測試用的 VM 環境（SUT + TestServer）。

## 它做什麼

1. 從 ISO 目錄（預設 `C:\Users\Administrator\Downloads`）挑選 `rhel-<X.Y>-x86_64-dvd*.iso`，解析出 RHEL 版本（例如 `10.0`、`8.6`）。
2. 掃描 host 上的 **wired** 實體網卡（排除 Wi-Fi），依 LinkSpeed 自動建立／沿用 VMSwitch：
   - `1 Gbps  → VMSwitch-1G`
   - `10 Gbps → VMSwitch-10G`
   - `25 Gbps → VMSwitch-25G`

   至少要 2 種不同速度，否則中止。
3. 決定 VM 檔案根目錄：預設 `D:\Hyper-V`；若沒有 D: 槽，則在非系統磁碟中找一顆 offline / RAW 的磁碟，經使用者確認後格式化為 NTFS 並 assign drive letter = D，再使用 `D:\Hyper-V`。
4. 選擇 VM 規格 profile：
   - **Default**: 16 vCPU / 64 GB
   - **Max**（依 ISO 大版號）：
     - RHEL 8  : 768 vCPU / 1152 GB
     - RHEL 9  : 1792 vCPU / 2688 GB
     - RHEL 10 : 1792 vCPU / 2688 GB
5. 找出 host 上「排在最後面」的 offline disk，準備給 SUT 做 SCSI passthrough。
6. 建立兩台 Gen2 VM：
   - **SUT** `RHEL_<X.Y>`：2 張 NIC（最快 + 第二快的 Switch）+ 額外 SCSI controller + passthrough disk
   - **TestServer** `RHEL_<X.Y>_TestServer`：1 張 NIC（最快的 Switch）

   兩台都掛上選定的 ISO，Secure Boot 套用 `MicrosoftUEFICertificateAuthority`（RHEL 在 Gen2 必要）。

## 先決條件

- Windows Server（或裝有 Hyper-V 角色的 Windows 10/11 Pro/Enterprise）
- 以 **系統管理員** 啟動的 PowerShell
- Hyper-V 角色與 `Hyper-V` PowerShell 模組
- 至少 2 種不同速度的 wired NIC 處於 Up 狀態
- ISO 檔已下載到目標目錄，且命名為 `rhel-<major>.<minor>-x86_64-dvd*.iso`

## 三種使用方式

以下範例使用 `howlin0811/RHEL_CertVM_Setup`（`main` branch）；fork 另外維護者請自行替換 URL。

### 方案 A — 一行下載並執行（最快）

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url = 'https://raw.githubusercontent.com/howlin0811/RHEL_CertVM_Setup/main/Setup-RHELCertVM.ps1'
iex (iwr -UseBasicParsing $url).Content
```

若要帶參數，得包成 scriptblock：

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url    = 'https://raw.githubusercontent.com/howlin0811/RHEL_CertVM_Setup/main/Setup-RHELCertVM.ps1'
$script = (iwr -UseBasicParsing $url).Content
& ([scriptblock]::Create($script)) -IsoDirectory 'C:\Users\Administrator\Downloads' -VhdSizeGB 200
```

### 方案 B — 下載到暫存檔再執行（可直接帶參數）

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$url = 'https://raw.githubusercontent.com/howlin0811/RHEL_CertVM_Setup/main/Setup-RHELCertVM.ps1'
$tmp = Join-Path $env:TEMP 'Setup-RHELCertVM.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& $tmp                                                              # 預設值
# 或：
& $tmp -IsoDirectory 'C:\Users\Administrator\Downloads' -VmRoot 'E:\Hyper-V' -VhdSizeGB 150
```

### 方案 C — Clone 整個 repo（推薦長期使用）

```powershell
git clone https://github.com/howlin0811/RHEL_CertVM_Setup.git C:\Tools\RHEL_CertVM_Setup
cd C:\Tools\RHEL_CertVM_Setup
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Setup-RHELCertVM.ps1

# 更新版本
git pull
```

## 參數

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `-IsoDirectory` | `C:\Users\Administrator\Downloads` | 存放 RHEL ISO 的目錄 |
| `-VmRoot` | (空) → 自動：`D:\Hyper-V` 或讓使用者挑分割槽 | VM (vhdx) 的存放根目錄 |
| `-VhdSizeGB` | `100` | 每台 VM 系統 VHDX 大小 (GB)，dynamic |

## ISO 檔名規範

腳本只會挑符合下列正則的檔案：

```
^rhel-(?<major>\d+)\.(?<minor>\d+)-x86_64-dvd.*\.iso$
```

範例：

| 檔名 | 解析出的版本 | SUT 名稱 | TestServer 名稱 |
|------|--------------|----------|------------------|
| `rhel-10.0-x86_64-dvd.iso` | 10.0 | `RHEL_10.0` | `RHEL_10.0_TestServer` |
| `rhel-9.4-x86_64-dvd.iso`  | 9.4  | `RHEL_9.4`  | `RHEL_9.4_TestServer`  |
| `rhel-8.6-x86_64-dvd.iso`  | 8.6  | `RHEL_8.6`  | `RHEL_8.6_TestServer`  |

## 常見問題

**Q. 一定要 admin 嗎？**
是。腳本有 `#Requires -RunAsAdministrator`；Hyper-V 操作本身也需要。

**Q. Execution Policy 怎麼處理？**
- 用 `iex`（方案 A）不受 Execution Policy 影響。
- 用 `.ps1` 直接執行（方案 B/C），先 `Set-ExecutionPolicy -Scope Process Bypass` 或對檔案 `Unblock-File` 即可。

**Q. 沒找到 offline disk 會怎樣？**
SUT 仍會被建立，但 **沒有** passthrough disk，會印一條 warning。

**Q. 同名 VM 已存在會怎樣？**
腳本會 throw 拒絕覆蓋。請先到 Hyper-V Manager 移除（連同 vhdx）再重跑。

**Q. 1792 vCPU 我的 host 跑得起來嗎？**
取決於 Windows / Hyper-V 版本上限。若 host 不支援，`Set-VMProcessor` 會自己 throw，由腳本的 `catch` 接住並 `exit 1`。

## 注意事項

- Max profile 主要用於 RHEL 官方最大配置壓測；一般功能性 cert 用 Default 即可。
- 同速度若有多張 wired NIC，腳本只挑「第一張」綁 Switch，其餘同速度網卡不會使用。
- 安裝 RHEL 結束後，DVD 仍會掛在第一順位；建議手動 `Remove-VMDvdDrive` 或改 boot order 以免重灌迴圈。
---

# Guest 端腳本：Setup-RHEL10-Cert.sh

`Setup-RHELCertVM.ps1` 在 Hyper-V host 上建好 SUT + TestServer 兩台 VM 、裝完 RHEL 10 之後，
需要進到 **VM 內部** 跑 [`Setup-RHEL10-Cert.sh`](Setup-RHEL10-Cert.sh) 來做註冊、啟用 cert repo、安裝必要元件。

## 它做什麼

1. `subscription-manager register` 註冊到 Red Hat (預設互動輸入帳密，已註冊則略過)。
2. 啟用認證測試 repo：`subscription-manager repos --enable=cert-1-for-rhel-10-<HOSTTYPE>-rpms`，
   同時啟用 `rhel-10-for-<HOSTTYPE>-baseos-debug-rpms`（之後要 `kernel-debuginfo*` 才裝得到，本腳本不預裝）。
3. `dnf install -y redhat-certification-hardware xorriso fio egl-utils wayland-utils stress-ng`。
4. 最後印出目前的訂閱狀態與已啟用的 repo 清單。

> 註：`dnf update kernel-abi-stablelists` 在 RHEL 10 目前無效，已以註解保留來日驗證。

## 怎麼使用

### 1. 先把腳本送進 VM

三選一：

- **scp** (VM 能聯網)：
  ```powershell
  scp D:\Git\RHEL_CertVM_Setup\Setup-RHEL10-Cert.sh root@<VM_IP>:/root/
  ```
- **在 VM 內直接下載** (已 push 到 GitHub)：
  ```bash
  curl -fLO https://raw.githubusercontent.com/howlin0811/RHEL_CertVM_Setup/main/Setup-RHEL10-Cert.sh
  ```
- **挨載 ISO / VHDX** 複製進去。

### 2. 在 VM 內跑

```bash
chmod +x Setup-RHEL10-Cert.sh

sudo ./Setup-RHEL10-Cert.sh                 # 預設 HOSTTYPE=x86_64
sudo ./Setup-RHEL10-Cert.sh aarch64         # 位置參數指定 HOSTTYPE
sudo HOSTTYPE=x86_64 ./Setup-RHEL10-Cert.sh # 以環境變數帶入
```

**SUT 與 TestServer 兩台都要各跑一次。**

### 3. 自動化 (不要互動輸入帳密)

把腳本裡的
```bash
subscription-manager register
```
改成：
```bash
subscription-manager register --username <RHN_USER> --password <RHN_PASS> --auto-attach
# 或用 activation key
subscription-manager register --org <ORG_ID> --activationkey <KEY>
```

## 整體流程

```
Hyper-V host:  Setup-RHELCertVM.ps1   → 建好 SUT + TestServer 兩台 VM
               ↓
VM (RHEL 10 裝完後):
  - 在 SUT 跑：        sudo ./Setup-RHEL10-Cert.sh
  - 在 TestServer 跑： sudo ./Setup-RHEL10-Cert.sh
               ↓
接著就可以開始跑 redhat-certification 測試
```