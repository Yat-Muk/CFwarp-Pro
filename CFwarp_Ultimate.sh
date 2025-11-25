#!/bin/bash
# ==============================================================================
# CFwarp Ultimate - Enterprise Edition
# ------------------------------------------------------------------------------
# Repository: https://github.com/Yat-Muk/warp-go-build
# ==============================================================================

# --- 1. 全局變量與路徑 ---
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export LANG=en_US.UTF-8

# WARP-GO: 鎖定 v1.0.8 穩定版
URL_WARP_GO="https://github.com/Yat-Muk/warp-go-build/releases/download/v1.0.8"
# WGCF: 鎖定 wgcf-latest (自動更新)
URL_WGCF="https://github.com/Yat-Muk/warp-go-build/releases/download/wgcf-latest"
# 工具集: 鎖定 tools-latest (含 IP優選, WARP+工具)
URL_TOOLS="https://github.com/Yat-Muk/warp-go-build/releases/download/tools-latest"

# 本地路徑
PATH_SCRIPT="/usr/bin/cf"  # 快捷指令路徑
PATH_WARP_GO="/usr/local/bin/warp-go"
PATH_WGCF="/usr/local/bin/wgcf"
PATH_WARP_PLUS="/usr/local/bin/warp_plus"
PATH_ENDPOINT="/usr/local/bin/warp_endpoint"
CONF_WARP_GO="/usr/local/bin/warp.conf"
CONF_WGCF="/etc/wireguard/wgcf.conf"

# Systemd 服務單元
SVC_GO="warp-go"
SVC_WGCF="wg-quick@wgcf"
SVC_MONITOR="warp-monitor"
SVC_RESTART="warp-daily-restart"

# --- 2. UI 樣式函數 ---
red(){ echo -e "\033[31m\033[01m$1\033[0m";}
green(){ echo -e "\033[32m\033[01m$1\033[0m";}
yellow(){ echo -e "\033[33m\033[01m$1\033[0m";}
blue(){ echo -e "\033[36m\033[01m$1\033[0m";}
white(){ echo -e "\033[37m\033[01m$1\033[0m";}
readp(){ read -p "$(yellow "$1")" $2;}

# --- 3. 系統檢測與依賴 ---

check_root() {
    [[ $EUID -ne 0 ]] && red "錯誤：請以 root 權限運行此腳本！" && exit 1
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
            red "不支持的架構: $ARCH" && exit 1 
            ;;
    esac
}

install_base_deps() {
    local missing=""
    local cmds=("curl" "wget" "tar" "bc" "sed" "grep" "gawk" "netstat" "qrencode" "fping")
    for c in "${cmds[@]}"; do
        if ! command -v "$c" &> /dev/null; then missing="$missing $c"; fi
    done
    
    if [[ -n "$missing" ]]; then
        echo "正在安裝缺失依賴: $missing ..."
        if [[ "$PM" == "yum" ]]; then
            yum install -y epel-release
            yum install -y $missing wireguard-tools iproute
        else
            apt-get update
            apt-get install -y $missing wireguard-tools iproute2 lsb-release gnupg net-tools
        fi
    fi
}

install_shortcut() {
    cp -f "$0" "$PATH_SCRIPT"
    chmod +x "$PATH_SCRIPT"
}

enable_tun() {
    if [[ ! -e /dev/net/tun ]]; then
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200
        chmod 0666 /dev/net/tun
    fi
}

# --- 4. 核心下載模塊 (帶校驗) ---

download_file() {
    local filename="$1"
    local dest="$2"
    local base_url="$3"
    local url="${base_url}/${filename}"
    local sha_url="${url}.sha256"

    echo "正在下載: $filename ..."
    wget -q --show-progress -O "$dest" "$url" || { red "下載失敗: $url"; return 1; }
    
    # 檢查是否下載了 404 頁面
    if grep -q "<!DOCTYPE html>" "$dest"; then
        rm -f "$dest"
        red "錯誤：文件不存在 (404)。請檢查 GitHub Release。"
        return 1
    fi

    # 校驗
    if wget -q -O "/tmp/checksum.tmp" "$sha_url"; then
        local expected=$(awk '{print $1}' /tmp/checksum.tmp)
        local actual=$(sha256sum "$dest" | awk '{print $1}')
        if [[ "$expected" != "$actual" ]]; then
            rm -f "$dest"
            red "安全警告：文件校驗失敗！已刪除文件。"
            return 1
        fi
        rm -f "/tmp/checksum.tmp"
    fi
    chmod +x "$dest"
}

# --- 5. Systemd 守護進程 ---

setup_systemd_monitor() {
    local restart_cmd="$1"
    # 寫入監控腳本
    cat > "/usr/local/bin/warp-check.sh" <<EOF
#!/bin/bash
if ! curl -s --max-time 3 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp=on"; then
    $restart_cmd
fi
EOF
    chmod +x "/usr/local/bin/warp-check.sh"
    
    # 寫入服務與定時器
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

# --- 6. 功能模塊 ---

# 安裝 WARP-GO
install_warp_go() {
    uninstall_all_silent
    download_file "$F_WARP_GO" "$PATH_WARP_GO" "$URL_WARP_GO" || return
    
    if [[ ! -f "$CONF_WARP_GO" ]]; then
        echo "正在註冊 WARP-GO..."
        mkdir -p $(dirname "$CONF_WARP_GO")
        cat > "$CONF_WARP_GO" <<EOF
[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = 162.159.192.1:2408
AllowedIPs = 0.0.0.0/0
KeepAlive = 30
EOF
        "$PATH_WARP_GO" --register --config="$CONF_WARP_GO" || { red "註冊失敗！"; return; }
    fi
    
    local mode=$1
    local ips=""
    case "$mode" in
        "ipv4") ips="0.0.0.0/0" ;;
        "ipv6") ips="::/0" ;;
        "dual") ips="0.0.0.0/0,::/0" ;;
    esac
    sed -i "s#AllowedIPs = .*#AllowedIPs = $ips#g" "$CONF_WARP_GO"
    
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
    
    green "WARP-GO 安裝完成！"
    readp "按回車返回菜單..."
    start_menu
}

# 安裝 WGCF
install_wgcf() {
    uninstall_all_silent
    install_pkg "wireguard-tools"
    download_file "$F_WGCF" "$PATH_WGCF" "$URL_WGCF" || return
    
    mkdir -p "$WGCF_DIR"
    cd "$WGCF_DIR" || exit 1
    if [[ ! -f wgcf-account.toml ]]; then
        echo "正在註冊 WGCF..."
        yes | "$PATH_WGCF" register
        "$PATH_WGCF" generate
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
    
    green "WGCF 模式已啟動！"
    readp "按回車返回菜單..."
    start_menu
}

# 安裝 Socks5
install_socks5() {
    uninstall_all_silent
    echo "安裝官方 Socks5 客戶端..."
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
    green "Socks5 代理已在端口 $port 啟動。"
    readp "按回車返回菜單..."
    start_menu
}

# --- 7. 高級功能 ---

optimize_endpoint() {
    echo "正在下載優選腳本..."
    download_file "warp_endpoint" "$PATH_ENDPOINT" "$URL_TOOLS" || return
    bash "$PATH_ENDPOINT"
    
    readp "輸入優選結果 IP:Port (留空不修改): " new_ep
    if [[ -n "$new_ep" ]]; then
        if [[ -f "$CONF_WARP_GO" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$CONF_WARP_GO"
            systemctl restart ${SVC_GO}
        elif [[ -f "$CONF_WGCF" ]]; then
            sed -i "s/Endpoint = .*/Endpoint = $new_ep/" "$CONF_WGCF"
            systemctl restart ${SVC_WGCF}
        fi
        green "Endpoint 已更新。"
    fi
    readp "按回車返回..."
    start_menu
}

manage_account() {
    echo
    yellow " 1. 刷 WARP+ 流量"
    yellow " 2. 應用 WARP+ Key"
    echo
    readp "請選擇: " sub
    
    if [[ "$sub" == "1" ]]; then
        download_file "$F_WARP_PLUS" "$PATH_WARP_PLUS" "$URL_TOOLS" || return
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
    readp "按回車返回..."
    start_menu
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
    green "已徹底卸載。"
}

# --- 8. 狀態顯示與檢測 ---

check_unlock() {
    local type="$1"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    
    # Netflix
    local nf="檢測失敗"
    local code=$(curl -${type}fsL -A "$ua" -w "%{http_code}" -o /dev/null -m 5 "https://www.netflix.com/title/70143836" 2>/dev/null)
    case "$code" in
        200) nf="${GREEN}完整解鎖${PLAIN}" ;;
        404) nf="${YELLOW}僅自製劇${PLAIN}" ;;
        403) nf="${RED}無權限${PLAIN}" ;;
        000) nf="${RED}失敗${PLAIN}" ;;
    esac

    # ChatGPT
    local gpt="檢測失敗"
    local gpt_ret=$(curl -${type}fsL -A "$ua" -m 5 "https://ios.chat.openai.com/public-api/mobile/server_status/v1" 2>/dev/null)
    if [[ "$gpt_ret" == *'"status":"normal"'* ]]; then
        gpt="${GREEN}APP+Web${PLAIN}"
    elif [[ -n "$gpt_ret" ]]; then
        gpt="${YELLOW}僅 Web${PLAIN}"
    else
        gpt="${RED}失敗${PLAIN}"
    fi

    echo -e " Netflix: $nf | ChatGPT: $gpt"
}

show_status_banner() {
    local v4=$(curl -s4m2 https://ip.gs -k)
    local v6=$(curl -s6m2 https://ip.gs -k)
    local warp_status=$(curl -s https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)

    white "---------------------------------------------------------"
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
    white "---------------------------------------------------------"
}

full_unlock_check() {
    echo
    blue ">>> 正在進行媒體解鎖檢測..."
    local v4=$(curl -s4m1 https://ip.gs -k)
    [[ -n "$v4" ]] && echo -e "\n${YELLOW}[IPv4]${PLAIN}" && check_unlock 4
    
    local v6=$(curl -s6m1 https://ip.gs -k)
    [[ -n "$v6" ]] && echo -e "\n${YELLOW}[IPv6]${PLAIN}" && check_unlock 6
    
    echo
    readp "按回車返回..."
    start_menu
}

# --- 9. 主菜單 ---

start_menu() {
    clear
    green "========================================================="
    green "   CFwarp Ultimate (Enterprise)        "
    green "========================================================="
    
    show_status_banner
    
    echo -e "${YELLOW}方案一：WARP 系統接管 (推薦 WARP-GO)${PLAIN}"
    green " 1. 安裝/切換 WARP-GO (IPv4)"
    green " 2. 安裝/切換 WARP-GO (IPv6)"
    green " 3. 安裝/切換 WARP-GO (雙棧)"
    echo
    green " 4. 安裝/切換 WGCF    (IPv4)"
    green " 5. 安裝/切換 WGCF    (IPv6)"
    green " 6. 安裝/切換 WGCF    (雙棧)"
    echo -e "${YELLOW}方案二：本地代理 (Socks5)${PLAIN}"
    green " 7. 安裝 Socks5-WARP (官方客戶端)"
    echo -e "${YELLOW}高級工具與維護${PLAIN}"
    green " 8. 優選 Endpoint IP (優化速度)"
    green " 9. 賬戶管理 (刷流量 / 升級)"
    green " 10. 媒體解鎖檢測 (Netflix/ChatGPT)"
    green " 11. 暫停 / 開啟服務"
    green " 12. 徹底卸載"
    green " 0. 退出"
    white "---------------------------------------------------------"
    
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
        10) full_unlock_check ;; 
        11) 
             readp "1.暫停 2.開啟: " act
             [[ "$act" == "1" ]] && uninstall_all_silent && green "服務已暫停"
             [[ "$act" == "2" ]] && systemctl start ${SVC_GO} 2>/dev/null || systemctl start wg-quick@wgcf 2>/dev/null && green "服務已開啟"
             readp "按回車返回..."
             start_menu
             ;;
        12) uninstall_full ;;
        0) exit 0 ;;
        *) red "無效輸入" ; sleep 1 ; start_menu ;;
    esac
}

# --- Entry Point ---
check_root
detect_system
enable_tun
install_shortcut
install_base_deps

if [[ $# == 0 ]]; then
    start_menu
else
    case "$1" in
        install) install_warp_go "dual" ;;
        uninstall) uninstall_full ;;
        menu) start_menu ;;
    esac
fi
