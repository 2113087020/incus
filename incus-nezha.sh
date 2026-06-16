#!/bin/bash

# incus 容器哪吒探针检测脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

declare -a INFECTED_CONTAINERS=()
declare -a INFECTED_DETAILS=()

echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN}  Incus 容器哪吒探针检测工具${NC}"
echo -e "${CYAN}=======================================${NC}"
echo ""

RUNNING_CONTAINERS=$(incus list -f csv -c ns | grep -i ',RUNNING$' | cut -d',' -f1)

if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${GREEN}没有正在运行的容器。${NC}"
    exit 0
fi

TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

COUNT=0
while IFS= read -r container <&3; do
    [ -z "$container" ] && continue
    COUNT=$((COUNT + 1))
    printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

    DETAIL=""

    # 方法1: 通过 /proc 读取进程 cmdline（不依赖 ps，Alpine/Debian 通用）
    PROC_RESULT=$(incus exec "$container" -- sh -c '
        for f in /proc/[0-9]*/cmdline; do
            [ -f "$f" ] || continue
            cmd=$(xargs -0 < "$f" 2>/dev/null || cat "$f" 2>/dev/null)
            [ -n "$cmd" ] && echo "$cmd"
        done
    ' </dev/null 2>/dev/null | grep -iE 'nezha[-_]?agent|nezha[-_]?dashboard|/opt/nezha|/usr/local/bin/nezha')

    if [ -n "$PROC_RESULT" ]; then
        DETAIL="${DETAIL}[进程] ${PROC_RESULT}"$'\n'
    fi

    # 方法2: 检查哪吒探针常见安装路径
    FILE_RESULT=$(incus exec "$container" -- sh -c '
        for p in \
            /opt/nezha \
            /opt/nezha/agent \
            /opt/nezha/agent/nezha-agent \
            /usr/local/bin/nezha-agent \
            /usr/local/bin/nezha_agent \
            /root/nezha-agent \
            /root/nezha_agent; do
            [ -e "$p" ] && echo "$p"
        done
    ' </dev/null 2>/dev/null)

    if [ -n "$FILE_RESULT" ]; then
        DETAIL="${DETAIL}[文件] ${FILE_RESULT}"$'\n'
    fi

    # 方法3: 检查服务 — 同时支持 systemd (Debian) 和 OpenRC (Alpine)
    SVC_RESULT=$(incus exec "$container" -- sh -c '
        # systemd (Debian/Ubuntu)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl list-unit-files 2>/dev/null | grep -i nezha
            for f in /etc/systemd/system/nezha-agent.service \
                     /etc/systemd/system/nezha-agent.service.d; do
                [ -e "$f" ] && echo "systemd: $f"
            done
        fi
        # OpenRC (Alpine)
        if command -v rc-service >/dev/null 2>&1; then
            rc-service -l 2>/dev/null | grep -i nezha
            for f in /etc/init.d/nezha-agent /etc/init.d/nezha_agent; do
                [ -e "$f" ] && echo "openrc: $f"
            done
        fi
        # crontab（通用，有些人用 cron 拉起哪吒）
        crontab -l 2>/dev/null | grep -i nezha
        for u in /var/spool/cron/crontabs/*; do
            [ -f "$u" ] && grep -i nezha "$u" 2>/dev/null && echo "cron: $u"
        done
    ' </dev/null 2>/dev/null)

    if [ -n "$SVC_RESULT" ]; then
        DETAIL="${DETAIL}[服务] ${SVC_RESULT}"$'\n'
    fi

    if [ -n "$DETAIL" ]; then
        INFECTED_CONTAINERS+=("$container")
        INFECTED_DETAILS+=("$DETAIL")
        echo ""
        echo -e "  ${RED}[!] 发现哪吒探针: ${container}${NC}"
        echo "$DETAIL" | while IFS= read -r line; do
            [ -n "$line" ] && echo -e "      ${YELLOW}${line}${NC}"
        done
    fi
done 3<<< "$RUNNING_CONTAINERS"

echo ""
echo ""
echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN}  扫描完成${NC}"
echo -e "${CYAN}=======================================${NC}"
echo ""

if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
    echo -e "${GREEN}所有容器均未检测到哪吒探针，安全！${NC}"
    exit 0
fi

echo -e "${RED}检测到 ${#INFECTED_CONTAINERS[@]} 个容器存在哪吒探针:${NC}\n"
for i in "${!INFECTED_CONTAINERS[@]}"; do
    echo -e "  ${YELLOW}[$((i+1))]${NC} ${INFECTED_CONTAINERS[$i]}"
    echo "${INFECTED_DETAILS[$i]}" | while IFS= read -r line; do
        [ -n "$line" ] && echo -e "       ${line}"
    done
done
echo ""

while true; do
    echo -e "${CYAN}请选择操作:${NC}"
    echo -e "  ${YELLOW}1${NC}) 暂停全部检测到的容器"
    echo -e "  ${YELLOW}2${NC}) 选择指定容器暂停"
    echo -e "  ${YELLOW}3${NC}) 仅列出容器名（不做操作）"
    echo -e "  ${YELLOW}0${NC}) 退出"
    echo ""
    read -rp "请输入选项 [0-3]: " choice

    case $choice in
        1)
            echo ""
            echo -e "${YELLOW}即将暂停以下容器:${NC}"
            for c in "${INFECTED_CONTAINERS[@]}"; do
                echo -e "  - $c"
            done
            echo ""
            read -rp "确认暂停全部？(y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                for c in "${INFECTED_CONTAINERS[@]}"; do
                    echo -ne "  正在暂停 ${c}... "
                    if incus stop "$c" --force 2>/dev/null; then
                        echo -e "${GREEN}已暂停${NC}"
                    else
                        echo -e "${RED}失败${NC}"
                    fi
                done
                echo -e "\n${GREEN}操作完成。${NC}"
            else
                echo -e "${YELLOW}已取消。${NC}"
            fi
            ;;
        2)
            echo ""
            echo -e "请输入要暂停的容器编号（多个用空格分隔，如: 1 3 5）:"
            for i in "${!INFECTED_CONTAINERS[@]}"; do
                echo -e "  ${YELLOW}[$((i+1))]${NC} ${INFECTED_CONTAINERS[$i]}"
            done
            echo ""
            read -rp "输入编号: " -a selections
            SELECTED=()
            for sel in "${selections[@]}"; do
                idx=$((sel - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#INFECTED_CONTAINERS[@]}" ]; then
                    SELECTED+=("${INFECTED_CONTAINERS[$idx]}")
                else
                    echo -e "${RED}无效编号: ${sel}${NC}"
                fi
            done
            if [ ${#SELECTED[@]} -gt 0 ]; then
                echo ""
                echo -e "${YELLOW}即将暂停以下容器:${NC}"
                for c in "${SELECTED[@]}"; do
                    echo -e "  - $c"
                done
                echo ""
                read -rp "确认暂停？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    for c in "${SELECTED[@]}"; do
                        echo -ne "  正在暂停 ${c}... "
                        if incus stop "$c" --force 2>/dev/null; then
                            echo -e "${GREEN}已暂停${NC}"
                        else
                            echo -e "${RED}失败${NC}"
                        fi
                    done
                    echo -e "\n${GREEN}操作完成。${NC}"
                else
                    echo -e "${YELLOW}已取消。${NC}"
                fi
            fi
            ;;
        3)
            echo ""
            echo -e "${CYAN}检测到哪吒探针的容器列表:${NC}\n"
            for c in "${INFECTED_CONTAINERS[@]}"; do
                echo "$c"
            done
            echo ""
            ;;
        0)
            echo -e "${GREEN}退出。${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新输入。${NC}\n"
            ;;
    esac
done
