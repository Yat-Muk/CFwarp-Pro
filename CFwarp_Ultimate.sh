#!/bin/bash
# ==============================================================================
# CFwarp Ultimate - Enterprise Edition
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

# --- [下載源配置] ---
REPO_WARP_GO="https://github.com/Yat-Muk/warp-go-build/releases/download/v1.0.8"
REPO_WGCF="https://github.com/Yat-Muk/warp-go-build/releases/download/wgcf-latest"
REPO_TOOLS="https://github.com/Yat-Muk/warp-go-build/releases/download/tools-latest"
SCRIPT_URL="https://raw.githubusercontent.com/Yat-Muk/CFwarp-Pro/master/CFwarp_Ultimate.sh"

# 本地路徑
PATH_SCRIPT="/usr/local/bin/CFwarp_Ultimate.sh"
PATH_SHORTCUT="/usr/bin/cf"

PATH_WARP_GO="/usr/local/bin/warp-go"
PATH_WGCF="/usr/local/bin/wgcf"
PATH_WARP_PLUS="/usr/local/bin/warp_plus"
PATH_ENDPOINT="/usr/local/bin/warp_endpoint"
CONF_WARP_GO="/usr/local/bin/warp.conf"
CONF_WGCF="/etc/wireguard/wgcf.conf"

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

check_dependencies() {
    local missing_deps=""
    local required_cmds=("curl" "wget" "tar" "bc" "sed" "grep" "gawk" "netstat" "qrencode" "fping")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps="$missing_deps $cmd"
        fi
    done

    if [[ -n "$missing_deps" ]]; then
        log_warn "檢測到缺失依賴: $missing_deps，正在自動安裝..."
        if [[ "$PM" == "yum" ]]; then
            yum install -y epel-release
            yum install -y $missing_deps wireguard-tools iproute
        else
            apt-get update
            apt-get install -y $missing_deps wireguard-tools iproute2 lsb-release gnupg net-tools
        fi
    fi
}

# 安裝快捷指令
install_shortcut() {
    # 1. 檢測腳本本體
    if [[ -s "$PATH_SCRIPT" ]]; then
        chmod +x "$PATH_SCRIPT"
    else
        # 文件不存在，執行下載
        wget -q -O "$PATH_SCRIPT" "$SCRIPT_URL" || log_error "腳本下載失敗，請檢查網絡。"
        chmod +x "$PATH_SCRIPT"
    fi

    # 2. 創建快捷鏈接
    cat > "$PATH_SHORTCUT" <<EOF
#!/bin/bash
bash $PATH_SCRIPT "\$@"
EOF
    chmod +x "$PATH_SHORTCUT"
}

enable_tun() {
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 0666 /dev/net/tun
    fi
}

# [核心優化] 智能下載函數 (Smart Download)
download_file() {
    local filename="$1"
    local dest="$2"
    local base_url="$3"
    local url="${base_url}/${filename}"
    local sha_url="${url}.sha256"
    local perform_download=true

    log_info "正在檢查: ${filename} ..."

    # 1. 下載校驗文件 (極小)
    if wget -q -O "/tmp/checksum.tmp" "$sha_url"; then
        local expected=$(awk '{print $1}' /tmp/checksum.tmp)
        
        # 2. 如果本地文件存在，計算本地 Hash
        if [[ -f "$dest" ]]; then
            local actual=$(sha256sum "$dest" | awk '{print $1}')
            if [[ "$expected" == "$actual" ]]; then
                log_info "文件已存在且版本最新，跳過下載。"
                perform_download=false
            else
                log_warn "檢測到新版本或文件損壞，準備更新..."
            fi
        fi
    else
        log_warn "無法獲取校驗文件，將嘗試強制下載二進制文件..."
    fi

    # 3. 執行下載
    if $perform_download; then
        wget -q --show-progress -O "$dest" "$url" || log_error "下載失敗: $url"
        
        # 404 檢查
        if grep -q "<!DOCTYPE html>" "$dest"; then
            rm -f "$dest"
            log_error "下載錯誤：文件不存在 (404)。請檢查 GitHub Release。"
        fi

        # 下載後再次校驗
        if [[ -f "/tmp/checksum.tmp" ]]; then
            local expected=$(awk '{print $1}' /tmp/checksum.tmp)
            local actual=$(sha256sum "$dest" | awk '{print $1}')
            if [[ "$expected" != "$actual" ]]; then
                rm -f "$dest"
                log_error "新下載文件校驗失敗！"
            else
                log_info "校驗通過。"
            fi
        fi
    fi
    
    chmod +x "$dest"
    rm -f "/tmp/checksum.tmp"
}

# --- 3. 狀態檢測 ---

show_status_panel() {
    local v4=$(curl -s4m2 https://ip.gs -k)
    local v6=$(curl -s6m2 https://ip.gs -k)
    local warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)

    echo -e "${BLUE}---------------------------------------------------------${PLAIN}"
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
    [[ "$warp_status" =~ on|plus ]] && s_run="${GREEN}運行中 ($warp_status)${PLAIN}"
    echo -e " WARP: $s_run"
    echo -e "${BLUE}---------------------------------------------------------${PLAIN}"
}

check_streaming_unlock() {
    echo -e "\n${BLUE}>>> 正在進行媒體解鎖檢測...${PLAIN}"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    
    run_check() {
        local type="$1"
        echo -e "\n${YELLOW}[IPv${type} 檢測]${PLAIN}"
        
        local nf="${RED}失敗${PLAIN}"
        local code=$(curl -${type}fsL -A "$ua" -w "%{http_code}" -o /dev/null -m 5 "https://www.netflix.com/title/70143836" 2>/dev/null)
        case "$code" in
            200) nf="${GREEN}完整解鎖${PLAIN}" ;;
            404) nf="${YELLOW}僅自製劇${PLAIN}" ;;
            403) nf="${RED}無權限${PLAIN}" ;;
        esac

        local gpt="${RED}失敗${PLAIN}"
        local gpt_ret=$(curl -${type}fsL -A "$ua" -m 5 "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null)
        if [[ "$gpt_ret" == *'"status":"normal"'* ]]; then gpt="${GREEN}完整解鎖${PLAIN}";
        elif [[ -n "$gpt_ret" ]]; then gpt="${YELLOW}僅 Web${PLAIN}"; fi

        echo -e " Netflix: $nf | ChatGPT: $gpt"
    }

    local v4=$(curl -s4m1 https://ip.gs -k)
    [[ -n "$v4" ]] && run_check 4
    local v6=$(curl -s6m1 https://ip.gs -k)
    [[ -n "$v6" ]] && run_check 6
    
    echo -e "\n按回車鍵返回菜單..."
    read
    menu
}

# --- 4. 安裝邏輯 ---

setup_systemd_monitor() {
    local restart_cmd="$1"
    cat > "/usr/local/bin/warp-check.sh" <<EOF
#!/bin/bash
if ! curl -s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    $restart_cmd
fi
EOF
    chmod +x "/usr/local/bin/warp-check.sh"
    
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
    download_file "$BIN_WARP_GO" "$PATH_WARP_GO" "$REPO_WARP_GO"
    
    if [[ ! -f "$CONF_WARP_GO" ]]; then
        log_info "註冊 WARP-GO..."
        mkdir -p $(dirname "$CONF_WARP_GO")
        cat > "$CONF_WARP_GO" <<EOF
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0
KeepAlive = 30
EOF
        "$PATH_WARP_GO" --register --config="$CONF_WARP_GO" || log_warn "註冊失敗，請檢查網絡。"
    fi
    
    local mode=$1
    local ips=""
    case "$mode" in
        "ipv4") ips="0.0.0.0/0" ;;
        "ipv6") ips="::/0" ;;
        "dual") ips="0.0.0.0/0,::/0" ;;
    esac
    
    if [[ -f "$CONF_WARP_GO" ]]; then
        sed -i "s#AllowedIPs = .*#AllowedIPs = $ips#g" "$CONF_WARP_GO"
    fi
    
    cat > "/etc/systemd/system/${SVC_GO}.service" <<EOF
[Unit]
Description=Cloudflare WARP-GO
After=network.target
[Service]
Type=simple
ExecStart=$PATH_WARP_GO --config=$CONF_WARP_GO
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now ${SVC_GO}
    setup_systemd_monitor "systemctl restart ${SVC_GO}"
    
    log_info "WARP-GO 安裝完成。"
    readp "按回車鍵返回菜單..."
    menu
}

install_wgcf() {
    uninstall_all_silent
    install_pkg "wireguard-tools"
    download_file "$BIN_WGCF" "$WGCF_BIN" "$REPO_WGCF"
    
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
    readp "按回車鍵返回菜單..."
    menu
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
    readp "按回車鍵返回菜單..."
    menu
}

optimize_endpoint() {
    log_info "正在運行 Endpoint 優選..."
    download_file "$BIN_ENDPOINT" "$PATH_ENDPOINT" "$REPO_TOOLS"
    bash "$PATH_ENDPOINT"
    
    readp "輸入優選 Endpoint IP:Port (留空不修改): " new_ep
    if [[ -n "$new_ep" ]]; then
        if [[ -f "$CONF_WARP_GO" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$CONF_WARP_GO"
            systemctl restart ${SVC_GO}
        elif [[ -f "$CONF_WGCF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$CONF_WGCF"
            systemctl restart ${SVC_WGCF}
        fi
        log_info "Endpoint 已更新。"
    fi
    readp "按回車鍵返回菜單..."
    menu
}

manage_account() {
    echo -e "${YELLOW}1. 刷 WARP+ 流量${PLAIN}"
    echo -e "${YELLOW}2. 應用 WARP+ Key${PLAIN}"
    readp "選擇: " sub
    
    if [[ "$sub" == "1" ]]; then
        download_file "$BIN_WARP_PLUS" "$PATH_WARP_PLUS" "$REPO_TOOLS"
        readp "輸入 ID (保留為空自動讀取): " id
        if [[ -z "$id" && -f "$CONF_WARP_GO" ]]; then
             id=$(grep "Device" "$CONF_WARP_GO" | awk '{print $3}')
        fi
        [[ -n "$id" ]] && "$PATH_WARP_PLUS" --id "$id" || "$PATH_WARP_PLUS"
    elif [[ "$sub" == "2" ]]; then
        readp "輸入 Key: " key
        if command -v warp-go &>/dev/null; then
            warp-go --update --config="$CONF_WARP_GO" --license="$key"
            systemctl restart ${SVC_GO}
        fi
    fi
    readp "按回車鍵返回菜單..."
    menu
}

uninstall_all_silent() {
    systemctl stop ${SVC_GO} ${SVC_WGCF} ${SVC_MONITOR}.timer ${SVC_RESTART}.timer >/dev/null 2>&1
    systemctl disable ${SVC_GO} ${SVC_WGCF} ${SVC_MONITOR}.timer ${SVC_RESTART}.timer >/dev/null 2>&1
    if command -v warp-cli &>/dev/null; then warp-cli --accept-tos disconnect >/dev/null 2>&1; fi
}

uninstall_full() {
    uninstall_all_silent
    rm -rf "$PATH_WARP_GO" "$CONF_WARP_GO" "$PATH_WGCF" $(dirname "$CONF_WGCF") "$PATH_WARP_PLUS" "$PATH_ENDPOINT"
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
    
    show_status_panel
    
    echo -e "${YELLOW}方案一：WARP 系統接管 (推薦 WARP-GO)${PLAIN}"
    echo -e "  1. 安裝/切換 WARP-GO (IPv4)"
    echo -e "  2. 安裝/切換 WARP-GO (IPv6)"
    echo -e "  3. 安裝/切換 WARP-GO (雙棧)"
    echo -e "  -----------------------------"
    echo -e "  4. 安裝/切換 WGCF    (IPv4)"
    echo -e "  5. 安裝/切換 WGCF    (IPv6)"
    echo -e "  6. 安裝/切換 WGCF    (雙棧)"
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
             readp "按回車鍵返回..."
             menu
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
    menu
else
    case "$1" in
        install) install_warp_go "dual" ;;
        uninstall) uninstall_full ;;
        menu) menu ;;
    esac
fi
