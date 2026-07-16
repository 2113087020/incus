#!/bin/bash
# incus 容器违规进程检测与智能自动重装脚本 (v3.2 生产环境终极修复版)

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
    echo -e "${RED}✖ 错误: 未找到 incus 命令，请确保已安装 Incus 且当前用户有执行权限。${NC}"
    exit 1
fi

# ==================== 🛡️ 网络安全防护初始化 ====================
setup_network_firewall() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} 🛡️ 初始化: 配置 Incus 全局网络防护${NC}"
    echo -e "${CYAN}=======================================${NC}"
    
    # --- 1. 清理旧版 block-22 规则 ---
    if incus network acl show block-22 >/dev/null 2>&1; then
        echo -e "${YELLOW}   ↳ [*] 检测到旧版单端口规则 (block-22)，正在自动执行无缝升级...${NC}"
        if incus network show incusbr0 >/dev/null 2>&1; then
            CURRENT_ACLS=$(incus network get incusbr0 security.acls 2>/dev/null)
            if [[ "$CURRENT_ACLS" =~ (^|,)"block-22"(,|$) ]]; then
                NEW_ACLS=""
                for acl in $(echo "$CURRENT_ACLS" | tr ',' ' '); do
                    if [ "$acl" != "block-22" ]; then
                        [ -z "$NEW_ACLS" ] && NEW_ACLS="$acl" || NEW_ACLS="${NEW_ACLS},${acl}"
                    fi
                done
                if [ -z "$NEW_ACLS" ]; then
                    incus network unset incusbr0 security.acls >/dev/null 2>&1
                else
                    incus network set incusbr0 security.acls="$NEW_ACLS" >/dev/null 2>&1
                fi
            fi
        fi
        incus network acl delete block-22 >/dev/null 2>&1
        echo -e "${GREEN}   ↳ [✔] 旧版规则已完美清理，系统就绪。${NC}"
    fi

    # --- 2. 创建并绑定新的泛端口拦截规则 ---
    if ! incus network acl show block-scan-ports >/dev/null 2>&1; then
        echo -e "${YELLOW}   ↳ [!] 正在构建底层多端口拦截 ACL...${NC}"
        incus network acl create block-scan-ports >/dev/null 2>&1
        # 【核心修复】：放弃脆弱的 YAML 覆写，改用原生健壮的 rule add 命令行追加
        incus network acl rule add block-scan-ports egress action=drop protocol=tcp destination_port="${BLOCK_OUT_PORTS}" state=enabled >/dev/null 2>&1
    fi

    if incus network show incusbr0 >/dev/null 2>&1; then
        CURRENT_ACLS=$(incus network get incusbr0 security.acls 2>/dev/null)
        if [ -z "$CURRENT_ACLS" ]; then
            incus network set incusbr0 security.acls=block-scan-ports >/dev/null 2>&1
            echo -e "${GREEN}   ↳ [✔] 成功配置！所有容器已被禁止对外扫描高危端口 (${BLOCK_OUT_PORTS})。${NC}"
        elif [[ ! "$CURRENT_ACLS" =~ (^|,)"block-scan-ports"(,|$) ]]; then
            incus network set incusbr0 security.acls="${CURRENT_ACLS},block-scan-ports" >/dev/null 2>&1
            echo -e "${GREEN}   ↳ [✔] 成功追加配置！已更新多端口拦截矩阵。${NC}"
        else
            echo -e "${GREEN}   ↳ [✔] 泛端口扫描拦截规则已生效并绑定，安全检查通过。${NC}"
        fi
    else
        echo -e "${RED}   ↳ [✖] 未找到默认网桥 incusbr0，请检查网络名称或手动绑定。${NC}"
    fi
}

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
    echo -e "${CYAN} 🚀 Incus 容器多进程及DDoS自动重装工具 (v3.2 稳定版)${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    TARGET_IMAGE=$(get_best_image)
    echo -e "🎯 静态黑名单: ${YELLOW}包含 $(echo "$SCAN_KEYWORDS" | tr '|' '\n' | wc -l) 个关键词${NC}"
    echo -e "🎯 动态防DDoS: ${YELLOW}TCP:${MAX_TCP_CONN} | UDP:${MAX_UDP_CONN} | RAW:${MAX_RAW_CONN} | ${RED}SYN发包:${MAX_SYN_SENT}${NC}"
    echo -e "🔧 适配环境：已自动选择重装目标镜像 -> ${GREEN}${TARGET_IMAGE}${NC}"
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

    # 【核心修复】：将脆弱的 3<<< 替换为标准的 Bash 进程替换机制机制 (< <(...))，防止解析挂掉
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

        # 【核心修复】：强强联合强力隔离单引号 '\''{print $4}'\'' 彻底解决 awk 内嵌解析错误
        HIT_REASON=$(incus exec "$container" -- sh -c '
            KEYWORDS="$1"
            MAX_TCP="$2"
            MAX_UDP="$3"
            MAX_RAW="$4"
            MAX_SYN="$5"
            SELF=$$
            
            # === 1. DDoS 与 泛端口扫描行为动态检测 ===
            TCP_FILE=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null)
            
            TCP_COUNT=$(echo "$TCP_FILE" | wc -l)
            UDP_COUNT=$(cat /proc/net/udp /proc/net/udp6 2>/dev/null | wc -l)
            RAW_COUNT=$(cat /proc/net/raw /proc/net/raw6 2>/dev/null | wc -l)
            
            SYN_COUNT=$(echo "$TCP_FILE" | awk '\''{print $4}'\'' | grep -c "02")

            if [ "$SYN_COUNT" -gt "$MAX_SYN" ]; then
                echo "泛端口扫描预警: 检测到大量恶意的 SYN_SENT 握手发包 (数量: $SYN_COUNT)"
                exit 0
            fi
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
        ' sh "$SCAN_KEYWORDS" "$MAX_TCP_CONN" "$MAX_UDP_CONN" "$MAX_RAW_CONN" "$MAX_SYN_SENT" 2>/dev/null)

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
    done < <(echo "$RUNNING_CONTAINERS")

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
