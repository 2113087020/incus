#!/bin/bash
# =======================================================================
# Linux 通用防火墙单向阻断与 Incus 巡检一体化部署脚本 (v5.16.2 终极生产金标版)
# =======================================================================

set -e
set -o pipefail

# =======================================================================
# 🌟 全局自定义双重白名单配置
# =======================================================================
WHITELIST_DOMAINS=(
    "zstaticcdn.com"
    "*.zstaticcdn.com"
)

WHITELIST_IPS=(
    "1.1.1.1"
    "8.8.8.8"
)
# =======================================================================

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"
INIT_SCRIPT="/etc/iptables-custom/init.sh"
CONF_DIR="/etc/iptables-custom"
LOG_FILE="/var/log/incus_clean.log"

echo "=================================================="
echo "🛡️  第一阶段：配置单向阻断防火墙与宿主 DNS 劫持"
echo "=================================================="

echo "🧹 正在释放可能残存的旧版劫持与阻断规则..."
while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

OS_TYPE="ubuntu"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    [ "$ID" = "debian" ] && OS_TYPE="debian"
fi
ARCH=$(dpkg --print-architecture)

if [ "$OS_TYPE" = "debian" ]; then
    OFFICIAL_URL="http://deb.debian.org/debian/"
    MATCH_REGEX="s#https?://[^/]*(aliyun|tencent|tsinghua|ustc|huaweicloud)[^/]*/debian/?#${OFFICIAL_URL}#g"
else
    if [ "$ARCH" = "arm64" ]; then
        OFFICIAL_URL="http://ports.ubuntu.com/ubuntu-ports/"
    else
        OFFICIAL_URL="http://archive.ubuntu.com/ubuntu/"
    fi
    MATCH_REGEX="s#https?://[^/]*(aliyun|tencent|tsinghua|ustc|huaweicloud)[^/]*/(ubuntu-ports|ubuntu)/?#${OFFICIAL_URL}#g"
fi

find /etc/apt/ -name "*.list" -type f | while read -r list_file; do
    if grep -qE "aliyun|tencent|tsinghua|ustc|huaweicloud" "$list_file"; then
        sed -i -E "${MATCH_REGEX}" "$list_file"
    fi
done

mkdir -p /etc/dnsmasq.d
echo "conf-dir=/etc/dnsmasq.d/,*.conf" > /etc/dnsmasq.conf

HOST_DNS_CONF="port=53535\nlisten-address=127.0.0.1\nbind-interfaces\n"
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    HOST_DNS_CONF="${HOST_DNS_CONF}ipset=/${clean_domain}/whitelist_ips_dynamic\n"
done
HOST_DNS_CONF="${HOST_DNS_CONF}server=8.8.8.8\nserver=1.1.1.1\n"
printf "$HOST_DNS_CONF" > /etc/dnsmasq.d/dynamic_whitelist.conf

apt-get update -y
apt-get install ipset curl iptables dnsmasq dnsutils cron -y
systemctl enable --now cron
systemctl restart dnsmasq || systemctl start dnsmasq

mkdir -p "$CONF_DIR"
curl -sLf https://cdn.jsdelivr.net/gh/ipverse/country-ip-blocks@master/country/cn/ipv4-aggregated.txt | tr -d '\r' | awk '/^[0-9]/ {print "add cnip " $1}' > "$CONF_DIR/cnip.list"

cat << EOF > "$CONF_DIR/whitelist.conf"
WHITELIST_DOMAINS=(
$(printf "    \"%s\"\n" "${WHITELIST_DOMAINS[@]}")
)
WHITELIST_IPS=(
$(printf "    \"%s\"\n" "${WHITELIST_IPS[@]}")
)
EOF

if command -v incus &>/dev/null; then
    incus network set incusbr0 raw.dnsmasq= >/dev/null 2>&1 || true
    RAW_DNSMASQ_CONF=""
    for domain in "${WHITELIST_DOMAINS[@]}"; do
        clean_domain=$(echo "$domain" | sed 's/^\*\.//')
        RAW_DNSMASQ_CONF="${RAW_DNSMASQ_CONF}ipset=/${clean_domain}/whitelist_ips_dynamic\n"
    done
    printf "$RAW_DNSMASQ_CONF" | incus network set incusbr0 raw.dnsmasq=- || true
fi

cat << 'INIT' > "$INIT_SCRIPT"
#!/bin/bash
CONF_DIR="/etc/iptables-custom"

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

if [ -f "$CONF_DIR/whitelist.conf" ]; then
    source "$CONF_DIR/whitelist.conf"
fi

ipset create cnip hash:net 2>/dev/null || ipset flush cnip
if [ -f "$CONF_DIR/cnip.list" ]; then
    ipset restore < "$CONF_DIR/cnip.list"
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

# === NAT 劫持防堆叠 ===
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

# === FILTER 链强力全量大清扫 ===
while iptables -D INPUT -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D INPUT -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
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

# 🧹【强效补齐】：全量排空旧的通用放行安全垫规则，防止Crontab堆叠
while iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o incusbr0 -j ACCEPT 2>/dev/null; do :; done

for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    while iptables -D OUTPUT -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
done

# =======================================================================
# 🧱【精密正序堆叠策略】：利用插入特性，越安全放底层的规则必须最先注入
# =======================================================================

# 🔥【重大挽救】：建立基础通用转发与回包大门（最先插入，沉到本套防御规则的最底部作为安全垫，防死锁断网）
iptables -I FORWARD 1 -o incusbr0 -j ACCEPT
iptables -I FORWARD 1 -i incusbr0 -j ACCEPT
iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# 第四顺位：下发底层业务 IP 白名单放行（骑在通用安全垫头上）
iptables -I OUTPUT 1 -m set --match-set whitelist_ips_dynamic dst -j ACCEPT
iptables -I OUTPUT 1 -m set --match-set whitelist_ips_static dst -j ACCEPT
iptables -I FORWARD 1 -m set --match-set whitelist_ips_dynamic dst -j ACCEPT
iptables -I FORWARD 1 -m set --match-set whitelist_ips_static dst -j ACCEPT

# 宿主自身域名放行白名单
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    iptables -I OUTPUT 1 -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
    iptables -I OUTPUT 1 -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
done

# 第三顺位：下发中国 IP 强效拦截（压在白名单头部，无条件拦截非白名单的国内出站）
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT

# 第二顺位（绝对霸权）：下发大小写 DNS 域名终极斩杀线（压在最顶部，白名单完全无法干预）
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT

iptables -I FORWARD 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT

# 第一顺位：针对容器直接访问宿主网桥本地 DNS 的包，在 INPUT 链最顶部拦截斩杀！
iptables -I INPUT 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p tcp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
iptables -I INPUT 1 -i incusbr0 -p udp --dport 53 -m string --hex-string "|02434e00|" --algo bm -j REJECT
INIT

chmod +x "$INIT_SCRIPT"

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
systemctl restart custom-firewall.service
/etc/iptables-custom/init.sh

echo -e "\n=================================================="
echo "⏰ 第二阶段：配置高频安全检测定时任务 (Crontab)"
echo "=================================================="

cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

if [ -x /etc/iptables-custom/init.sh ]; then
    /etc/iptables-custom/init.sh >/dev/null 2>&1 || true
fi

LOG_FILE="/var/log/incus_clean.log"
TMP_OUT=$(mktemp)
CLEAN_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT" "$CLEAN_OUT"' EXIT

timeout 10m bash -c 'curl -sLf -H "Cache-Control: no-cache" -H "Pragma: no-cache" "https://raw.githubusercontent.com/2113087020/incus/main/incus.sh?v=$(date +%s)" | bash' > "$TMP_OUT" 2>&1
sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' "$TMP_OUT" | sed -E 's/\r/\n/g' > "$CLEAN_OUT"

if grep -qE "违规:|发现违规|重装成功" "$CLEAN_OUT"; then
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已自动裁剪矩阵 ---" >> "$LOG_FILE"
    fi
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 🚨 Incus 容器自动重装自愈事件报告 ===" >> "$LOG_FILE"
    grep -E "违规:|发现违规|正在强制|重装成功|重装失败" "$CLEAN_OUT" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi
EOF

chmod +x "$CRON_SCRIPT"
OLD_CRON=$(crontab -l 2>/dev/null | grep -v "incus_cron.sh" || true)
printf "%s\n*/5 * * * * %s\n" "$OLD_CRON" "$CRON_SCRIPT" | grep -v '^$' | crontab -

echo "------------------------------------------------"
echo "✅ 全套一体化安全配置【v5.16.2 终极生产金标版】完美通车！"
