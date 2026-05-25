#!/usr/bin/env bash
# =============================================================================
# Setup-RHEL10-Cert.sh
#
# RHEL 10 認證測試 VM 安裝完 OS 後的後續設定腳本。
# 在 SUT 與 TestServer 兩台 VM 內各跑一次。
#
# 主要動作：
#   1. 用 subscription-manager 註冊到 Red Hat (互動輸入帳密)
#   2. 啟用 cert-1-for-rhel-10-<HOSTTYPE>-rpms 認證測試 repo
#   3. 用 dnf 安裝認證測試常用的元件
#
# -----------------------------------------------------------------------------
# 怎麼把這個檔案弄進 VM
# -----------------------------------------------------------------------------
# 這個腳本是跑在 RHEL 10 guest，不是跑在 Hyper-V host；常用送檔方式：
#
# (A) 用 scp (VM 已能聯網)：
#     # 在 Windows host上
#     scp D:\Git\RHEL_CertVM_Setup\Setup-RHEL10-Cert.sh root@<VM_IP>:/root/
#
# (B) 在 VM 內直接 curl (需先 push 到 GitHub)：
#     curl -fLO https://raw.githubusercontent.com/howlin0811/RHEL_CertVM_Setup/main/Setup-RHEL10-Cert.sh
#
# (C) 挨載 ISO / VHDX 複製進 VM。
#
# -----------------------------------------------------------------------------
# Usage (在 VM 內)
# -----------------------------------------------------------------------------
#   chmod +x Setup-RHEL10-Cert.sh
#   sudo ./Setup-RHEL10-Cert.sh                              # 預設 HOSTTYPE=x86_64，互動詢問 hostname
#   sudo ./Setup-RHEL10-Cert.sh aarch64                      # 位置參數指定 HOSTTYPE
#   sudo HOSTTYPE=x86_64 ./Setup-RHEL10-Cert.sh              # 用環境變數帶入 HOSTTYPE
#   sudo NEW_HOSTNAME=sut01.lab ./Setup-RHEL10-Cert.sh       # 用環境變數帶入 hostname (跳過互動)
#   sudo NEW_HOSTNAME=keep ./Setup-RHEL10-Cert.sh            # 維持現有 hostname 不變
#
# 要完全自動化 (不要互動輸入 RHN 帳密)，把腳本裡的
#   subscription-manager register
# 改成：
#   subscription-manager register --username <USER> --password <PASS> --auto-attach
# 或：
#   subscription-manager register --org <ORG_ID> --activationkey <KEY>
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 參數
# -----------------------------------------------------------------------------
VERSION=10
# HOSTTYPE 對應 Red Hat cert repo 的命名後綴，常見值：x86_64 / aarch64 / ...
HOSTTYPE="${1:-${HOSTTYPE:-x86_64}}"
CERT_REPO="cert-1-for-rhel-${VERSION}-${HOSTTYPE}-rpms"
# kernel-debuginfo 必須從 debug repo 裝
DEBUG_REPO="rhel-${VERSION}-for-${HOSTTYPE}-baseos-debug-rpms"

# 認證測試常用元件清單 (RHEL 10)
# 註：kernel-debuginfo / kernel-debuginfo-common 不在此預裝，只啟用 debug repo，
#     需要時再 `dnf debuginfo-install kernel` 或手動裝。
PKGS=(
    redhat-certification-hardware
    xorriso
    fio
    egl-utils
    wayland-utils
    stress-ng
)

# -----------------------------------------------------------------------------
# 前置檢查
# -----------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: 請用 root 或 sudo 執行此腳本。" >&2
    exit 1
fi

if ! command -v subscription-manager >/dev/null 2>&1; then
    echo "ERROR: 找不到 subscription-manager，請先確認這是 RHEL 系統。" >&2
    exit 1
fi

echo "==============================================================="
echo " RHEL ${VERSION} cert VM post-install setup"
echo " Cert repo  : ${CERT_REPO}"
echo " Debug repo : ${DEBUG_REPO}"
echo "==============================================================="

# -----------------------------------------------------------------------------
# Step 0: 設定 hostname (在註冊前先改，subscription-manager 上看到的會是新名稱)
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 0/3: set hostname ==="
CURRENT_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
echo "目前 hostname: ${CURRENT_HOSTNAME}"

# 可用環境變數 NEW_HOSTNAME 跳過互動：
#   NEW_HOSTNAME=sut01.lab   -> 直接改成這個
#   NEW_HOSTNAME=keep        -> 不改，沿用目前 hostname
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
if [[ -z "${NEW_HOSTNAME}" ]]; then
    read -r -p "請輸入新的 hostname (直接 Enter 保持「${CURRENT_HOSTNAME}」不變): " NEW_HOSTNAME || true
fi

if [[ -z "${NEW_HOSTNAME}" || "${NEW_HOSTNAME}" == "keep" || "${NEW_HOSTNAME}" == "${CURRENT_HOSTNAME}" ]]; then
    echo "保持現有 hostname：${CURRENT_HOSTNAME}"
else
    # 基本格式檢查 (允許字母/數字/'-'/'_'/'.'，長度 1~253；底線雖不符 RFC 1123，但 Linux 實務常用)
    if [[ ! "${NEW_HOSTNAME}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,251}[A-Za-z0-9])?$ ]]; then
        echo "ERROR: hostname 格式不正確：${NEW_HOSTNAME}" >&2
        exit 1
    fi
    echo "套用新 hostname：${NEW_HOSTNAME}"
    hostnamectl set-hostname "${NEW_HOSTNAME}"
    # 同步更新 /etc/hosts 的 127.0.1.1 條目 (若沒有就追加一筆)
    if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s|^([[:space:]]*127\.0\.1\.1[[:space:]]+).*$|\1${NEW_HOSTNAME}|" /etc/hosts
    else
        echo "127.0.1.1 ${NEW_HOSTNAME}" >> /etc/hosts
    fi
    echo "新 hostname 已生效：$(hostnamectl --static)"
fi

# -----------------------------------------------------------------------------
# Step 1: 註冊到 Red Hat
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 1/3: subscription-manager register ==="
if subscription-manager status >/dev/null 2>&1; then
    echo "系統已註冊，略過 register。"
else
    # 互動式輸入帳密；要自動化可改成：
    #   subscription-manager register --username <USER> --password <PASS> --auto-attach
    # 或用 activation key：
    #   subscription-manager register --org <ORG_ID> --activationkey <KEY>
    subscription-manager register
fi

# -----------------------------------------------------------------------------
# Step 2: 啟用認證測試 repo
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 2/3: enable cert repo (${CERT_REPO}) ==="
subscription-manager repos --enable="${CERT_REPO}"

echo "=== Step 2/3: enable debug repo (${DEBUG_REPO}) ==="
# kernel-debuginfo 與 kernel-debuginfo-common 需要 baseos-debug-rpms
subscription-manager repos --enable="${DEBUG_REPO}" \
    || echo "WARN: 無法啟用 ${DEBUG_REPO}，kernel-debuginfo* 可能裝不起來。"

# -----------------------------------------------------------------------------
# Step 3: 安裝認證測試常用元件
# -----------------------------------------------------------------------------
echo ""
echo "=== Step 3/3: dnf install cert helper packages ==="
dnf install -y "${PKGS[@]}"

# 註：以下指令在 RHEL 10 目前 NOT WORK (package 已被淘汰或改名)，先保留供日後驗證
#   dnf update kernel-abi-stablelists

# 註：重灌 / 重建 VM 後若 SSH 連線出現 host key 不一致警告，
#     可用下列指令清掉舊的 known_hosts 紀錄 (把 [IP] 換成目標 VM 的 IP)：
#   ssh-keygen -f /root/.ssh/known_hosts -R [IP]

# -----------------------------------------------------------------------------
# 收尾
# -----------------------------------------------------------------------------
echo ""
echo "=== Done. 目前訂閱狀態： ==="
subscription-manager status || true

echo ""
echo "=== Enabled repos: ==="
subscription-manager repos --list-enabled || true
