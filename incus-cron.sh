#!/bin/bash
# =======================================================================
# Ubuntu 22.04 防火墙单向阻断与 Incus 高频巡检一体化部署脚本 (v4.3 终极封顶版)
# =======================================================================

# 开启顶级严格错误追踪与管道熔断，全局死锁保护
set -e
set -o pipefail

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"
INIT_SCRIPT="/etc/iptables-custom/init.sh"
LOG_FILE="/var/log/incus_clean.log"

echo "=================================================="
echo "🛡️  第一阶段：配置单向阻断防火墙 (Host + Incus)"
echo "=================================================="

# 1. 架构自适应与 APT 全局软件源深度清洗 (主文件 + 子文件全覆盖)
echo "📦 正在全盘扫描并修正系统 APT 软件源..."
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "arm64" ]; then
    echo "ℹ️  检测到 ARM64 架构，官方源锁向 ports.ubuntu.com"
    OFFICIAL_URL="http://ports.ubuntu.com/ubuntu-ports/"
else
    echo "ℹ️  检测到 x86_64 架构，官方源锁向 archive.ubuntu.com/ubuntu/"
    OFFICIAL_URL="http://archive.ubuntu.com/ubuntu/"
fi

find /etc/apt/ -name "*.list" -type f | while read -r list_file; do
    if grep -qE "aliyun|tencent|tsinghua|ustc|huaweicloud|ubuntu\.com" "$list_file"; then
        echo "⚠️  正在清洗国内/区域源文件: $list_file"
        sed -i -E "s#https?://[^/]+/(ubuntu-ports|ubuntu)/?#${OFFICIAL_URL}#g" "$list_file"
    fi
done

# 2. 安装内核防火墙组件与计划任务组件
echo "📥 正在同步并安装 ipset、curl、iptables 及 cron 守护进程..."
apt-get update -y
apt-get install ipset curl iptables cron -y
systemctl enable --now cron

# 3. 创建配置目录并预下载中国 IP 库
echo "🌐 正在下载并生成最新中国大陆 IP 基础库 (ipset)..."
mkdir -p /etc/iptables-custom
curl -sLf http://www.ipdeny.com/ipblocks/data/countries/cn.zone | awk '{print "add cnip " $1}' > /etc/iptables-custom/cnip.list

# 4. 生成独立的本地防火墙原子初始化脚本 (融合全局 .cn 域名劫持技术)
echo "📝 正在构建本地独立防火墙自愈脚本..."
cat << 'INIT' > "$INIT_SCRIPT"
#!/bin/bash
# 在内存中创建或清空集合
ipset create cnip hash:net 2>/dev/null || ipset flush cnip
if [ -f /etc/iptables-custom/cnip.list ]; then
    ipset restore < /etc/iptables-custom/cnip.list
fi

# 强力排空残留的旧版规则，防止堆叠垃圾
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done

# 🔥【最高优先级层：DNS 协议特征阻断】斩断 Host 与 容器对所有全球 .cn 域名的解析请求
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT

# 🧱【第二优先级层：IP 封锁层】对漏网的非 .cn 国内硬核 IP 阻断 NEW 连接
iptables -I OUTPUT 5 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I FORWARD 5 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
INIT

chmod +x "$INIT_SCRIPT"

# 5. 构建 systemd 服务实现开机自愈托管
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
systemctl start custom-firewall.service


echo -e "\n=================================================="
echo "⏰ 第二阶段：配置高频安全检测定时任务 (Crontab)"
echo "=================================================="

echo "📦 正在配置定时任务调度外壳..."

# 写入后台巡检调度脚本 (同步嵌入 DNS 级别的自愈和绝对置顶逻辑)
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

if ! ipset list cnip >/dev/null 2>&1; then
    ipset create cnip hash:net 2>/dev/null || ipset flush cnip
    if [ -f /etc/iptables-custom/cnip.list ]; then
        ipset restore < /etc/iptables-custom/cnip.list
    fi
fi

# 5分钟定时强制清洗并置顶 DNS 阻断规则与 IP 阻断规则
while iptables -D FORWARD -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
iptables -I FORWARD 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

while iptables -D FORWARD -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
iptables -I FORWARD 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
iptables -I FORWARD 5 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true

while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
iptables -I OUTPUT 5 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true

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
echo "✅ 全套一体化安全配置【终极封顶】！"
echo "ℹ️  新增长矛：全球所有以 .cn 结尾的域名已被就地剥夺解析权（海外节点同罪）。"
echo "ℹ️  防线自愈：每 5 分钟自动执行【DNS置顶 + IP洗净】，双层过滤网达成。"
