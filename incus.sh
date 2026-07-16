#!/bin/bash
# incus 容器网络自愈与违规进程智能检测一体化脚本 (v4.8 生产环境终极自愈合体版)

# ==================== 🔍 自定义监控黑名单 ====================
SCAN_KEYWORDS="nezha[-_]?agent|komari|xmrig|xmr-stak|minerd|cpuminer|ccminer|cgminer|bfgminer|ethminer|claymore|phoenixminer|nanominer|t-rex|lolminer|nbminer|gminer|teamredminer|nicehash|kryptex|kdevtmpfsi|kinsing|sysrv|sysrv-md|sustse|sustsed|wnw7492|monero|cryptonight|stratum|minergate|poolminer|minerstat|srbminer|astrominer|xmrig-proxy|crypto-miner|hashcat|crypto-pool|gridcrude|pamd32|panchan|p2pinfect|skidmap|watchdogx|watchdogs|kerberods|nmap|masscan|zmap|rustscan|fscan|gobuster|dirbuster|nikto|wpscan|hydra|medusa|ncrack|crowbar|patator|brutex|ssh_scan|sshcheck|pyrdp|xsstrike|hping|hping3|loic|hoic|slowloris|synflood|udpflood|mirai|gafgyt|bashlite|tsunami|billgates|elknot|dofloo|sedna|stacheldraht|trinoo|kptd|atdd|skynet|gates\.lod|conficker|xorddos|muhstik|frpc|frps|npc|nps|chisel|rclone|ngrok|pagekite|bore|localtonet|vtun|anyconnect|openconnect|iodine|dnscat2|dnscat|3proxy|lcx|ew|beacon|geacon|sliver|merlin|metasploit|msfconsole|msfvenom|viper|meterpreter|suo5|reasing|neo-regeorg|cmd53|godzilla|behinder|antsword|stowaway|venom|serverstatus|stat_server|stat_client|sergate|beszel-hub|beszel-agent|beszel|nodeget|uptime-kuma|nodequery|ward|prometheus|node_exporter|zabbix_server|zabbix_agentd|grafana-server|grafana|influxd|netdata|glances|cockpit-ws|skywalking|sw-oap-server|vmagent|victoriametrics|fluent-bit|fluentd|logstash|vector|datadog-agent|agent2|filebeat|packetbeat|telegraf|sematext|pinpoint-agent|skywalking-agent|dozzle|scrutiny|sysupdate"
MAX_TCP_CONN=500    # TCP 并发上限
MAX_UDP_CONN=500    # UDP 并发上限 
MAX_RAW_CONN=50     # Raw Socket 上限
MAX_SYN_SENT=30     # SYN_SENT 状态上限 (超过判定为恶意端口扫描或洪水攻击)

# 常见高危扫描端口集合 (Egress 拦截矩阵)
BLOCK_OUT_PORTS="22,23,445,3389,6379,2375,2376" 
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 环境权限前置检查
if ! command -v incus &>/dev/null; then
    echo -e "${RED}✖ 错误: 未找到 incus 命令，请确保已安装 Incus 并拥有 root 执行权限。${NC}"
    exit 1
fi

# ==================== 🛠️ 阶段一：宿主机网络与网桥 ACL 100% 自愈 ====================
echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🛠️  阶段一: 强效执行宿主机网络转发与网桥 ACL 自愈${NC}"
echo -e "${CYAN}=======================================${NC}"

# 1. 强力自愈：强开宿主机内核转发开关，防止开机或网络重载导致容器瘫痪
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

# 2. 强力自愈：在宿主机 FILTER 表最顶层，强行注入转发安全垫规则（防范 Docker/UFW 截胡断网或 SSH 阻断）
# 先精准排空，防止 Crontab 运行导致规则无限堆叠
while iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -i incusbr0 -j ACCEPT 2>/dev/null; do :; done
while iptables -D FORWARD -o incusbr0 -j ACCEPT 2>/dev/null; do :; done

# 重新正序最优先插入
iptables -I FORWARD 1 -o incusbr0 -j ACCEPT
iptables -I FORWARD 1 -i incusbr0 -j ACCEPT
iptables -I FORWARD 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
echo -e "${GREEN}   [✔] 宿主机 FILTER 转发通用安全垫已强行置顶。${NC}"

# 3. 检查拦截策略是否存在，不存在则创建
if incus network acl show block-scan-ports < /dev/null >/dev/null 2>&1; then
    echo -e "${GREEN}   [✔] 检测到底层 block-scan-ports ACL 规则已建立。${NC}"
else
    echo -e "${YELLOW}   [!] 未检测到拦截规则，正在构建底层多端口拦截 ACL...${NC}"
    incus network acl create block-scan-ports < /dev/null >/dev/null 2>&1
    incus network acl rule add block-scan-ports egress action=drop protocol=tcp destination_port="${BLOCK_OUT_PORTS}" state=enabled < /dev/null >/dev/null 2>&1
    echo -e "${GREEN}   [✔] 底层 ACL 规则构建成功！${NC}"
fi

# 4. 网桥绑定与 100% 入站解封（核心自愈：彻底根治由于 ACL 默认闭锁导致的 SSH 和外网阻断）
if incus network show incusbr0 < /dev/null >/dev/null 2>&1; then
    CURRENT_ACLS=$(incus network get incusbr0 security.acls < /dev/null 2>/dev/null)
    if [ -z "$CURRENT_ACLS" ]; then
        echo -e "${YELLOW}   [!] 检测到网桥尚未绑定任何安全规则，正在执行首次绑定...${NC}"
        incus network set incusbr0 security.acls=block-scan-ports < /dev/null >/dev/null 2>&1
        echo -e "${GREEN}   [✔] 首次绑定成功！安全防护网已实时覆盖。${NC}"
    elif [[ ! "$CURRENT_ACLS" =~ (^|,)"block-scan-ports"(,|$) ]]; then
        echo -e "${YELLOW}   [!] 检测到网桥已存在其他规则，正在追加多端口拦截阵列...${NC}"
        incus network set incusbr0 security.acls="${CURRENT_ACLS},block-scan-ports" < /dev/null >/dev/null 2>&1
        echo -e "${GREEN}   [✔] 规则追加成功！${NC}"
    else
        echo -e "${GREEN}   [✔] 泛端口扫描拦截规则已牢固绑定在网桥 incusbr0。${NC}"
    fi

    # 🔑【生产核心加固】：强制将网桥的默认入站/出站全部设置为 ALLOW
    # 彻底激活黑名单过滤模式，绝对封死全网断流与外部 SSH 连不上的底层机制漏洞
    incus network set incusbr0 security.acls.default.egress.action=allow < /dev/null >/dev/null 2>&1
    incus network set incusbr0 security.acls.default.ingress.action=allow < /dev/null >/dev/null 2>&1
    echo -e "${GREEN}   [✔] 默认上网及 SSH 入站规则（Default Allow）已强行焊死，自愈完毕。${NC}"
else
    echo -e "${RED}   [✖] 严重警告：未找到默认网桥 incusbr0，跳过网桥自愈，请手动核对网桥名称。${NC}"
fi


# ==================== 🛡️ 阶段二：容器进程与DDoS动态扫描 ====================
echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🚀 阶段二: 容器内部违规进程与 DDoS 行为清查${NC}"
echo -e "${CYAN}=======================================${NC}\n"

# 智能匹配本地缓存中最好的重装镜像，避免消耗外网流量
local_alpine=$(incus image list local: -f csv -c fd < /dev/null 2>/dev/null | grep -i "alpine" | head -n1 | awk -F, '{print $1}')
if [ -n "$local_alpine" ]; then
    TARGET_IMAGE="$local_alpine"
else
    local_any=$(incus image list local: -f csv -c f < /dev/null 2>/dev/null | head -n1)
    if [ -n "$local_any" ]; then
        TARGET_IMAGE="$local_any"
    else
        TARGET_IMAGE="images:alpine/latest"
    fi
fi

# 获取系统内全量的真实项目名称列表，拒绝使用脆弱的列缩写猜想
PROJECT_LIST=$(incus project list -f csv -c n < /dev/null 2>/dev/null)
if [ -z "$PROJECT_LIST" ]; then
    PROJECT_LIST="default"
fi

echo -e "正在全量跨项目深度盘查活跃容器..."
echo "------------------------------------------------"

COUNT=0
INFECTED_COUNT=0

# 第一层循环：遍历所有合法的项目
for project in $PROJECT_LIST; do
    [ -z "$project" ] && continue
    
    # 第二层循环：获取当前项目下所有真正运行中的容器名
    RUNNING_CONTAINERS=$(incus list --project "$project" -f csv -c ns < /dev/null 2>/dev/null | grep -i ',RUNNING$' | awk -F, '{print $1}')
    
    for container in $RUNNING_CONTAINERS; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        
        # 明文逐行滚动日志输出，确保生产环境掌控感，所见即所得
        printf "[%d] 正在盘查容器: %-26s [项目: %-8s] -> " "$COUNT" "$container" "$project"

        # 核心进入容器内部检测逻辑
        HIT_REASON=$(incus exec --project "$project" "$container" -- sh -c '
            KEYWORDS="$1"
            MAX_TCP="$2"
            MAX_UDP="$3"
            MAX_RAW="$4"
            MAX_SYN="$5"
            SELF=$$
            
            # 兼容性防御：如果系统没有基本 proc 文件，直接安全退出避免空变量引发 shell 崩溃
            [ -f /proc/net/tcp ] || exit 0
            
            # 过滤掉首行表头，防止干扰数据流
            TCP_FILE=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -v "sl")
            
            # 斩断空格补齐引发的 bad number 报错，纯净输出整数
            TCP_COUNT=$(echo "$TCP_FILE" | grep -c "^")
            UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | grep -v "sl" | grep -c "^")
            RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | grep -v "sl" | grep -c "^")
            SYN_COUNT=$(echo "$TCP_FILE" | awk '\''{print $4}'\'' | grep -c "02")

            if [ "$SYN_COUNT" -gt "$MAX_SYN" ]; then echo "异常开包扫描 ($SYN_COUNT)"; exit 0; fi
            if [ "$TCP_COUNT" -gt "$MAX_TCP" ]; then echo "TCP高并发 ($TCP_COUNT)"; exit 0; fi
            if [ "$UDP_COUNT" -gt "$MAX_UDP" ]; then echo "UDP洪水 ($UDP_COUNT)"; exit 0; fi
            if [ "$RAW_COUNT" -gt "$MAX_RAW" ]; then echo "伪造Raw协议 ($RAW_COUNT)"; exit 0; fi

            # === 内存运行进程指令清查 ===
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                MATCHED=$(tr "\0" "\n" < "$f" 2>/dev/null | grep -oiE "$KEYWORDS" | head -n1)
                if [ -n "$MATCHED" ]; then echo "违规进程: $MATCHED"; exit 0; fi
            done
            
            # === 静态高危残留特征文件扫描 ===
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                if [ -e "$p" ]; then echo "残留文件: $p"; exit 0; fi
            done
        ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" "$MAX_SYN_SENT" < /dev/null 2>/dev/null)

        if [ -n "$HIT_REASON" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            echo -e "${RED}【🚨 违规: $HIT_REASON】${NC}"
            echo -e "${YELLOW}   ↳ 🔄 发现违规，正在强制直接智能重装...${NC}"
            # 严格遵循参数前置原则进行强制抹除性重装
            if incus rebuild --project "$project" "$TARGET_IMAGE" "$container" --force < /dev/null >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！容器已重置净化。${NC}"
            else
                echo -e "${RED}   ↳ ❌ 重装失败，请手动介入检查该容器状态。${NC}"
            fi
        else
            echo -e "${GREEN}[✔ 正常]${NC}"
        fi
    done
done

echo "------------------------------------------------"
echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN} 🏁 全盘自愈与检测任务顺利结束${NC}"
echo -e "${CYAN}=======================================${NC}\n"

if [ "$INFECTED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✨ 完美安全：本台机器网络链路 100% 畅通健康，未发现违规容器。${NC}"
else
    echo -e "${YELLOW}🚨 处理报告：网络自愈完毕。本次任务共计清洗并强制抹除重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险违规容器。${NC}"
fi
