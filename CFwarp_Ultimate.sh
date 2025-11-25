#!/bin/bash
# ==============================================================================
# CFwarp Ultimate - Enterprise Edition (Optimized)
# ------------------------------------------------------------------------------
# Repository: https://github.com/Yat-Muk/warp-go-build
# ==============================================================================

# --- 1. 全局配置 ---
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 倉庫配置
REPO_BASE="https://github.com/Yat-Muk/warp-go-build/releases/latest/download"
# 腳本自身的在線地址 (用於安裝到本地)
SCRIPT_URL="https://raw.githubusercontent.com/Yat-Muk/CFwarp-Pro/main/CFwarp_Ultimate.sh"

# 文件名與路徑
BIN_WARP_GO="warp-go_linux_amd64"
BIN_WGCF="wgcf_linux_amd64"
BIN_WARP_PLUS="warp_plus_linux_amd64"
BIN_ENDPOINT="warp_endpoint"

PATH_SCRIPT="/usr/local/bin/CFwarp_Ultimate.sh"
PATH_WARP_GO="/usr/local/bin/warp-go"
PATH_WGCF="/usr/local/bin/wgcf"
PATH_WARP_PLUS="/usr/local/bin/warp_plus"
PATH_ENDPOINT="/usr/local/bin/warp_endpoint"
CONF_WARP_GO="/usr/local/bin/warp.conf"
CONF_WGCF="/etc/wireguard/wgcf.conf"

# Systemd 服務名
SVC_GO="warp-go"
SVC_WGCF="wg-quick@wgcf"
SVC_MONITOR="warp-monitor"
SVC_RESTART="warp-daily-restart"

# --- 2. 基礎工具函數 ---

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
            BIN_WARP_GO="warp-go_linux_amd64"
            BIN_WGCF="wgcf_linux_amd64"
            BIN_WARP_PLUS="warp_plus_linux_amd64"
            ;;
        aarch64) 
            BIN_WARP_GO="warp-go_linux_arm64"
            BIN_WGCF="wgcf_linux_arm64" 
            BIN_WARP_PLUS="warp_plus_linux_arm64"
            ;;
        *) 
            log_error "不支持的架構: $ARCH" 
            ;;
    esac
}

# 智能依賴檢測
check_dependencies() {
    local missing_deps=""
    # 定義必須的命令列表
    local required_cmds=("curl" "wget" "tar" "bc" "sed" "grep" "gawk" "netstat" "qrencode" "fping")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    # 如果有缺失的命令，執行安裝
    if [[ -n "$missing_deps" ]]; then
        log_warn "檢測到缺失依賴: $missing_deps，正在自動安裝..."
        if [[ "$PM" == "yum" ]]; then
            yum install -y epel-release
            yum install -y $missing_deps wireguard-tools iproute
        else
            apt-get update
            # net-tools 包含 netstat
            apt-get install -y $missing_deps wireguard-tools iproute2 lsb-release gnupg net-tools
        fi
    fi
}

# 修復快捷指令 (安裝腳本到本地)
install_shortcut() {
    # 下載腳本自身到 /usr/local/bin
    if [[ ! -f "$PATH_SCRIPT" ]]; then
        wget -q -O "$PATH_SCRIPT" "$SCRIPT_URL"
        chmod +x "$PATH_SCRIPT"
    fi

    # 創建 cf 命令
    cat > /usr/bin/cf <<EOF
#!/bin/bash
bash $PATH_SCRIPT "\$@"
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

download_file() {
    local filename="$1"
    local dest="$2"
    local url="${REPO_BASE}/${filename}"
    local sha_url="${url}.sha256"

    log_info "下載: ${filename} ..."
    wget -q --show-progress -O "$dest" "$url" || log_error "下載失敗: $url"
    
    # 校驗
    if wget -q -O "/tmp/checksum.tmp" "$sha_url"; then
        local expected=$(awk '{print $1}' /tmp/checksum.tmp)
        local actual=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$expected" != "$actual" ]]; then
            rm -f "$dest"
            log_error "文件校驗失敗！"
        fi
        rm -f "/tmp/checksum.tmp"
    fi
    chmod +x "$dest"
}

# --- 3. 狀態檢測 (Status) ---

check_streaming_unlock() {
    echo -e "\n${BLUE}--- 正在進行媒體解鎖檢測 (請稍候) ---${PLAIN}"
    
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    local type="4" # 默認檢測 IPv4，如果只有 v6 則檢測 v6
    [[ -z $(curl -s4m2 https://ip.gs -k) ]] && type="6"

    # Netflix
    local nf="${RED}檢測失敗${PLAIN}"
    local code=$(curl -${type}fsL -A "$ua" -w "%{http_code}" -o /dev/null -m 5 "https://www.netflix.com/title/70143836" 2>/dev/null)
    case "$code" in
        200) nf="${GREEN}完整解鎖 (非自製劇)${PLAIN}" ;;
        404) nf="${YELLOW}僅自製劇${PLAIN}" ;;
        403) nf="${RED}無權限/被封鎖${PLAIN}" ;;
        000) nf="${RED}網絡連接失敗${PLAIN}" ;;
    esac

    # ChatGPT
    local gpt="${RED}檢測失敗${PLAIN}"
    local gpt_ret=$(curl -${type}fsL -A "$ua" -m 5 "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null)
    if [[ "$gpt_ret" == *'"status":"normal"'* ]]; then
        gpt="${GREEN}APP+Web 全解鎖${PLAIN}"
    elif [[ -n "$gpt_ret" ]]; then
        gpt="${YELLOW}僅 Web 解鎖${PLAIN}"
    else
        gpt="${RED}無法訪問${PLAIN}"
    fi

    echo -e " Netflix: $nf"
    echo -e " ChatGPT: $gpt"
    echo -e "\n按回車鍵返回菜單..."
    read
    menu
}

# 基礎狀態顯示
show_status_basic() {
    echo -e "\n${BLUE}--- 網絡狀態 ---${PLAIN}"
    local v4=$(curl -s4m2 https://ip.gs -k)
    local v6=$(curl -s6m2 https://ip.gs -k)
    local warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)

    if [[ -n "$v4" ]]; then
        local loc=$(curl -s4m2 http://ip-api.com/json/$v4?lang=zh-CN -k | grep '"country":' | cut -d'"' -f4)
        echo -e " IPv4: ${GREEN}$v4${PLAIN} ($loc)"
    else
        echo -e " IPv4: ${RED}無連接${PLAIN}"
    fi
    
    if [[ -n "$v6" ]]; then
        local loc=$(curl -s6m2 http://ip-api.com/json/$v6?lang=zh-CN -k | grep '"country":' | cut -d'"' -f4)
        echo -e " IPv6: ${GREEN}$v6${PLAIN} ($loc)"
    else
        echo -e " IPv6: ${RED}無連接${PLAIN}"
    fi

    local s_run="${RED}未運行${PLAIN}"
    [[ "$warp_status" == "on" || "$warp_status" == "plus" ]] && s_run="${GREEN}運行中 ($warp_status)${PLAIN}"
    echo -e " WARP: $s_run"
    echo "----------------"
}

# --- 4. 核心安裝 ---

setup_systemd_monitor() {
    local restart_cmd="$1"
    cat > "/usr/local/bin/warp-check.sh" <<EOF
#!/bin/bash
if ! curl -s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    $restart_cmd
fi
EOF
    chmod +x "/usr/local/bin/warp-check.sh"
    
    # Monitor Service
    cat > "/etc/systemd/system/${SVC_MONITOR}.service" <<EOF
[Unit]
Description=WARP Monitor
[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-check.sh
EOF
    cat > "/etc/systemd/system/${SVC_MONITOR}.timer" <<EOF
[Unit]
Description=WARP Monitor Timer
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Unit=${SVC_MONITOR}.service
[Install]
WantedBy=timers.target
EOF

    # Daily Restart
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

install_warp_go() {
    uninstall_all_silent
    download_file "$BIN_WARP_GO" "$WARP_GO_BIN"
    
    if [[ ! -f "$WARP_GO_CONF" ]]; then
        log_info "註冊 WARP-GO..."
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
    
    log_info "WARP-GO 安裝完成。"
    show_status_basic
}

install_wgcf() {
    uninstall_all_silent
    download_file "$BIN_WGCF" "$WGCF_BIN"
    
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR" || exit 1
    if [[ ! -f wgcf-account.toml ]]; then
        log_info "註冊 WGCF..."
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
    show_status_basic
}

install_socks5() {
    uninstall_all_silent
    log_info "安裝 Socks5 WARP-CLI..."
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
    readp "設置端口 (默認 40000): " port
    port=${port:-40000}
    warp-cli --accept-tos proxy port $port
    warp-cli --accept-tos connect
    log_info "Socks5 代理已啟動: 127.0.0.1:$port"
}

# --- 5. 高級工具 ---

optimize_endpoint() {
    log_info "正在運行 Endpoint 優選..."
    download_file "$BIN_ENDPOINT" "$PATH_ENDPOINT"
    bash "$PATH_ENDPOINT"
    
    log_info "優選結束。請將上方最優 IP:Port 填入。"
    readp "輸入 Endpoint (留空不修改): " new_ep
    if [[ -n "$new_ep" ]]; then
        if [[ -f "$WARP_GO_CONF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$WARP_GO_CONF"
            systemctl restart ${SVC_GO}
        elif [[ -f "$WGCF_CONF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$WGCF_CONF"
            systemctl restart ${SVC_WGCF}
        fi
        log_info "Endpoint 已更新。"
    fi
}

manage_account() {
    echo -e "${YELLOW}1. 刷 WARP+ 流量${PLAIN}"
    echo -e "${YELLOW}2. 應用 WARP+ Key${PLAIN}"
    echo -e "${YELLOW}3. 應用 Teams Token${PLAIN}"
    readp "選擇: " sub
    
    if [[ "$sub" == "1" ]]; then
        download_file "$BIN_WARP_PLUS" "$PATH_WARP_PLUS"
        readp "輸入 ID (保留為空自動讀取配置): " id
        if [[ -z "$id" && -f "$WARP_GO_CONF" ]]; then
             id=$(grep "Device" "$WARP_GO_CONF" | awk '{print $3}')
        fi
        [[ -n "$id" ]] && "$PATH_WARP_PLUS" --id "$id" || "$PATH_WARP_PLUS"
    elif [[ "$sub" == "2" ]]; then
        readp "輸入 Key: " key
        if command -v warp-go &>/dev/null; then
            warp-go --update --config="$WARP_GO_CONF" --license="$key"
            systemctl restart ${SVC_GO}
        fi
    elif [[ "$sub" == "3" ]]; then
        readp "輸入 Token: " token
        if command -v warp-go &>/dev/null; then
            warp-go --register --config="$WARP_GO_CONF" --team-config="$token"
            systemctl restart ${SVC_GO}
        fi
    fi
}

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

# --- 6. 主菜單 ---

menu() {
    clear
    echo -e "${BLUE}=========================================================${PLAIN}"
    echo -e "${BLUE}   CFwarp Ultimate (Self-Hosted & Production Grade)      ${PLAIN}"
    echo -e "${BLUE}=========================================================${PLAIN}"
    echo -e "${YELLOW}方案一：WARP 系統接管 (推薦 WARP-GO)${PLAIN}"
    echo -e "  1. 安裝/切換 WARP-GO (IPv4)"
    echo -e "  2. 安裝/切換 WARP-GO (IPv6)"
    echo -e "  3. 安裝/切換 WARP-GO (雙棧)"
    echo -e "  -----------------------------"
    echo -e "  4. 安裝/切換 WGCF (IPv4)"
    echo -e "  5. 安裝/切換 WGCF (IPv6)"
    echo -e "  6. 安裝/切換 WGCF (雙棧)"
    echo -e "${YELLOW}方案二：本地代理 (Socks5)${PLAIN}"
    echo -e "  7. 安裝 Socks5-WARP (官方客戶端)"
    echo -e "${YELLOW}高級工具與維護${PLAIN}"
    echo -e "  8. 優選 Endpoint IP (優化速度)"
    echo -e "  9. 賬戶管理 (刷流量 / 升級 Teams)"
    echo -e " 10. 媒體解鎖檢測 (Netflix/ChatGPT)"
    echo -e " 11. 暫停 / 開啟服務"
    echo -e " 12. 徹底卸載"
    echo -e "  0. 退出"
    echo -e "---------------------------------------------------------"
    
    if [[ -f "$WARP_GO_CONF" || -f "$WGCF_CONF" ]]; then
        echo -e "當前狀態: ${GREEN}已安裝${PLAIN}"
    else
        echo -e "當前狀態: ${RED}未安裝${PLAIN}"
    fi
    echo ""
    
    readp "請輸入選項: " num
    case "$num" in
        1) install_warp_go "ipv4" ;;
        2) install_warp_go "ipv6" ;;
        3) install_warp_go "dual" ;;
        4) install_wgcf "ipv4" ;;
        5) install_wgcf "ipv6" ;;
        6) install_wgcf "dual" ;;
        7) install_socks5 ;;
        8) optimize_endpoint ;;
        9) manage_account ;;
        10) check_streaming_unlock ;; 
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
check_dependencies
enable_tun
install_shortcut

if [[ $# == 0 ]]; then
    show_status_basic
    menu
else
    case "$1" in
        install) install_warp_go "dual" ;;
        uninstall) uninstall_full ;;
        status) show_status_basic ;;
    esac
fi
