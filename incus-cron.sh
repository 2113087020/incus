#!/bin/bash
# =======================================================================
# Ubuntu/Debian 通用防火墙单向阻断与 Incus 巡检一体化部署脚本 (v5.0 双核封板版)
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

# 1. 操作系统与架构自适应，全局软件源深度安全清洗 (完美兼容 Ubuntu / Debian)
echo "📦 正在全盘扫描并自适应修正系统 APT 软件源..."
OS_TYPE="ubuntu"
if [ -f /etc/os-release ]; then
    if grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"
    fi
fi

ARCH=$(dpkg --print-architecture)

if [ "$OS_TYPE" = "debian" ]; then
    echo "ℹ️  检测到 Debian 系统，官方源锁向 deb.debian.org"
    OFFICIAL_URL="http://deb.debian.org/debian/"
    # 精准清洗国内大厂的 Debian 镜像源路径，绝不误伤三方自定义源
    MATCH_REGEX="s#https?://[^/]*(aliyun|tencent|tsinghua|ustc|huaweicloud)[^/]*/debian/?#${OFFICIAL_URL}#g"
else
    echo "ℹ️  检测到 Ubuntu 系统..."
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

# 2. 安装内核防火墙组件与计划任务组件
echo "📥 正在同步并安装 ipset、curl、iptables 及 cron 守护进程..."
apt-get update -y
apt-get install ipset curl iptables cron -y
systemctl enable --now cron

# 3. 创建配置目录并预下载中国 IP 库
echo "🌐 正在下载并生成最新中国大陆 IP 基础库 (ipset)..."
mkdir -p /etc/iptables-custom
# 下载最新的中国 IP 段（若下载失败，由于 pipefail 机制会立即安全退出，保护旧配置）
curl -sLf http://www.ipdeny.com/ipblocks/data/countries/cn.zone | awk '{print "add cnip " $1}' > /etc/iptables-custom/cnip.list

# 4. 生成独立的本地防火墙原子初始化脚本 (基于位置 1 倒序安全堆叠，彻底免疫索引越界)
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

# 【无损堆叠技术】：全部从位置 1 倒序推入，自动向下挤压，自然形成完美优先级且绝对不报越界错误
# 堆叠后最终顺序：1.UDP DNS阻断 -> 2.TCP DNS阻断 -> 3.IP国界封锁
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT

iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I FORWARD 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
iptables -I FORWARD 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT
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

# 写入后台巡检调度脚本 (内嵌无损堆叠自愈置顶逻辑)
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

if ! ipset list cnip >/dev/null 2>&1; then
    ipset create cnip hash:net 2>/dev/null || ipset flush cnip
    if [ -f /etc/iptables-custom/cnip.list ]; then
        ipset restore < /etc/iptables-custom/cnip.list
    fi
fi

# 5分钟定时强力排空所有旧规则
while iptables -D FORWARD -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done

# 重新以倒序安全堆叠置顶 FORWARD 链
iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true
iptables -I FORWARD 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true
iptables -I FORWARD 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

while iptables -D OUTPUT -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null; do :; done
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done

# 重新以倒序安全堆叠置顶 OUTPUT 链
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true
iptables -I OUTPUT 1 -p tcp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true
iptables -I OUTPUT 1 -p udp --dport 53 -m string --hex-string "|02636e00|" --algo bm -j REJECT 2>/dev/null || true

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
echo "✅ 全套一体化安全配置【通用核准封板】！"
echo "ℹ️  智能识别：原生支持 Ubuntu 22.04 与 Debian 11/12 跨系统自适应换源。"
echo "ℹ️  防线稳固：规则倒序安全堆叠，全局自愈与定时置顶已进入最高戒备状态。"
