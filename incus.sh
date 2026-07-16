#!/bin/bash
# incus 容器网络防护与违规进程智能检测一体化脚本 (v4.1 滚动日志明文版)

SCAN_KEYWORDS="nezha[-_]?agent|komari|xmrig|xmr-stak|minerd|cpuminer|ccminer|cgminer|bfgminer|ethminer|claymore|phoenixminer|nanominer|t-rex|lolminer|nbminer|gminer|teamredminer|nicehash|kryptex|kdevtmpfsi|kinsing|sysrv|sysrv-md|sustse|sustsed|wnw7492|monero|cryptonight|stratum|minergate|poolminer|minerstat|srbminer|astrominer|xmrig-proxy|crypto-miner|hashcat|crypto-pool|gridcrude|pamd32|panchan|p2pinfect|skidmap|watchdogx|watchdogs|kerberods|nmap|masscan|zmap|rustscan|fscan|gobuster|dirbuster|nikto|wpscan|hydra|medusa|ncrack|crowbar|patator|brutex|ssh_scan|sshcheck|pyrdp|xsstrike|hping|hping3|loic|hoic|slowloris|synflood|udpflood|mirai|gafgyt|bashlite|tsunami|billgates|elknot|dofloo|sedna|stacheldraht|trinoo|kptd|atdd|skynet|gates\.lod|conficker|xorddos|muhstik|frpc|frps|npc|nps|chisel|rclone|ngrok|pagekite|bore|localtonet|vtun|anyconnect|openconnect|iodine|dnscat2|dnscat|3proxy|lcx|ew|beacon|geacon|sliver|merlin|metasploit|msfconsole|msfvenom|viper|meterpreter|suo5|reasing|neo-regeorg|cmd53|godzilla|behinder|antsword|stowaway|venom|serverstatus|stat_server|stat_client|sergate|beszel-hub|beszel-agent|beszel|nodeget|uptime-kuma|nodequery|ward|prometheus|node_exporter|zabbix_server|zabbix_agentd|grafana-server|grafana|influxd|netdata|glances|cockpit-ws|skywalking|sw-oap-server|vmagent|victoriametrics|fluent-bit|fluentd|logstash|vector|datadog-agent|agent2|filebeat|packetbeat|telegraf|sematext|pinpoint-agent|skywalking-agent|dozzle|scrutiny|sysupdate"
MAX_TCP_CONN=500
MAX_UDP_CONN=500
MAX_RAW_CONN=50
MAX_SYN_SENT=30
BLOCK_OUT_PORTS="22,23,445,3389,6379,2375,2376"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if ! command -v incus &> /dev/null; then
    echo -e "${RED}✖ 错误: 未找到 incus 命令。${NC}"
    exit 1
fi

# ==================== 🛡️ 阶段一：网络安全防护检测与安装 ====================
echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🛡️ 阶段一: 检测/安装全局网络拦截防火墙${NC}"
echo -e "${CYAN}=======================================${NC}"

if incus network acl show block-scan-ports < /dev/null >/dev/null 2>&1; then
    echo -e "${GREEN}   [✔] 检测到底层 block-scan-ports ACL 规则已建立。${NC}"
else
    echo -e "${YELLOW}   [!] 未检测到拦截规则，正在构建底层多端口拦截 ACL...${NC}"
    incus network acl create block-scan-ports < /dev/null >/dev/null 2>&1
    incus network acl rule add block-scan-ports egress action=drop protocol=tcp destination_port="${BLOCK_OUT_PORTS}" state=enabled < /dev/null >/dev/null 2>&1
    echo -e "${GREEN}   [✔] 底层 ACL 规则构建成功！${NC}"
fi

if incus network show incusbr0 < /dev/null >/dev/null 2>&1; then
    CURRENT_ACLS=$(incus network get incusbr0 security.acls < /dev/null 2>/dev/null)
    if [ -z "$CURRENT_ACLS" ]; then
        echo -e "${YELLOW}   [!] 检测到网桥尚未绑定任何安全规则，正在执行首次绑定...${NC}"
        incus network set incusbr0 security.acls block-scan-ports < /dev/null >/dev/null 2>&1
        echo -e "${GREEN}   [✔] 首次绑定成功！安全防护网已实时覆盖。${NC}"
    elif [[ ! "$CURRENT_ACLS" =~ (^|,)"block-scan-ports"(,|$) ]]; then
        echo -e "${YELLOW}   [!] 检测到网桥已存在其他规则，正在追加多端口拦截阵列...${NC}"
        incus network set incusbr0 security.acls "${CURRENT_ACLS},block-scan-ports" < /dev/null >/dev/null 2>&1
        echo -e "${GREEN}   [✔] 规则追加成功！${NC}"
    else
        echo -e "${GREEN}   [✔] 泛端口扫描拦截规则已牢固绑定在网桥 incusbr0。${NC}"
    fi
else
    echo -e "${RED}   [✖] 未找到默认网桥 incusbr0。${NC}"
fi

# ==================== 🛡️ 阶段二：容器进程与DDoS动态扫描 ====================
echo -e "\n${CYAN}=======================================${NC}"
echo -e "${CYAN} 🚀 阶段二: 容器内部违规进程与 DDoS 行为清查${NC}"
echo -e "${CYAN}=======================================${NC}\n"

# 智能匹配重装镜像
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

# 修正部分低版本快捷键解析，改用标准全称获取实例列表
RUNNING_INSTANCES=$(incus list --all-projects -f csv -c n,p,s < /dev/null 2>/dev/null | grep -i ',RUNNING$' | awk -F, '{print $1","$2}')

if [ -z "$RUNNING_INSTANCES" ]; then
    echo -e "${GREEN}安全：当前宿主机上没有正在运行的容器，无需清查。${NC}"
    exit 0
fi

TOTAL=$(echo "$RUNNING_INSTANCES" | grep -c "^")
echo -e "正在全量跨项目深度盘查 ${YELLOW}${TOTAL}${NC} 个活跃容器..."
echo "------------------------------------------------"

COUNT=0
INFECTED_COUNT=0

for instance in $RUNNING_INSTANCES; do
    [ -z "$instance" ] && continue
    COUNT=$((COUNT + 1))
    
    container=$(echo "$instance" | awk -F, '{print $1}')
    project=$(echo "$instance" | awk -F, '{print $2}')
    
    # 改为明文换行打印，拒绝回首覆盖，确保所见即所得
    printf "[%d/%d] 正在盘查容器: %-26s [项目: %-8s] -> " "$COUNT" "$TOTAL" "$container" "$project"

    # 【核心修复】将 --project 参数严格修正移动到 exec 子命令的最前面！
    HIT_REASON=$(incus exec --project "$project" "$container" -- sh -c '
        KEYWORDS="$1"
        MAX_TCP="$2"
        MAX_UDP="$3"
        MAX_RAW="$4"
        MAX_SYN="$5"
        SELF=$$
        
        [ -f /proc/net/tcp ] || exit 0
        
        TCP_FILE=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)
        
        TCP_COUNT=$(echo "$TCP_FILE" | grep -c "^")
        UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | grep -c "^")
        RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | grep -c "^")
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
    ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" "$MAX_SYN_SENT" < /dev/null 2>/dev/null)

    if [ -n "$HIT_REASON" ]; then
        INFECTED_COUNT=$((INFECTED_COUNT + 1))
        echo -e "${RED}【🚨 违规: $HIT_REASON】${NC}"
        echo -e "${YELLOW}   ↳ 🔄 正在强制直接智能重装...${NC}"
        # 【核心修复】同样修正 rebuild 的 --project 参数顺序
        if incus rebuild --project "$project" "$TARGET_IMAGE" "$container" --force < /dev/null >/dev/null 2>&1; then
            echo -e "${GREEN}   ↳ ✅ 重装成功！容器已重置净化。${NC}"
        else
            echo -e "${RED}   ↳ ❌ 重装失败，请手动介入检查。${NC}"
        fi
    else
        echo -e "${GREEN}[✔ 正常]${NC}"
    fi
done

echo "------------------------------------------------"
echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN} 🏁 全盘盘查结束${NC}"
echo -e "${CYAN}=======================================${NC}\n"

if [ "$INFECTED_COUNT" -eq 0 ]; then
    echo -e "${GREEN}✨ 完美安全：所有项目运行中容器指标健康，未发现任何违规。${NC}"
else
    echo -e "${YELLOW}🚨 处理报告：本次任务共计清洗并强制重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险容器。${NC}"
fi
