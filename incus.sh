#!/bin/bash
# incus 容器违规进程检测与智能自动重装脚本 (v2.8 严格防爆破版 - 进程查杀 + 网络阻断 + DDoS检测)

# ==================== 🔍 自定义监控黑名单 ====================
SCAN_KEYWORDS="nezha[-_]?agent|komari|xmrig|xmr-stak|minerd|cpuminer|ccminer|cgminer|bfgminer|ethminer|claymore|phoenixminer|nanominer|t-rex|lolminer|nbminer|gminer|teamredminer|nicehash|kryptex|kdevtmpfsi|kinsing|sysrv|sysrv-md|sustse|sustsed|wnw7492|monero|cryptonight|stratum|minergate|poolminer|minerstat|srbminer|astrominer|xmrig-proxy|crypto-miner|hashcat|crypto-pool|gridcrude|pamd32|panchan|p2pinfect|skidmap|watchdogx|watchdogs|kerberods|nmap|masscan|zmap|rustscan|fscan|gobuster|dirbuster|nikto|wpscan|hydra|medusa|ncrack|crowbar|patator|brutex|ssh_scan|sshcheck|pyrdp|xsstrike|hping|hping3|loic|hoic|slowloris|synflood|udpflood|mirai|gafgyt|bashlite|tsunami|billgates|elknot|dofloo|sedna|stacheldraht|trinoo|kptd|atdd|skynet|gates\.lod|conficker|xorddos|muhstik|frpc|frps|npc|nps|chisel|rclone|ngrok|pagekite|bore|localtonet|vtun|anyconnect|openconnect|iodine|dnscat2|dnscat|3proxy|lcx|ew|beacon|geacon|sliver|merlin|metasploit|msfconsole|msfvenom|viper|meterpreter|suo5|reasing|neo-regeorg|cmd53|godzilla|behinder|antsword|stowaway|venom|serverstatus|stat_server|stat_client|sergate|beszel-hub|beszel-agent|beszel|nodeget|uptime-kuma|nodequery|ward|prometheus|node_exporter|zabbix_server|zabbix_agentd|grafana-server|grafana|influxd|netdata|glances|cockpit-ws|skywalking|sw-oap-server|vmagent|victoriametrics|fluent-bit|fluentd|logstash|vector|datadog-agent|agent2|filebeat|packetbeat|telegraf|sematext|pinpoint-agent|skywalking-agent|dozzle|scrutiny|sysupdate"
# ============================================================

# ==================== 🚦 DDoS 并发阈值配置 ====================
MAX_TCP_CONN=500    # TCP 并发连接数上限 (严格模式：超过500判定为洪水攻击或扫描)
MAX_UDP_CONN=500    # UDP 并发连接数上限 (严格模式：超过500判定为 UDP 发包)
MAX_RAW_CONN=50     # Raw Socket 上限 (正常情况一般为 0，超过说明在伪造底层协议发包)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 🛡️ 网络安全防护初始化 ====================
setup_network_firewall() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🛡️ 初始化: 配置 Incus 全局网络防护${NC}"
    echo -e "${CYAN}=======================================${NC}"
    
    if ! incus network acl show block-22 >/dev/null 2>&1; then
        echo -e "${YELLOW}   ↳ [!] 未检测到出站 22 端口拦截规则，正在创建底层 ACL...${NC}"
        incus network acl create block-22 >/dev/null 2>&1
        printf "egress:\n  - action: drop\n    protocol: tcp\n    destination_port: '22'\n    state: enabled\n" | incus network acl edit block-22 >/dev/null 2>&1
    fi

    if incus network show incusbr0 >/dev/null 2>&1; then
        CURRENT_ACLS=$(incus network get incusbr0 security.acls 2>/dev/null)
        if [ -z "$CURRENT_ACLS" ]; then
            incus network set incusbr0 security.acls=block-22 >/dev/null 2>&1
            echo -e "${GREEN}   ↳ [✔] 成功配置！所有容器已被禁止对外扫描 22 端口。${NC}"
        elif [[ ! "$CURRENT_ACLS" =~ "block-22" ]]; then
            incus network set incusbr0 security.acls="${CURRENT_ACLS},block-22" >/dev/null 2>&1
            echo -e "${GREEN}   ↳ [✔] 成功追加配置！已在不影响现有规则的情况下增加了 22 端口拦截。${NC}"
        else
            echo -e "${GREEN}   ↳ [✔] 出站 22 端口拦截规则 (block-22) 已生效并绑定，检查通过。${NC}"
        fi
    else
        echo -e "${RED}   ↳ [✖] 未找到默认网桥 incusbr0，请检查网络名称或手动绑定规则。${NC}"
    fi
}
# ============================================================

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

do_scan() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🚀 Incus 容器多进程及DDoS自动重装工具 (v2.8 严格版)${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    TARGET_IMAGE=$(get_best_image)
    echo -e "🎯 静态黑名单: ${YELLOW}包含 $(echo "$SCAN_KEYWORDS" | tr '|' '\n' | wc -l) 个关键词${NC}"
    echo -e "🎯 动态防DDoS: ${YELLOW}TCP上限:${MAX_TCP_CONN} | UDP上限:${MAX_UDP_CONN} | RAW底包上限:${MAX_RAW_CONN}${NC}"
    echo -e "🔧 适配环境：已自动选择重装目标镜像 -> ${GREEN}${TARGET_IMAGE}${NC}"
    if [[ "$TARGET_IMAGE" != images:* ]]; then
        echo -e "ℹ️  提示：该镜像是从你本地缓存中智能匹配的，重装无需消耗外网流量。"
    fi
    echo "------------------------------------------------"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns 2>/dev/null | grep -i ',RUNNING$' | awk -F, '{print $1}')

    if [ -z "$RUNNING_CONTAINERS" ]; then
        echo -e "${GREEN}没有正在运行的容器。${NC}"
        return 0
    fi

    TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

    COUNT=0
    INFECTED_COUNT=0

    while IFS= read -r container <&3; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

        # 传入更多参数 (包括关键词和DDoS阈值)
        HIT_REASON=$(incus exec "$container" -- sh -c '
            KEYWORDS="$1"
            MAX_TCP="$2"
            MAX_UDP="$3"
            MAX_RAW="$4"
            SELF=$$
            
            # === 1. DDoS 网络行为动态检测 ===
            TCP_COUNT=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l)
            UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)
            RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | wc -l)
            
            if [ "$TCP_COUNT" -gt "$MAX_TCP" ]; then
                echo "DDoS预警: 极高频的 TCP 并发连接 (数量: $TCP_COUNT)"
                exit 0
            fi
            if [ "$UDP_COUNT" -gt "$MAX_UDP" ]; then
                echo "DDoS预警: 极高频的 UDP 洪水发包 (数量: $UDP_COUNT)"
                exit 0
            fi
            if [ "$RAW_COUNT" -gt "$MAX_RAW" ]; then
                echo "DDoS发包特征: 异常的 Raw Socket 底层协议伪造 (数量: $RAW_COUNT)"
                exit 0
            fi

            # === 2. 静态内存运行进程检测 ===
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                MATCHED=$(tr "\0" "\n" < "$f" 2>/dev/null | grep -oiE "$KEYWORDS" | head -n1)
                if [ -n "$MATCHED" ]; then
                    echo "恶意进程触发: $MATCHED"
                    exit 0
                fi
            done
            
            # === 3. 静态残留特征文件扫描 ===
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                if [ -e "$p" ]; then
                    echo "残留特征文件: $p"
                    exit 0
                fi
            done
        ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" </dev/null 2>/dev/null)

        if [ -n "$HIT_REASON" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            printf "\r${RED}[!] 发现违规特征: %-25s -> 【%s】${NC}\n" "$container" "$HIT_REASON"
            echo -e "${YELLOW}   ↳ 🔄 正在强制重装...${NC}"
            
            if incus rebuild "$TARGET_IMAGE" "$container" --force >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！容器已重置。${NC}\n"
            else
                echo -e "${RED}   ↳ ❌ 重装失败，可能该容器处于锁定状态或存储卷异常。${NC}\n"
            fi
        fi
    done 3<<< "$RUNNING_CONTAINERS"

    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🏁 扫描与自动清理完成${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ "$INFECTED_COUNT" -eq 0 ]; then
        echo -e "${GREEN}安全：所有运行中的容器状态及网络连接均正常。${NC}"
    else
        echo -e "${YELLOW}处理报告：共自动清洗并重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险容器。${NC}"
    fi
}

setup_network_firewall
do_scan
    echo -e "🎯 当前监控特征: ${YELLOW}${SCAN_KEYWORDS}${NC}"
    echo -e "🔧 适配环境：已自动选择重装目标镜像 -> ${GREEN}${TARGET_IMAGE}${NC}"
    if [[ "$TARGET_IMAGE" != images:* ]]; then
        echo -e "ℹ️  提示：该镜像是从你本地缓存中智能匹配的，重装无需消耗外网流量。"
    else
        echo -e "⚠️  警告：本地未发现任何缓存镜像，将尝试从官方远程源拉取。"
    fi
    echo "------------------------------------------------"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns 2>/dev/null | grep -i ',RUNNING$' | awk -F, '{print $1}')

    if [ -z "$RUNNING_CONTAINERS" ]; then
        echo -e "${GREEN}没有正在运行的容器。${NC}"
        return 0
    fi

    TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

    COUNT=0
    INFECTED_COUNT=0

    while IFS= read -r container <&3; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

        # 深度检测进程与特征文件
        HIT_REASON=$(incus exec "$container" -- sh -c '
            KEYWORDS="$1"
            SELF=$$
            
            # 1. 扫描内存运行进程 (改用 tr \0 换行，完美解决精准关键字提取)
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                
                # 将内存 cmdline 的 \0 转换为换行符再精确匹配关键字
                MATCHED=$(tr "\0" "\n" < "$f" 2>/dev/null | grep -oiE "$KEYWORDS" | head -n1)
                if [ -n "$MATCHED" ]; then
                    echo "进程触发: $MATCHED"
                    exit 0
                fi
            done
            
            # 2. 扫描特定残留特征文件
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                if [ -e "$p" ]; then
                    echo "残留特征文件: $p"
                    exit 0
                fi
            done
        ' sh "$SCAN_KEYWORDS" </dev/null 2>/dev/null)

        # 判断是否有输出原因
        if [ -n "$HIT_REASON" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            # 标准控制台输出
            printf "\r${RED}[!] 发现违规特征: %-25s -> 【%s】${NC}\n" "$container" "$HIT_REASON"
            echo -e "${YELLOW}   ↳ 🔄 正在强制重装...${NC}"
            
            if incus rebuild "$TARGET_IMAGE" "$container" --force >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！容器已重置。${NC}\n"
            else
                echo -e "${RED}   ↳ ❌ 重装失败，可能该容器处于锁定状态或存储卷异常。${NC}\n"
            fi
        fi
    done 3<<< "$RUNNING_CONTAINERS"

    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN} 扫描与自动清理完成${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ "$INFECTED_COUNT" -eq 0 ]; then
        echo -e "${GREEN}安全：所有运行中的容器均未发现违规特征。${NC}"
    else
        echo -e "${YELLOW}处理报告：共自动清洗并重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险容器。${NC}"
    fi
}

do_scan
