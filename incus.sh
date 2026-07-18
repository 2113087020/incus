#!/bin/bash
# =======================================================================
# Incus 宿主网络安全自愈与容器动态清洗一体化部署脚本 (v5.8 容器专用隔离版)
# =======================================================================

set -e
set -o pipefail

# =======================================================================
# 🌟 全局自定义配置区
# =======================================================================
WHITELIST_DOMAINS=(
    "zstaticcdn.com"
    "*.zstaticcdn.com"     # Zoom 视频会议
    "*.ooklaserver.net"    # Ookla Speedtest 全球测速节点
    "*.speedtest.net"      # Ookla Speedtest 官方主域名
    "*.fast.com"           # Netflix 官方测速
    "speed.cloudflare.com" # Cloudflare 测速
)

WHITELIST_IPS=(
    "1.1.1.1"
    "8.8.8.8"              # 公共 DNS
)

# ☠️ 强制黑洞域名列表
BLACKLIST_DOMAINS=(
    "baidu.com"
    "taobao.com"
    "qq.com"
    "jd.com"
    "bilibili.com"
    "163.com"
    "weibo.com"
    "zhihu.com"
    "douyin.com"
    "kuaishou.com"
    "alipay.com"
    "alibaba.com"
    "tencent.com"
    "sohu.com"
    "sina.com"
    "360.com"
    "iqiyi.com"
    "youku.com"
    "xiaohongshu.com"
    "pinduoduo.com"
    "meituan.com"
    "ele.me"
    "aliyun.com"
)

# ==================== 🔍 自定义扫描与容器端口拦截 ====================
SCAN_KEYWORDS="nezha[-_]?agent|komari|xmrig|xmr-stak|minerd|cpuminer|ccminer|cgminer|bfgminer|ethminer|claymore|phoenixminer|nanominer|t-rex|lolminer|nbminer|gminer|teamredminer|nicehash|kryptex|kdevtmpfsi|kinsing|sysrv|sysrv-md|sustse|sustsed|wnw7492|monero|cryptonight|stratum|minergate|poolminer|minerstat|srbminer|astrominer|xmrig-proxy|crypto-miner|hashcat|crypto-pool|gridcrude|pamd32|panchan|p2pinfect|skidmap|watchdogx|watchdogs|kerberods|nmap|masscan|zmap|rustscan|fscan|gobuster|dirbuster|nikto|wpscan|hydra|medusa|ncrack|crowbar|patator|brutex|ssh_scan|sshcheck|pyrdp|xsstrike|hping|hping3|loic|hoic|slowloris|synflood|udpflood|mirai|gafgyt|bashlite|tsunami|billgates|elknot|dofloo|sedna|stacheldraht|trinoo|kptd|atdd|skynet|gates\.lod|conficker|xorddos|muhstik|frpc|frps|npc|nps|chisel|rclone|ngrok|pagekite|bore|localtonet|vtun|anyconnect|openconnect|iodine|dnscat2|dnscat|3proxy|lcx|beacon|geacon|sliver|merlin|metasploit|msfconsole|msfvenom|viper|meterpreter|suo5|reasing|neo-regeorg|cmd53|godzilla|behinder|antsword|stowaway|venom|serverstatus|stat_server|stat_client|sergate|beszel-hub|beszel-agent|beszel|nodeget|uptime-kuma|nodequery|ward|prometheus|node_exporter|zabbix_server|zabbix_agentd|grafana-server|grafana|influxd|netdata|glances|cockpit-ws|skywalking|sw-oap-server|vmagent|victoriametrics|fluent-bit|fluentd|logstash|vector|datadog-agent|agent2|filebeat|packetbeat|telegraf|sematext|pinpoint-agent|skywalking-agent|dozzle|scrutiny|sysupdate"
MAX_TCP_CONN=500
MAX_UDP_CONN=500
MAX_RAW_CONN=50
MAX_SYN_SENT=30

# ⛔ 仅针对容器的出站高危端口封杀
BLOCK_OUT_PORTS="22,23,445,3389,6379,2375,2376"
# =======================================================================

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"
INIT_SCRIPT="/etc/iptables-custom/init.sh"
CONF_DIR="/etc/iptables-custom"
LOG_FILE="/var/log/incus_clean.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if ! command -v incus &>/dev/null; then
    echo -e "${RED}✖ 未找到 incus 环境，当前节点安全跳过。${NC}"
    exit 0 
fi

echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🛡️  第一阶段: 网络防护与自愈模块同步${NC}"
echo -e "${CYAN}=======================================${NC}"

if ! command -v ipset &>/dev/null || ! command -v dnsmasq &>/dev/null || ! command -v dig &>/dev/null; then
    echo -e "${YELLOW}[!] 检测到关键依赖缺失，正在静默安装补齐...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -yq || true
    apt-get install -yq ipset curl iptables dnsmasq dnsutils cron || true
    systemctl enable --now cron || true
    systemctl restart dnsmasq >/dev/null 2>&1 || systemctl start dnsmasq >/dev/null 2>&1 || true
fi

mkdir -p /etc/dnsmasq.d
if [ ! -f /etc/dnsmasq.conf ] || ! grep -q "conf-dir=/etc/dnsmasq.d/" /etc/dnsmasq.conf; then
    echo "conf-dir=/etc/dnsmasq.d/,*.conf" > /etc/dnsmasq.conf
fi

HOST_DNS_CONF="port=53535\nlisten-address=127.0.0.1\nbind-interfaces\n"
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    HOST_DNS_CONF="${HOST_DNS_CONF}ipset=/${clean_domain}/whitelist_ips_dynamic\n"
done
for domain in "${BLACKLIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    HOST_DNS_CONF="${HOST_DNS_CONF}address=/${clean_domain}/0.0.0.0\n"
done
HOST_DNS_CONF="${HOST_DNS_CONF}server=8.8.8.8\nserver=1.1.1.1\n"
echo -e "$HOST_DNS_CONF" > /etc/dnsmasq.d/dynamic_whitelist.conf
systemctl restart dnsmasq >/dev/null 2>&1 || true

mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/cnip.list" ] || [ -n "$(find "$CONF_DIR/cnip.list" -mmin +1440 2>/dev/null)" ]; then
    echo "🌐 正在获取最新中国大陆 IP 基础库..."
    TMP_IP_FILE=$(mktemp)
    if curl -sLf https://cdn.jsdelivr.net/gh/ipverse/country-ip-blocks@master/country/cn/ipv4-aggregated.txt | tr -d '\r' | awk '/^[0-9]/ {print "add cnip " $1}' > "$TMP_IP_FILE"; then
        if [ -s "$TMP_IP_FILE" ]; then
            mv "$TMP_IP_FILE" "$CONF_DIR/cnip.list"
        fi
    fi
    rm -f "$TMP_IP_FILE"
fi

cat << EOF > "$CONF_DIR/whitelist.conf"
WHITELIST_DOMAINS=(
$(printf "    \"%s\"\n" "${WHITELIST_DOMAINS[@]}")
)
WHITELIST_IPS=(
$(printf "    \"%s\"\n" "${WHITELIST_IPS[@]}")
)
BLOCK_OUT_PORTS="$BLOCK_OUT_PORTS"
EOF

incus network set incusbr0 raw.dnsmasq= >/dev/null 2>&1 || true
RAW_DNSMASQ_CONF=""
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    RAW_DNSMASQ_CONF="${RAW_DNSMASQ_CONF}ipset=/${clean_domain}/whitelist_ips_dynamic\n"
done
for domain in "${BLACKLIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    RAW_DNSMASQ_CONF="${RAW_DNSMASQ_CONF}address=/${clean_domain}/0.0.0.0\n"
done
echo -e "$RAW_DNSMASQ_CONF" | incus network set incusbr0 raw.dnsmasq=- >/dev/null 2>&1 || true

cat << 'INIT' > "$INIT_SCRIPT"
#!/bin/bash
CONF_DIR="/etc/iptables-custom"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ -f "$CONF_DIR/whitelist.conf" ]; then
    source "$CONF_DIR/whitelist.conf"
fi

ipset create cnip hash:net 2>/dev/null || ipset flush cnip
if [ -f "$CONF_DIR/cnip.list" ]; then
    ipset restore < "$CONF_DIR/cnip.list" 2>/dev/null || true
fi

ipset create whitelist_ips_static hash:net 2>/dev/null || ipset flush whitelist_ips_static
ipset create whitelist_ips_dynamic hash:net 2>/dev/null || true

NEW_IPS=""
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    ips=$(dig +short "$clean_domain" 2>/dev/null | grep -E '^[0-9.]+$') || true
    if [ -n "$ips" ]; then
        NEW_IPS="${NEW_IPS}\n${ips}"
    fi
done

if echo -e "$NEW_IPS" | grep -qE '^[0-9.]+$'; then
    echo -e "$NEW_IPS" | grep -E '^[0-9.]+$' | sort -u > "$CONF_DIR/static_ips.cache"
fi

if [ -f "$CONF_DIR/static_ips.cache" ]; then
    while read -r ip; do
        [ -n "$ip" ] && ipset add whitelist_ips_static "$ip" 2>/dev/null || true
    done < "$CONF_DIR/static_ips.cache"
fi

for ip in "${WHITELIST_IPS[@]}"; do
    ipset add whitelist_ips_static "$ip" 2>/dev/null || true
done

while iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner nobody -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner nobody -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done

iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j REDIRECT --to-ports 53535
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j REDIRECT --to-ports 53535
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -m owner --uid-owner nobody -j ACCEPT
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -m owner --uid-owner nobody -j ACCEPT
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT

# 仅清理容器 FORWARD 链上的端口限制
if [ -n "$BLOCK_OUT_PORTS" ]; then
    while iptables -D FORWARD -i incusbr0 -p tcp -m multiport --dports "$BLOCK_OUT_PORTS" -j REJECT 2>/dev/null; do :; done
fi

while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp -m set --match-set cnip dst --syn -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p udp -m set --match-set cnip dst -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p icmp -m set --match-set cnip dst -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p tcp -m set --match-set cnip dst --syn -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p udp -m set --match-set cnip dst -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p icmp -m set --match-set cnip dst -j REJECT 2>/dev/null; do :; done

while iptables -D INPUT -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set whitelist_ips_static dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -m set --match-set whitelist_ips_static dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set whitelist_ips_dynamic dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -m set --match-set whitelist_ips_dynamic dst -j ACCEPT 2>/dev/null; do :; done

while iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o incusbr0 -j ACCEPT 2>/dev/null; do :; done

for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    while iptables -D OUTPUT -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
done

iptables -I FORWARD 1 -o incusbr0 -j ACCEPT
iptables -I FORWARD 1 -i incusbr0 -j ACCEPT
iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 仅封杀容器端口
if [ -n "$BLOCK_OUT_PORTS" ]; then
    iptables -I FORWARD 1 -i incusbr0 -p tcp -m multiport --dports "$BLOCK_OUT_PORTS" -j REJECT
fi

iptables -I OUTPUT 1 -p tcp -m set --match-set cnip dst --syn -j REJECT
iptables -I OUTPUT 1 -p udp -m set --match-set cnip dst -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p tcp -m set --match-set cnip dst --syn -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p udp -m set --match-set cnip dst -j REJECT

iptables -I OUTPUT 1 -m set --match-set whitelist_ips_dynamic dst -j ACCEPT
iptables -I OUTPUT 1 -m set --match-set whitelist_ips_static dst -j ACCEPT
iptables -I FORWARD 1 -m set --match-set whitelist_ips_dynamic dst -j ACCEPT
iptables -I FORWARD 1 -m set --match-set whitelist_ips_static dst -j ACCEPT

for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    iptables -I OUTPUT 1 -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
    iptables -I OUTPUT 1 -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
done

iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT

iptables -I FORWARD 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT

iptables -I INPUT 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
INIT

chmod +x "$INIT_SCRIPT"

if [ ! -f /etc/systemd/system/custom-firewall.service ]; then
    cat << 'SERVICE' > /etc/systemd/system/custom-firewall.service
[Unit]
Description=Custom Outbound Firewall for Host and Incus Containers
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/iptables-custom/init.sh

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable custom-firewall.service
fi

/etc/iptables-custom/init.sh

incus network set incusbr0 security.acls.default.egress.action=allow >/dev/null 2>&1 || true
incus network set incusbr0 security.acls.default.ingress.action=allow >/dev/null 2>&1 || true

if [ ! -f "$CRON_SCRIPT" ]; then
    cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
LOG_FILE="/var/log/incus_clean.log"
TMP_OUT=$(mktemp)
CLEAN_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT" "$CLEAN_OUT"' EXIT

timeout 10m bash -c 'curl -sLf -H "Cache-Control: no-cache" -H "Pragma: no-cache" "https://raw.githubusercontent.com/2113087020/incus/main/incus.sh?v=$(date +%s)" | bash' > "$TMP_OUT" 2>&1 || true
sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' "$TMP_OUT" | sed -E 's/\r/\n/g' > "$CLEAN_OUT" || true

if grep -qE "违规:|发现违规|重装成功" "$CLEAN_OUT" 2>/dev/null; then
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已自动裁剪 ---" >> "$LOG_FILE"
    fi
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 🚨 Incus 容器自动重装自愈事件报告 ===" >> "$LOG_FILE"
    grep -E "违规:|发现违规|正在强制|重装成功|重装失败" "$CLEAN_OUT" >> "$LOG_FILE" || true
    echo "" >> "$LOG_FILE"
fi
EOF
    chmod +x "$CRON_SCRIPT"
    OLD_CRON=$(crontab -l 2>/dev/null | grep -v "incus_cron.sh" || true)
    printf "%s\n*/5 * * * * %s\n" "$OLD_CRON" "$CRON_SCRIPT" | grep -v '^$' | crontab -
fi

echo -e "${GREEN}[✔] 阶段一自愈完成，网络隔离状态 100% 畅通。${NC}"

echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🚀 阶段二: 容器内部违规进程与 DDoS 行为清查${NC}"
echo -e "${CYAN}=======================================${NC}\n"

local_alpine=$(incus image list local: -f csv -c fd < /dev/null 2>/dev/null | grep -i "alpine" | head -n1 | awk -F, '{print $1}' || true)
if [ -n "$local_alpine" ]; then
    TARGET_IMAGE="$local_alpine"
else
    local_any=$(incus image list local: -f csv -c f < /dev/null 2>/dev/null | head -n1 || true)
    if [ -n "$local_any" ]; then
        TARGET_IMAGE="$local_any"
    else
        TARGET_IMAGE="images:alpine/latest"
    fi
fi

PROJECT_LIST=$(incus project list -f csv -c n < /dev/null 2>/dev/null || true)
if [ -z "$PROJECT_LIST" ]; then
    PROJECT_LIST="default"
fi

COUNT=0
INFECTED_COUNT=0

for project in $PROJECT_LIST; do
    [ -z "$project" ] && continue
    RUNNING_CONTAINERS=$(incus list --project "$project" -f csv -c ns < /dev/null 2>/dev/null | awk -F, 'tolower($0) ~ /,running$/ {print $1}' || true)
    
    for container in $RUNNING_CONTAINERS; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        
        printf "[%d] 正在盘查: %-26s [项目: %-8s] -> " "$COUNT" "$container" "$project"

        HIT_REASON=$(incus exec --project "$project" "$container" -- sh -c '
            KEYWORDS="$1"
            MAX_TCP="$2"
            MAX_UDP="$3"
            MAX_RAW="$4"
            MAX_SYN="$5"
            SELF=$$
            
            [ -f /proc/net/tcp ] || exit 0
            TCP_FILE=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -v "sl")
            
            TCP_COUNT=$(echo "$TCP_FILE" | grep -c "^")
            UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | grep -v "sl" | grep -c "^")
            RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | grep -v "sl" | grep -c "^")
            SYN_COUNT=$(echo "$TCP_FILE" | awk '\''{print $4}'\'' | grep -c "02")

            if [ "$SYN_COUNT" -gt "$MAX_SYN" ]; then echo "异常开包扫描 ($SYN_COUNT)"; exit 0; fi
            if [ "$TCP_COUNT" -gt "$MAX_TCP" ]; then echo "TCP高并发 ($TCP_COUNT)"; exit 0; fi
            if [ "$UDP_COUNT" -gt "$MAX_UDP" ]; then echo "UDP洪水 ($UDP_COUNT)"; exit 0; fi
            if [ "$RAW_COUNT" -gt "$MAX_RAW" ]; then echo "伪造Raw协议 ($RAW_COUNT)"; exit 0; fi

            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                MATCHED=$(tr "\0" "\n" < "$f" 2>/dev/null | grep -oiE "$KEYWORDS" | head -n1)
                if [ -n "$MATCHED" ]; then echo "违规进程: $MATCHED"; exit 0; fi
            done
            
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                if [ -e "$p" ]; then echo "残留文件: $p"; exit 0; fi
            done
        ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" "$MAX_SYN_SENT" < /dev/null 2>/dev/null || true)

        if [ -n "$HIT_REASON" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            echo -e "${RED}【🚨 违规: $HIT_REASON】${NC}"
            echo -e "${YELLOW}   ↳ 🔄 正在执行强制抹除性重装自愈...${NC}"
            if incus rebuild --project "$project" "$TARGET_IMAGE" "$container" --force < /dev/null >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！${NC}"
            else
                echo -e "${RED}   ↳ ❌ 重装失败，请手动检查。${NC}"
            fi
        else
            echo -e "${GREEN}[✔ 正常]${NC}"
        fi
    done
done

echo "------------------------------------------------"
echo -e "✅ ${GREEN}全套安全策略与清洗巡检运行结束！${NC}"
