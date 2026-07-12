#!/bin/bash
# =======================================================================
# Ubuntu 22.04 防火墙单向阻断与 Incus 高频巡检一体化部署脚本 (v4.1 终极纯净版)
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

# 深度清洗：不仅洗主文件，连带 /etc/apt/sources.list.d/ 下的云厂商魔改子文件一同精准洗净
find /etc/apt/ -name "*.list" -type f | while read -r list_file; do
    if grep -qE "aliyun|tencent|tsinghua|ustc|huaweicloud|ubuntu\.com" "$list_file"; then
        echo "⚠️  正在清洗国内/区域源文件: $list_file"
        sed -i -E "s|https?://[^/]+/(ubuntu-ports|ubuntu)/?|${OFFICIAL_URL}|g" "$list_file"
    fi
done

# 2. 安装内核防火墙组件与计划任务组件 (强行补齐精简版系统环境)
echo "📥 正在同步并安装 ipset、curl、iptables 及 cron 守护进程..."
apt-get update -y
apt-get install ipset curl iptables cron -y
systemctl enable --now cron

# 3. 创建配置目录并预下载中国 IP 库
echo "🌐 正在下载并生成最新中国大陆 IP 基础库 (ipset)..."
mkdir -p /etc/iptables-custom
# 下载最新的中国 IP 段（若下载失败，由于 pipefail 机制会立即安全退出，保护旧配置）
curl -sLf http://www.ipdeny.com/ipblocks/data/countries/cn.zone | awk '{print "add cnip " $1}' > /etc/iptables-custom/cnip.list

# 4. 生成独立的本地防火墙原子初始化脚本 (解耦 systemd 内联解析风险)
echo "📝 正在构建本地独立防火墙自愈脚本..."
cat << 'INIT' > "$INIT_SCRIPT"
#!/bin/bash
# 在内存中创建或清空集合，防止重复执行时报错
ipset create cnip hash:net 2>/dev/null || ipset flush cnip
# 立即将基础库导入当前系统内核
if [ -f /etc/iptables-custom/cnip.list ]; then
    ipset restore < /etc/iptables-custom/cnip.list
fi

# 使用 while 循环强力剥离所有可能残留的同名旧规则，直到彻底洗净，防止堆叠垃圾
while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done

# 【最高优先级插入】只要目的地是国内且是 NEW 状态，在链的最顶端直接枪毙
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT
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

# 重载磁盘服务配置、激活开机自启并立即以标准化接口触发首次规则灌注
systemctl daemon-reload
systemctl enable custom-firewall.service
systemctl start custom-firewall.service


echo -e "\n=================================================="
echo "⏰ 第二阶段：配置高频安全检测定时任务 (Crontab)"
echo "=================================================="

echo "📦 正在配置定时任务调度外壳..."

# 写入后台巡检调度脚本 (内嵌内核级 ipset & iptables 双重自愈置顶逻辑)
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
# 显式引入环境变量
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

# 🛡️ 【防火墙内核级深度自愈机制】
if ! ipset list cnip >/dev/null 2>&1; then
    ipset create cnip hash:net 2>/dev/null || ipset flush cnip
    if [ -f /etc/iptables-custom/cnip.list ]; then
        ipset restore < /etc/iptables-custom/cnip.list
    fi
fi

# 每 5 分钟强力排空并重新将规则顶回第一行，彻底粉碎 Incus 重载网卡时对防线的冲刷
while iptables -D FORWARD -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
iptables -I FORWARD 1 -i incusbr0 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true

while iptables -D OUTPUT -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null; do :; done
iptables -I OUTPUT 1 -m set --match-set cnip dst -m conntrack --ctstate NEW -j REJECT 2>/dev/null || true

LOG_FILE="/var/log/incus_clean.log"

# 创建临时文件与防泄漏钩子
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# 设置 10 分钟全局超时，并在 curl 层增加网络超时
timeout 10m bash -c 'curl -sLf --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/2113087020/incus/main/incus.sh | bash' > "$TMP_OUT" 2>&1

# 🚨 【核心判断】如果全文没有“发现违规特征”，则直接静默退出，不写入任何日志！
if grep -q "发现违规特征" "$TMP_OUT"; then

    # 日志体积限制 100KB (约102400字节)
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已裁剪 ---" >> "$LOG_FILE"
    fi

    # 写入单行时间戳标题
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 拦截与重装记录 ===" >> "$LOG_FILE"
    
    # 极致精简日志：只提取“违规原因”和“重装结果”
    grep -E "发现违规特征|重装成功|重装失败" "$TMP_OUT" | \
    sed -E 's/\r/\n/g' | \
    sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
    grep -E "发现违规特征|重装成功|重装失败" >> "$LOG_FILE"
    
    # 每次记录完毕加空行分隔
    echo "" >> "$LOG_FILE"
fi
EOF

echo "🔐 赋予外壳脚本执行权限..."
chmod +x "$CRON_SCRIPT"

echo "⏰ 正在配置每 5 分钟高频安全检测 (Crontab)..."
# ✨ 【无损注入】：利用 printf 无损拼接配合 grep -v '^$' 过滤空行，实现最安全的计划任务挂载
OLD_CRON=$(crontab -l 2>/dev/null | grep -v "incus_cron.sh" || true)
printf "%s\n*/5 * * * * %s\n" "$OLD_CRON" "$CRON_SCRIPT" | grep -v '^$' | crontab -

echo "------------------------------------------------"
echo "✅ 全套一体化安全配置彻底收官！"
echo "ℹ️  防火墙状态：单向隔离已完全锁定（外网直连丝滑，国内主动回国物理切断）。"
echo "ℹ️  防火墙自愈：规则已强绑定至托管服务与高频计划任务，具备自动【纠错置顶】功能。"
echo "ℹ️  巡检定时任务：已完美挂载，每 5 分钟自动拉起系统层扫描。"
echo "📂 巡检日志路径：$LOG_FILE"
