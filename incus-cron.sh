#!/bin/bash
# =======================================================================
# Linux 通用防火墙单向阻断与 Incus 巡检一体化部署脚本 (v5.9.2 终极无损版)
# =======================================================================

# 开启顶级严格错误追踪与管道熔断，全局死锁保护
set -e
set -o pipefail

# =======================================================================
# 🌟 全局自定义双重白名单配置 (在此修改，自动同步至所有自愈组件)
# =======================================================================
WHITELIST_DOMAINS=(
    "zstaticcdn.com"
    "*.zstaticcdn.com"  # Zoom 视频会议官方静态 CDN 资源放行
)

WHITELIST_IPS=(
    "1.1.1.1"
    "8.8.8.8"           # 常用上游纯净公共 DNS 放行
)
# =======================================================================

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"
INIT_SCRIPT="/etc/iptables-custom/init.sh"
CONF_DIR="/etc/iptables-custom"
LOG_FILE="/var/log/incus_clean.log"

echo "=================================================="
echo "🛡️  第一阶段：配置单向阻断防火墙与宿主 DNS 劫持"
echo "=================================================="

# 1. 变量化自适应解析，彻底解决 Ubuntu/Debian 模糊血统误判 Bug
echo "📦 正在全盘扫描并自适应修正系统 APT 软件源..."
OS_TYPE="ubuntu"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ]; then
        OS_TYPE="debian"
    fi
fi

ARCH=$(dpkg --print-architecture)

if [ "$OS_TYPE" = "debian" ]; then
    echo "ℹ️  检测到纯正 Debian 系统，官方源锁向 deb.debian.org"
    OFFICIAL_URL="http://deb.debian.org/debian/"
    MATCH_REGEX="s#https?://[^/]*(aliyun|tencent|tsinghua|ustc|huaweicloud)[^/]*/debian/?#${OFFICIAL_URL}#g"
else
    echo "ℹ️  检测到纯正 Ubuntu 系统..."
    if [ "$ARCH" = "arm64" ]; then
        echo "ℹ️  检测到 ARM64 架构，官方源锁向 ports.ubuntu.com"
        OFFICIAL_URL="http://ports.ubuntu.com/ubuntu-ports/"
    else
        echo "ℹ️  检测到 x86_64 架构，官方源锁向 archive.ubuntu.com/ubuntu/"
        OFFICIAL_URL="http://archive.ubuntu.com/ubuntu/"
    fi
    MATCH_REGEX="s#https?://[^/]*(aliyun|tencent|tsinghua|ustc|huaweicloud)[^/]*/(ubuntu-ports|ubuntu)/?#${OFFICIAL_URL}#g"
fi

# 深度清洗：全局扫描子目录，只有当文件中确实包含国内镜像源时才触发原子替换
find /etc/apt/ -name "*.list" -type f | while read -r list_file; do
    if grep -qE "aliyun|tencent|tsinghua|ustc|huaweicloud" "$list_file"; then
        echo "⚠️  正在安全清洗国内镜像源文件: $list_file"
        sed -i -E "${MATCH_REGEX}" "$list_file"
    fi
done

# 2. 提前创建 dnsmasq 53535 物理隔离配置，彻底消除安装阶段的 Socket 冲突
echo "⚙️  正在预配置 dnsmasq 隔离解析沙箱 (监听 53535)..."
mkdir -p /etc/dnsmasq.d
cat << 'DNS' > /etc/dnsmasq.d/dynamic_whitelist.conf
# 🌟 绝对安全：避开 53 端口，强绑定本地高端口 53535，绝不引发 Socket 冲突
port=53535
listen-address=127.0.0.1
bind-interfaces

# 🌟 核心拦截：当宿主机解析 zstaticcdn.com 及其子域名时，自动将 IP 动态写入 whitelist_ips_dynamic
ipset=/zstaticcdn.com/whitelist_ips_dynamic

# 干净的上游 DNS 转发源
server=8.8.8.8
server=1.1.1.1
DNS

# 3. 安装内核防火墙组件、DNS解析组件与计划任务组件
echo "📥 正在同步并安装 ipset、curl、iptables、dnsmasq、dnsutils 及 cron..."
apt-get update -y
apt-get install ipset curl iptables dnsmasq dnsutils cron -y
systemctl enable --now cron

# 重启或启动 dnsmasq 服务
systemctl restart dnsmasq || systemctl start dnsmasq

# 4. 改用 ipverse 官方高频维护的国内 IP 镜像库
echo "🌐 正在下载并生成最新中国大陆 IP 基础库 (ipset)..."
mkdir -p "$CONF_DIR"
curl -sLf https://cdn.jsdelivr.net/gh/ipverse/country-ip-blocks@master/country/cn/ipv4-aggregated.txt | tr -d '\r' | awk '/^[0-9]/ {print "add cnip " $1}' > "$CONF_DIR/cnip.list"

# 5. 生成统一白名单配置文件
echo "📝 正在构建本地统一白名单配置文件..."
cat << EOF > "$CONF_DIR/whitelist.conf"
# 自动生成的白名单配置文件 (由部署脚本 v5.9.2 托管配置)
WHITELIST_DOMAINS=(
$(printf "    \"%s\"\n" "${WHITELIST_DOMAINS[@]}")
)

WHITELIST_IPS=(
$(printf "    \"%s\"\n" "${WHITELIST_IPS[@]}")
)
EOF

# 6. 🧹【物理清理残留】：将容器侧的动态白名单残留彻底抹除
if command -v incus &>/dev/null; then
    echo "🧹 正在清理 Incus 网桥残留的 raw.dnsmasq 规则..."
    incus network unset incusbr0 raw.dnsmasq || true
fi

# 7. 生成独立的本地防火墙原子初始化脚本 (已彻底修复 Shebang Typo)
echo "📝 正在构建本地独立防火墙自愈脚本..."
cat << 'INIT' > "$INIT_SCRIPT"
#!/bin/bash
CONF_DIR="/etc/iptables-custom"

# 载入统一白名单配置
if [ -f "$CONF_DIR/whitelist.conf" ]; then
    source "$CONF_DIR/whitelist.conf"
fi

# 在内存中创建或清空集合
ipset create cnip hash:net 2>/dev/null || ipset flush cnip
if [ -f "$CONF_DIR/cnip.list" ]; then
    ipset restore < "$CONF_DIR/cnip.list"
fi

# 创建 IP 静态与动态白名单集合
ipset create whitelist_ips_static hash:net 2>/dev/null || ipset flush whitelist_ips_static
# 动态集合绝不 flush，完美保留已建立连接的 CDN 动态 IP
ipset create whitelist_ips_dynamic hash:net 2>/dev/null || true

# 自动解析白名单域名的当前 IP 并追加进静态白名单
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    ips=$(dig +short "$clean_domain" 2>/dev/null | grep -E '^[0-9.]+$') || true
    for ip in $ips; do
        ipset add whitelist_ips_static "$ip" 2>/dev/null || true
    done
done

# 追加手动写入的白名单静态 IP
for ip in "${WHITELIST_IPS[@]}"; do
    ipset add whitelist_ips_static "$ip" 2>/dev/null || true
done


# =======================================================================
# 🔥【NAT 劫持与死锁防护】：物理隔离劫持所有本地 DNS 流量并扭送至 53535
# =======================================================================
# 强力排空 nat 表中的旧重定向规则，防止堆叠垃圾
while iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p udp --dport 53 -m owner --uid-owner nobody -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -m owner --uid-owner nobody -j ACCEPT 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done
while iptables -t nat -D OUTPUT -p tcp --dport 53 -j REDIRECT --to-ports 53535 2>/dev/null; do :; done

# 🧱【无损倒序堆叠 nat 规则】：后写的最先匹配
# REDIRECT 规则在最底层
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -j REDIRECT --to-ports 53535
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -j REDIRECT --to-ports 53535

# Loop 防护规则骑在 REDIRECT 规则头上，确保 dnsmasq 自身的上游查询放行，不发生死锁
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -m owner --uid-owner nobody -j ACCEPT
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -m owner --uid-owner nobody -j ACCEPT
iptables -t nat -I OUTPUT 1 -p tcp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT
iptables -t nat -I OUTPUT 1 -p udp --dport 53 -m owner --uid-owner dnsmasq -j ACCEPT


# =======================================================================
# 🧱【FILTER 规则】：清洗并下发包过滤与阻断逻辑
# =======================================================================
# 强力排空 filter 表中的旧阻断与斩杀规则
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done

# 清理旧 of 白名单放行规则
while iptables -D OUTPUT -m set --match-set whitelist_ips_static dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -m set --match-set whitelist_ips_static dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set whitelist_ips_dynamic dst -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -m set --match-set whitelist_ips_dynamic dst -j ACCEPT 2>/dev/null; do :; done

for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    while iptables -D OUTPUT -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
    while iptables -D FORWARD -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT 2>/dev/null; do :; done
done

# 🧱【第三优先级：IP 阻断与 DNS 斩杀】
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT

# 🧱 容器侧一刀切严格闭锁
iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I FORWARD 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT

# 🧱【第二优先级：DNS 放行白名单】 (仅限宿主机自身 OUTPUT 链)
for domain in "${WHITELIST_DOMAINS[@]}"; do
    clean_domain=$(echo "$domain" | sed 's/^\*\.//')
    iptables -I OUTPUT 1 -p udp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
    iptables -I OUTPUT 1 -p tcp --dport 53 -m string --string "$clean_domain" --algo bm -j ACCEPT
done

# 🧱【第一优先级：IP 放行白名单】 (最高顺位，仅限宿主机自身 OUTPUT 链，绝对置顶)
iptables -I OUTPUT 1 -m set --match-set whitelist_ips_dynamic dst -j ACCEPT
iptables -I OUTPUT 1 -m set --match-set whitelist_ips_static dst -j ACCEPT
INIT

chmod +x "$INIT_SCRIPT"

# 8. 构建 systemd 服务实现开机自愈托管
echo "⚙️ 正在构建守护服务，彻底锁定开机加载顺序..."
cat << 'SERVICE' > /etc/systemd/system/custom-firewall.service
[Unit]
Description=Custom Outbound Firewall for Host and Incus Containers
After=network.target
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/iptables-custom/init.sh

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable custom-firewall.service

# 强行打穿 Oneshot 缓存重新加载自愈脚本并立即在 Shell 生效
systemctl restart custom-firewall.service
/etc/iptables-custom/init.sh


echo -e "\n=================================================="
echo "⏰ 第二阶段：配置高频安全检测定时任务 (Crontab)"
echo "=================================================="

echo "📦 正在配置定时任务调度外壳..."

# 写入后台巡检调度脚本
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

# 1. 5分钟定时强制触发防火墙自愈与规则置顶
if [ -x /etc/iptables-custom/init.sh ]; then
    /etc/iptables-custom/init.sh >/dev/null 2>&1 || true
fi

# 2. 执行 Incus 容器特征扫描与重装巡检
LOG_FILE="/var/log/incus_clean.log"
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

timeout 10m bash -c 'curl -sLf --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/2113087020/incus/main/incus.sh | bash' > "$TMP_OUT" 2>&1

if grep -q "发现违规特征" "$TMP_OUT"; then
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已裁剪 ---" >> "$LOG_FILE"
    fi
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 拦截与重装记录 ===" >> "$LOG_FILE"
    grep -E "发现违规特征|重装成功|重装失败" "$TMP_OUT" | sed -E 's/\r/\n/g' | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | grep -E "发现违规特征|重装成功|重装失败" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi
EOF

echo "🔐 赋予外壳脚本执行权限..."
chmod +x "$CRON_SCRIPT"

echo "⏰ 正在配置每 5 分钟高频安全检测 (Crontab)..."
OLD_CRON=$(crontab -l 2>/dev/null | grep -v "incus_cron.sh" || true)
printf "%s\n*/5 * * * * %s\n" "$OLD_CRON" "$CRON_SCRIPT" | grep -v '^$' | crontab -

echo "------------------------------------------------"
echo "✅ 全套一体化安全配置【v5.9.2 宿主专属无损完全体版】！"
echo "ℹ️  极速 IP：中国 IP 库已通过 ipverse 官方源刷新装载。"
echo "ℹ️  宿主动态放行：仅放行宿主机自身的 CDN 白名单解析与连接。"
