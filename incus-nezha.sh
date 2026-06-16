#!/bin/bash

# incus 容器哪吒探针检测脚本
# 检测所有运行中的 incus 容器是否存在 nezha-agent 进程

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NEZHA_PATTERNS="nezha-agent|nezha_agent|nezha-dashboard|nezha_dashboard"

declare -a INFECTED_CONTAINERS=()

echo -e "${CYAN}=======================================${NC}"
echo -e "${CYAN}  Incus 容器哪吒探针检测工具${NC}"
echo -e "${CYAN}=======================================${NC}"
echo ""

RUNNING_CONTAINERS=$(incus list status=running -f csv -c n 2>/dev/null)

if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${GREEN}没有正在运行的容器。${NC}"
    exit 0
fi

TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

COUNT=0
while IFS= read -r container; do
    COUNT=$((COUNT + 1))
    printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

    RESULT=$(incus exec "$container" -- sh -c "ps aux 2>/dev/null || ps -ef 2>/dev/null" 2>/dev/null | grep -iE "$NEZHA_PATTERNS" | grep -v grep)

    if [ -n "$RESULT" ]; then
        INFECTED_CONTAINERS+=("$container")
        echo ""
        echo -e "  ${RED}[!] 发现哪吒探针: ${container}${NC}"
        echo "$RESULT" | while IFS= read -r line; do
            echo -e "      ${YELLOW}${line}${NC}"
        done
    fi
done <<< "$RUNNING_CONTAINERS"

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
