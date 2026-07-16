#!/bin/bash
# incus 容器网络防护与违规进程智能检测一体化脚本 (v3.5 最终生产环境版)

# ==================== 🔍 自定义监控黑名单 ====================
SCAN_KEYWORDS="nezha[-_]?agent|komari|xmrig|xmr-stak|minerd|cpuminer|ccminer|cgminer|bfgminer|ethminer|claymore|phoenixminer|nanominer|t-rex|lolminer|nbminer|gminer|teamredminer|nicehash|kryptex|kdevtmpfsi|kinsing|sysrv|sysrv-md|sustse|sustsed|wnw7492|monero|cryptonight|stratum|minergate|poolminer|minerstat|srbminer|astrominer|xmrig-proxy|crypto-miner|hashcat|crypto-pool|gridcrude|pamd32|panchan|p2pinfect|skidmap|watchdogx|watchdogs|kerberods|nmap|masscan|zmap|rustscan|fscan|gobuster|dirbuster|nikto|wpscan|hydra|medusa|ncrack|crowbar|patator|brutex|ssh_scan|sshcheck|pyrdp|xsstrike|hping|hping3|loic|hoic|slowloris|synflood|udpflood|mirai|gafgyt|bashlite|tsunami|billgates|elknot|dofloo|sedna|stacheldraht|trinoo|kptd|atdd|skynet|gates\.lod|conficker|xorddos|muhstik|frpc|frps|npc|nps|chisel|rclone|ngrok|pagekite|bore|localtonet|vtun|anyconnect|openconnect|iodine|dnscat2|dnscat|3proxy|lcx|ew|beacon|geacon|sliver|merlin|metasploit|msfconsole|msfvenom|viper|meterpreter|suo5|reasing|neo-regeorg|cmd53|godzilla|behinder|antsword|stowaway|venom|serverstatus|stat_server|stat_client|sergate|beszel-hub|beszel-agent|beszel|nodeget|uptime-kuma|nodequery|ward|prometheus|node_exporter|zabbix_server|zabbix_agentd|grafana-server|grafana|influxd|netdata|glances|cockpit-ws|skywalking|sw-oap-server|vmagent|victoriametrics|fluent-bit|fluentd|logstash|vector|datadog-agent|agent2|filebeat|packetbeat|telegraf|sematext|pinpoint-agent|skywalking-agent|dozzle|scrutiny|sysupdate"
# ============================================================

# ==================== 🚦 网络与 DDoS 阈值配置 ====================
MAX_TCP_CONN=500    # TCP 并发上限
MAX_UDP_CONN=500    # UDP 并发上限 
MAX_RAW_CONN=50     # Raw Socket 上限
MAX_SYN_SENT=30     # SYN_SENT 状态上限 (超过判定为端口扫描)

# 常见高危扫描端口集合
BLOCK_OUT_PORTS="22,23,445,3389,6379,2375,2376" 
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 环境权限前置检查
if ! command -v incus &> /dev/null; then
    echo -e "${RED}✖ 错误: 未找到 incus 命令，请确保已安装 Incus 并拥有 root 执行权限。${NC}"
    exit 1
fi

# ==================== 🛡️ 第一阶段：网络安全防护检测与安装 ====================
check_and_install_firewall() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🛡️ 阶段一: 检测/安装全局网络拦截防火墙${NC}"
    echo -e "${CYAN}=======================================${NC}"
    
    # 1. 检查拦截策略是否存在，不存在则创建
    if incus network acl show block-scan-ports >/dev/null 2>&1; then
        echo -e "${GREEN}   [✔] 检测到底层 block-scan-ports ACL 规则已建立。${NC}"
    else
        echo -e "${YELLOW}   [!] 未检测到拦截规则，正在构建底层多端口拦截 ACL...${NC}"
        incus network acl create block-scan-ports >/dev/null 2>&1
        # 使用官方标准的 rule add 命令行追加，彻底废弃脆弱的 printf 覆写
        incus network acl rule add block-scan-ports egress action=drop protocol=tcp destination_port="${BLOCK_OUT_PORTS}" state=enabled >/dev/null 2>&1
        echo -e "${GREEN}   [✔] 底层 ACL 规则构建成功！${NC}"
    fi

    # 2. 检查默认网桥 incusbr0 是否绑定了该规则
    if incus network show incusbr0 >/dev/null 2>&1; then
        CURRENT_ACLS=$(incus network get incusbr0 security.acls 2>/dev/null)
        
        if [ -z "$CURRENT_ACLS" ]; then
            echo -e "${YELLOW}   [!] 检测到网桥尚未绑定任何安全规则，正在执行首次绑定...${NC}"
            incus network set incusbr0 security.acls block-scan-ports >/dev/null 2>&1
            echo -e "${GREEN}   [✔] 首次绑定成功！安全防护网已实时覆盖。${NC}"
        elif [[ ! "$CURRENT_ACLS" =~ (^|,)"block-scan-ports"(,|$) ]]; then
            echo -e "${YELLOW}   [!] 检测到网桥已存在其他规则，正在追加多端口拦截阵列...${NC}"
            incus network set incusbr0 security.acls "${CURRENT_ACLS},block-scan-ports" >/dev/null 2>&1
            echo -e "${GREEN}   [✔] 规则追加成功！${NC}"
        else
            echo -e "${GREEN}   [✔] 泛端口扫描拦截规则已牢固绑定在网桥 incusbr0，安全加固运行中。${NC}"
        fi
    else
        echo -e "${RED}   [✖] 严重警告：未找到默认网桥 incusbr0，跳过网桥绑定，请手动核对网桥名称。${NC}"
    fi
}

# 辅助函数：智能匹配重装镜像
get_best_image() {
    local local_alpine=$(incus image list local: -f csv -c fd 2>/dev/null | grep -i "alpine" | head -n1 | awk -F, '{print $1}')
    if [ -n "$local_alpine" ]; then
        echo "$local_alpine"
        return 0
    fi
    local local_any=$(incus image list local: -f csv -c f 2>/dev/null | head -n1)
    if [ -n "$local_any" ]; then
        echo "$local_any"
        return 0
    fi
    echo "images:alpine/latest"
}

# ==================== 🛡️ 第二阶段：容器进程与DDoS动态扫描 ====================
do_scan() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🚀 阶段二: 容器内部违规进程与 DDoS 行为清查${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    TARGET_IMAGE=$(get_best_image)
    echo -e "🎯 监控指标: 包含 $(echo "$SCAN_KEYWORDS" | tr '|' '\n' | wc -l) 个特征关键词"
    echo -e "🎯 动态阈值: TCP:${MAX_TCP_CONN} | UDP:${MAX_UDP_CONN} | RAW:${MAX_RAW_CONN} | SYN发包:${MAX_SYN_SENT}"
    echo -e "🔧 重装预设: 智能匹配重装镜像 -> ${GREEN}${TARGET_IMAGE}${NC}"
    echo "------------------------------------------------"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns 2>/dev/null | grep -i ',RUNNING$' | awk -F, '{print $1}')

    if [ -z "$RUNNING_CONTAINERS" ]; then
        echo -e "${GREEN}安全：当前宿主机上没有正在运行的容器，无需清查。${NC}"
        return 0
    fi

    TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    echo -e "正在深度盘查 ${YELLOW}${TOTAL}${NC} 个活跃容器...\n"

    COUNT=0
    INFECTED_COUNT=0

    # 使用标准的管道和进程替换机制，防止老旧 sh 环境引发的 Here-string 兼容崩溃
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在深度透视: %-30s" "$COUNT" "$TOTAL" "$container"

        # 完美剥离单引号，解决 awk 在底层执行时的转义泥潭
        HIT_REASON=$(incus exec "$container" -- sh -c '
            KEYWORDS="$1"
            MAX_TCP="$2"
            MAX_UDP="$3"
            MAX_RAW="$4"
            MAX_SYN="$5"
            SELF=$$
            
            # === 1. 动态网络行为与DDoS发包监控 ===
            TCP_FILE=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)
            
            TCP_COUNT=$(echo "$TCP_FILE" | wc -l)
            UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)
            RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | wc -l)
            
            SYN_COUNT=$(echo "$TCP_FILE" | awk '\''{print $4}'\'' | grep -c "02")

            if [ "$SYN_COUNT" -gt "$MAX_SYN" ]; then
                echo "泛端口扫描行为: 异常暴增的 SYN_SENT 握手包 (数量: $SYN_COUNT)"
                exit 0
            fi
            if [ "$TCP_COUNT" -gt "$MAX_TCP" ]; then
                echo "DDoS预警: 极高频 TCP 并发连接 (数量: $TCP_COUNT)"
                exit 0
            fi
            if [ "$UDP_COUNT" -gt "$MAX_UDP" ]; then
                echo "DDoS预警: 极高频 UDP 洪水发包 (数量: $UDP_COUNT)"
                exit 0
            fi
            if [ "$RAW_COUNT" -gt "$MAX_RAW" ]; then
                echo "底层协议伪造: 异常 Raw Socket 底层通信 (数量: $RAW_COUNT)"
                exit 0
            fi

            # === 2. 内存运行进程指令清查 ===
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                MATCHED=$(tr "\0" "\n" < "$f" 2>/dev/null | grep -oiE "$KEYWORDS" | head -n1)
                if [ -n "$MATCHED" ]; then
                    echo "命中违规违禁进程: $MATCHED"
                    exit 0
                fi
            done
            
            # === 3. 静态高危残留特征文件扫描 ===
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                if [ -e "$p" ]; then
                    echo "发现残留挖矿/监控特征文件: $p"
                    exit 0
                fi
            done
        ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" "$MAX_SYN_SENT" 2>/dev/null)

        if [ -n "$HIT_REASON" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            printf "\r${RED}[!] 警告: 容器 [%s] 触发违规行为 -> 【%s】${NC}\n" "$container" "$HIT_REASON"
            echo -e "${YELLOW}   ↳ 🔄 正在强制启动智能重装重置程序...${NC}"
            
            if incus rebuild "$TARGET_IMAGE" "$container" --force >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！该容器已被强制重置净化。${NC}\n"
            else
                echo -e "${RED}   ↳ ❌ 重装失败，请检查该容器状态或存储卷是否锁死。${NC}\n"
            fi
        fi
    done < <(echo "$RUNNING_CONTAINERS")

    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🏁 阶段二盘查结束${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ "$INFECTED_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✨ 完美安全：所有运行中容器指标健康，网络及进程无异常。${NC}"
    else
        echo -e "${YELLOW}🚨 处理报告：本次任务共计清洗并重装了 ${RED}${INFECTED_COUNT}${NC} 个违规高风险容器。${NC}"
    fi
}

# ==================== 🚀 顺序执行主逻辑 ====================
check_and_install_firewall
do_scan
