#!/bin/bash
# ==============================================================================
# CFwarp Ultimate - Enterprise Edition
# ------------------------------------------------------------------------------
# Repository: https://github.com/Yat-Muk/warp-go-build
# ==============================================================================

# --- 1. 全局配置 (Global Config) ---
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# --- [關鍵配置] 您的自有 GitHub Mirror ---
# WARP-GO: 鎖定 v1.0.8 穩定版
REPO_WARP_GO="https://github.com/Yat-Muk/warp-go-build/releases/download/v1.0.8"
# WGCF: 自動獲取最新版
REPO_WGCF="https://github.com/Yat-Muk/warp-go-build/releases/latest/download"
# 工具集: 鎖定 tools-latest (含 IP 優選和刷流量工具)
REPO_TOOLS="https://github.com/Yat-Muk/warp-go-build/releases/download/tools-latest"

# 系統路徑
WARP_GO_BIN="/usr/local/bin/warp-go"
WARP_GO_CONF="/usr/local/bin/warp.conf"
WGCF_BIN="/usr/local/bin/wgcf"
WGCF_DIR="/etc/wireguard"
WGCF_CONF="${WGCF_DIR}/wgcf.conf"
WARP_PLUS_BIN="/usr/local/bin/warp-plus"
ENDPOINT_SCRIPT="/usr/local/bin/warp_endpoint"

# Systemd 服務名
SVC_GO="warp-go"
SVC_WGCF="wg-quick@wgcf"
SVC_MONITOR="warp-monitor"
SVC_RESTART="warp-daily-restart"

# --- 2. 基礎工具函數 (Base Utils) ---

log_info() { echo -e "${GREEN}[INFO] $1${PLAIN}"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${PLAIN}"; }
log_error() { echo -e "${RED}[ERROR] $1${PLAIN}"; exit 1; }
readp() { read -p "$(echo -e "${YELLOW}$1${PLAIN}")" $2; }

check_root() {
    [[ $EUID -ne 0 ]] && log_error "錯誤：本腳本必須以 root 權限運行。"
}

detect_system() {
    if [[ -f /etc/redhat-release ]]; then
        PM="yum"
    elif grep -q -E -i "debian|ubuntu" /etc/issue; then
        PM="apt"
    else
        PM="apt"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) 
            F_WARP_GO="warp-go_linux_amd64"
            F_WGCF="wgcf_linux_amd64"
            F_WARP_PLUS="warp_plus_linux_amd64"
            ;;
        aarch64) 
            F_WARP_GO="warp-go_linux_arm64"
            F_WGCF="wgcf_linux_arm64" 
            F_WARP_PLUS="warp_plus_linux_arm64"
            ;;
        *) 
            log_error "不支持的架構: $ARCH" 
            ;;
    esac
}

install_base_deps() {
    # 安裝基礎依賴，包含原腳本需要的所有工具
    local deps=("curl" "wget" "tar" "bc" "sed" "grep" "gawk" "net-tools" "qrencode" "fping")
    if [[ "$PM" == "yum" ]]; then
        yum install -y epel-release
        yum install -y "${deps[@]}" wireguard-tools iproute
    else
        apt-get update
        apt-get install -y "${deps[@]}" wireguard-tools iproute2 lsb-release gnupg
    fi
}

create_shortcut() {
    cat > /usr/bin/cf <<EOF
#!/bin/bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yat-Muk/CFwarp-Pro/main/CFwarp_Ultimate.sh) "\$@"
EOF
    chmod +x /usr/bin/cf
}

enable_tun() {
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 0666 /dev/net/tun
    fi
}

# 通用下載函數 (帶校驗)
download_file() {
    local url="$1"
    local dest="$2"
    local sha_url="${url}.sha256"
    
    log_info "正在下載: $(basename "$dest")"
    wget -q --show-progress -O "$dest" "$url" || log_error "下載失敗: $url"
    
    # 嘗試下載校驗文件 (如果存在)
    if wget -q -O "/tmp/checksum.tmp" "$sha_url"; then
        local expected=$(awk '{print $1}' /tmp/checksum.tmp)
        local actual=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$expected" != "$actual" ]]; then
            rm -f "$dest"
            log_error "文件完整性校驗失敗！請檢查網絡或源倉庫。"
        else
            log_info "文件校驗通過。"
        fi
        rm -f "/tmp/checksum.tmp"
    fi
    chmod +x "$dest"
}

# --- 3. 狀態與解鎖檢測 (Status & Unlock Check) ---
# 復刻原 nf4/nf6/chatgpt 函數邏輯

check_unlock_status() {
    local type="$1" # 4 or 6
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    
    # Netflix 檢測
    local nf_status="${RED}檢測失敗${PLAIN}"
    local code=$(curl -${type}fsL -A "$ua" -w "%{http_code}" -o /dev/null -m 5 "https://www.netflix.com/title/70143836" 2>/dev/null)
    case "$code" in
        200) nf_status="${GREEN}完整解鎖 (非自製劇)${PLAIN}" ;;
        404) nf_status="${YELLOW}僅自製劇${PLAIN}" ;;
        403) nf_status="${RED}無法觀看${PLAIN}" ;;
        000) nf_status="${RED}連接失敗${PLAIN}" ;;
    esac

    # ChatGPT 檢測
    local gpt_status="${RED}檢測失敗${PLAIN}"
    local gpt_ret=$(curl -${type}fsL -A "$ua" -m 5 "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null)
    if [[ "$gpt_ret" == *'"status":"normal"'* ]]; then
        gpt_status="${GREEN}APP+Web 解鎖${PLAIN}"
    elif [[ -n "$gpt_ret" ]]; then
        gpt_status="${YELLOW}僅 Web 解鎖${PLAIN}"
    else
        gpt_status="${RED}無法訪問${PLAIN}"
    fi

    echo -e " Netflix: $nf_status"
    echo -e " ChatGPT: $gpt_status"
}

show_full_status() {
    echo -e "\n${BLUE}--- 網絡連接與解鎖狀態 ---${PLAIN}"
    local v4=$(curl -s4m5 https://ip.gs -k)
    local v6=$(curl -s6m5 https://ip.gs -k)
    local warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)

    if [[ -n "$v4" ]]; then
        local loc=$(curl -s4m5 http://ip-api.com/json/$v4?lang=zh-CN -k | grep '"country":' | cut -d'"' -f4)
        echo -e " IPv4: ${GREEN}$v4${PLAIN} ($loc)"
        check_unlock_status 4
    else
        echo -e " IPv4: ${RED}無連接${PLAIN}"
    fi
    echo "--------------------------------"
    if [[ -n "$v6" ]]; then
        local loc=$(curl -s6m5 http://ip-api.com/json/$v6?lang=zh-CN -k | grep '"country":' | cut -d'"' -f4)
        echo -e " IPv6: ${GREEN}$v6${PLAIN} ($loc)"
        check_unlock_status 6
    else
        echo -e " IPv6: ${RED}無連接${PLAIN}"
    fi
    echo "--------------------------------"
    
    local s_run="${RED}未運行${PLAIN}"
    [[ "$warp_status" == "on" || "$warp_status" == "plus" ]] && s_run="${GREEN}運行中 ($warp_status)${PLAIN}"
    echo -e " WARP 狀態: $s_run"
    echo ""
}

# --- 4. Systemd 守護與自動任務 ---

setup_systemd_monitor() {
    local restart_cmd="$1"
    
    # 1. 創建監測腳本
    cat > "/usr/local/bin/warp-check.sh" <<EOF
#!/bin/bash
# 如果無法訪問 Cloudflare Trace，則重啟服務
if ! curl -s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    $restart_cmd
fi
EOF
    chmod +x "/usr/local/bin/warp-check.sh"

    # 2. 創建監測服務與定時器 (每分鐘)
    cat > "/etc/systemd/system/${SVC_MONITOR}.service" <<EOF
[Unit]
Description=WARP Connectivity Monitor
[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-check.sh
EOF
    cat > "/etc/systemd/system/${SVC_MONITOR}.timer" <<EOF
[Unit]
Description=Run WARP Monitor every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Unit=${SVC_MONITOR}.service
[Install]
WantedBy=timers.target
EOF

    # 3. 創建每日自動重啟定時器 (原腳本功能 15)
    cat > "/etc/systemd/system/${SVC_RESTART}.service" <<EOF
[Unit]
Description=Daily WARP Restart
[Service]
Type=oneshot
ExecStart=$restart_cmd
EOF
    cat > "/etc/systemd/system/${SVC_RESTART}.timer" <<EOF
[Unit]
Description=Daily WARP Restart Timer
[Timer]
OnCalendar=*-*-* 04:00:00
Unit=${SVC_RESTART}.service
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SVC_MONITOR}.timer
    systemctl enable --now ${SVC_RESTART}.timer
}

# --- 5. 核心安裝邏輯 (WARP-GO & WGCF) ---

# 安裝 WARP-GO (方案一 A)
install_warp_go() {
    uninstall_all_silent
    download_file "${F_WARP_GO}" "$WARP_GO_BIN" "$REPO_WARP_GO/${F_WARP_GO}"
    
    if [[ ! -f "$WARP_GO_CONF" ]]; then
        log_info "註冊 WARP-GO 帳戶..."
        mkdir -p $(dirname "$WARP_GO_CONF")
        cat > "$WARP_GO_CONF" <<EOF
[Account]
Type = free
Name = WARP
MTU = 1280
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0
KeepAlive = 30
EOF
        "$WARP_GO_BIN" --register --config="$WARP_GO_CONF"
        # 嘗試自動應用 WARP+ (如果之前有備份)
        auto_apply_warp_plus "$WARP_GO_BIN" "--config=$WARP_GO_CONF"
    fi
    
    local mode=$1
    local ips=""
    case "$mode" in
        "ipv4") ips="0.0.0.0/0" ;;
        "ipv6") ips="::/0" ;;
        "dual") ips="0.0.0.0/0,::/0" ;;
    esac
    sed -i "s#AllowedIPs = .*#AllowedIPs = $ips#g" "$WARP_GO_CONF"

    cat > "/etc/systemd/system/${SVC_GO}.service" <<EOF
[Unit]
Description=Cloudflare WARP-GO
After=network.target
[Service]
Type=simple
ExecStart=$WARP_GO_BIN --config=$WARP_GO_CONF
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SVC_GO}
    setup_systemd_monitor "systemctl restart ${SVC_GO}"
    
    log_info "WARP-GO 安裝完成 (模式: $mode)。"
    show_full_status
}

# 安裝 WGCF (方案一 B)
install_wgcf() {
    uninstall_all_silent
    install_pkg "wireguard-tools"
    download_file "${F_WGCF}" "$WGCF_BIN" "$REPO_WGCF/${F_WGCF}"
    
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR" || exit 1
    
    if [[ ! -f wgcf-account.toml ]]; then
        log_info "註冊 WGCF 帳戶..."
        yes | "$WGCF_BIN" register
        "$WGCF_BIN" generate
    fi
    
    cp -f wgcf-profile.conf wgcf.conf
    sed -i "s/engage.cloudflareclient.com:2408/162.159.192.1:2408/g" wgcf.conf
    
    local mode=$1
    local ips=""
    case "$mode" in
        "ipv4") ips="0.0.0.0\/0" ;;
        "ipv6") ips="::\/0" ;;
        "dual") ips="0.0.0.0\/0, ::\/0" ;;
    esac
    sed -i "s/^AllowedIPs.*/AllowedIPs = $ips/" wgcf.conf
    
    systemctl enable --now wg-quick@wgcf
    setup_systemd_monitor "systemctl restart wg-quick@wgcf"
    
    log_info "WGCF 模式已啟動。"
    show_full_status
}

# 安裝 Socks5 (方案二)
install_socks5() {
    uninstall_all_silent
    log_info "安裝官方 WARP-CLI (Socks5)..."
    
    if [[ "$PM" == "apt" ]]; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update && apt-get install -y cloudflare-warp
    else
        rpm -ivh https://pkg.cloudflareclient.com/cloudflare-release-el8.rpm
        yum install -y cloudflare-warp
    fi
    
    warp-cli --accept-tos register
    warp-cli --accept-tos mode proxy
    readp "請輸入 Socks5 端口 (默認 40000): " port
    port=${port:-40000}
    warp-cli --accept-tos proxy port $port
    warp-cli --accept-tos connect
    
    log_info "Socks5 代理已在端口 $port 啟動。"
}

# --- 6. 高級功能工具集 (Advanced Tools) ---

# 自動優選 IP (功能 13)
optimize_endpoint() {
    log_info "正在下載並運行 Endpoint 優選腳本..."
    download_file "warp_endpoint" "$PATH_ENDPOINT" "$REPO_TOOLS/warp_endpoint"
    
    # 運行 badafans 的腳本
    bash "$PATH_ENDPOINT"
    
    # 腳本運行完後，提示用戶輸入結果
    log_info "優選結束。請根據上方結果輸入最優 IP:Port。"
    readp "輸入 Endpoint (例如 162.159.192.10:2408): " new_ep
    
    if [[ -n "$new_ep" ]]; then
        if [[ -f "$WARP_GO_CONF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$WARP_GO_CONF"
            systemctl restart ${SVC_GO}
        elif [[ -f "$WGCF_CONF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$WGCF_CONF"
            systemctl restart ${SVC_WGCF}
        fi
        log_info "Endpoint 已更新為 $new_ep"
    else
        log_warn "未輸入，保持原樣。"
    fi
}

# 刷 WARP+ 流量 (功能 4, 17)
run_warp_plus_tool() {
    log_info "正在下載 WARP+ 流量生成工具..."
    download_file "$F_WARP_PLUS" "$WARP_PLUS_BIN" "$REPO_TOOLS/$F_WARP_PLUS"
    
    local id=""
    # 嘗試自動獲取 ID
    if [[ -f "$WARP_GO_CONF" ]]; then
        id=$(grep "Device" "$WARP_GO_CONF" | awk '{print $3}')
    fi
    
    echo -e "當前設備 ID: ${GREEN}${id:-未知}${PLAIN}"
    readp "請輸入 WARP ID (回車使用當前 ID): " input_id
    [[ -n "$input_id" ]] && id="$input_id"
    
    if [[ -n "$id" ]]; then
        "$WARP_PLUS_BIN" --id "$id"
    else
        "$WARP_PLUS_BIN"
    fi
}

# 帳戶升級 (功能 5, 6)
upgrade_account() {
    echo -e "${YELLOW}1. 升級 WARP+ (密鑰)${PLAIN}"
    echo -e "${YELLOW}2. 升級 Teams (Token)${PLAIN}"
    readp "請選擇: " sub
    
    if command -v warp-go &>/dev/null; then
        if [[ "$sub" == "1" ]]; then
            readp "輸入 WARP+ 密鑰: " key
            warp-go --update --config="$WARP_GO_CONF" --license="$key"
        elif [[ "$sub" == "2" ]]; then
            readp "輸入 Teams Token: " token
            warp-go --register --config="$WARP_GO_CONF" --team-config="$token"
        fi
        systemctl restart ${SVC_GO}
        show_full_status
    else
        log_error "當前僅支持 WARP-GO 內核升級。"
    fi
}

# 內部卸載
uninstall_all_silent() {
    systemctl stop ${SVC_GO} ${SVC_WGCF} ${SVC_MONITOR}.timer ${SVC_RESTART}.timer >/dev/null 2>&1
    systemctl disable ${SVC_GO} ${SVC_WGCF} ${SVC_MONITOR}.timer ${SVC_RESTART}.timer >/dev/null 2>&1
    if command -v warp-cli &>/dev/null; then warp-cli --accept-tos disconnect >/dev/null 2>&1; fi
}

uninstall_full() {
    uninstall_all_silent
    rm -rf "$WARP_GO_BIN" "$WARP_GO_CONF" "$WGCF_BIN" "$WGCF_DIR" "$WARP_PLUS_BIN" "$PATH_ENDPOINT"
    rm -f "/usr/local/bin/warp-check.sh" "/etc/systemd/system/${SVC_MONITOR}*" "/etc/systemd/system/${SVC_RESTART}*"
    if [[ "$PM" == "apt" ]]; then apt purge -y cloudflare-warp; else yum remove -y cloudflare-warp; fi
    systemctl daemon-reload
    log_info "已徹底卸載。"
}

# --- 7. 菜單界面 ---

menu() {
    clear
    echo -e "${BLUE}=========================================================${PLAIN}"
    echo -e "${BLUE}   CFwarp Ultimate (Enterprise) - 100% Functional Parity ${PLAIN}"
    echo -e "${BLUE}=========================================================${PLAIN}"
    echo -e "${YELLOW}方案一：WARP 系統接管 (推薦 WARP-GO)${PLAIN}"
    echo -e "  1. 安裝/切換 WARP-GO (IPv4)"
    echo -e "  2. 安裝/切換 WARP-GO (IPv6)"
    echo -e "  3. 安裝/切換 WARP-GO (雙棧)"
    echo -e "  -----------------------------"
    echo -e "  4. 安裝/切換 WGCF    (IPv4)"
    echo -e "  5. 安裝/切換 WGCF    (IPv6)"
    echo -e "  6. 安裝/切換 WGCF    (雙棧)"
    echo -e "${YELLOW}方案二：Socks5 代理${PLAIN}"
    echo -e "  7. 安裝 Socks5-WARP (官方客戶端)"
    echo -e "${YELLOW}高級工具與維護${PLAIN}"
    echo -e "  8. 顯示詳細狀態 (含 Netflix/ChatGPT 檢測)"
    echo -e "  9. 優選 Endpoint IP (自動/手動)"
    echo -e " 10. 刷 WARP+ 流量 / 帳戶升級 (Teams)"
    echo -e " 11. 暫停 / 開啟服務"
    echo -e " 12. 卸載腳本與服務"
    echo -e "  0. 退出"
    echo -e "---------------------------------------------------------"
    
    readp "請選擇: " num
    case "$num" in
        1) install_warp_go "ipv4" ;;
        2) install_warp_go "ipv6" ;;
        3) install_warp_go "dual" ;;
        4) install_wgcf "ipv4" ;;
        5) install_wgcf "ipv6" ;;
        6) install_wgcf "dual" ;;
        7) install_socks5 ;;
        8) show_full_status ;;
        9) optimize_endpoint ;;
        10) 
             echo -e "1. 刷流量 (WARP+)\n2. 帳戶升級"
             readp "選擇: " sub
             [[ "$sub" == "1" ]] && run_warp_plus_tool
             [[ "$sub" == "2" ]] && upgrade_account
             ;;
        11)
             readp "1.暫停 2.開啟: " act
             [[ "$act" == "1" ]] && uninstall_all_silent && log_info "服務已暫停"
             [[ "$act" == "2" ]] && systemctl start ${SVC_GO} 2>/dev/null || systemctl start wg-quick@wgcf 2>/dev/null && log_info "服務已開啟"
             ;;
        12) uninstall_full ;;
        0) exit 0 ;;
        *) log_error "無效輸入" ;;
    esac
}

# --- Entry Point ---
check_root
detect_system
install_base_deps
create_shortcut
enable_tun

if [[ $# == 0 ]]; then
    # 默認啟動模式：顯示狀態後進入菜單
    show_full_status
    menu
else
    # 命令行參數模式 (方便自動化調用)
    case "$1" in
        install) install_warp_go "dual" ;;
        uninstall) uninstall_full ;;
        status) show_full_status ;;
    esac
fi
