#!/bin/bash

# incus 容器哪吒探针检测脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

declare -a INFECTED_CONTAINERS=()

do_scan() {
    INFECTED_CONTAINERS=()

    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN}  Incus 容器哪吒探针检测工具${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns | grep -i ',RUNNING$' | cut -d',' -f1)

    if [ -z "$RUNNING_CONTAINERS" ]; then
        echo -e "${GREEN}没有正在运行的容器。${NC}"
        return 1
    fi

    TOTAL=$(echo "$RUNNING_CONTAINERS" | wc -l | tr -d ' ')
    echo -e "正在扫描 ${YELLOW}${TOTAL}${NC} 个运行中的容器...\n"

    COUNT=0
    while IFS= read -r container <&3; do
        [ -z "$container" ] && continue
        COUNT=$((COUNT + 1))
        printf "\r[%d/%d] 正在检查: %-30s" "$COUNT" "$TOTAL" "$container"

        # 单次 exec，命中任一条件立刻 exit 0 短路，不多跑
        HIT=$(incus exec "$container" -- sh -c '
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                if xargs -0 < "$f" 2>/dev/null | grep -qiE "nezha"; then
                    echo HIT; exit 0
                fi
            done
            for p in /opt/nezha /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                [ -e "$p" ] && echo HIT && exit 0
            done
        ' </dev/null 2>/dev/null)

        if [ "$HIT" = "HIT" ]; then
            INFECTED_CONTAINERS+=("$container")
            printf "\r${RED}[!] %-40s${NC}\n" "$container"
        fi
    done 3<<< "$RUNNING_CONTAINERS"

    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN}  扫描完成${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
        echo -e "${GREEN}所有容器均未检测到哪吒探针，安全！${NC}"
        return 1
    fi

    echo -e "${RED}检测到 ${#INFECTED_CONTAINERS[@]} 个容器存在哪吒探针:${NC}\n"
    for i in "${!INFECTED_CONTAINERS[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${INFECTED_CONTAINERS[$i]}"
    done
    echo ""
    return 0
}

print_infected_list() {
    for i in "${!INFECTED_CONTAINERS[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${INFECTED_CONTAINERS[$i]}"
    done
}

pick_containers() {
    local prompt_msg="$1"
    PICKED_CONTAINERS=()

    echo ""
    echo -e "$prompt_msg"
    echo -e "  ${YELLOW}[A]${NC} 全部"
    print_infected_list
    echo ""
    read -rp "输入编号（空格分隔）或 A 全选: " -a selections

    if [[ "${selections[0]}" =~ ^[Aa]$ ]]; then
        PICKED_CONTAINERS=("${INFECTED_CONTAINERS[@]}")
        return 0
    fi

    for sel in "${selections[@]}"; do
        idx=$((sel - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#INFECTED_CONTAINERS[@]}" ]; then
            PICKED_CONTAINERS+=("${INFECTED_CONTAINERS[$idx]}")
        else
            echo -e "${RED}无效编号: ${sel}，已跳过${NC}"
        fi
    done

    [ ${#PICKED_CONTAINERS[@]} -gt 0 ]
}

select_image() {
    SELECTED_IMAGE=""

    echo -e "\n${CYAN}正在获取本地镜像列表...${NC}\n"

    local image_raw
    image_raw=$(incus image list -f csv -c lLfd 2>/dev/null)

    if [ -z "$image_raw" ]; then
        echo -e "${RED}未找到本地镜像。请先导入镜像。${NC}"
        return 1
    fi

    declare -a IMG_ALIASES=()
    declare -a IMG_FINGERPRINTS=()
    declare -a IMG_DESCRIPTIONS=()

    local idx=0
    while IFS=',' read -r aliases alt_names fingerprint description; do
        local display_name="${aliases:-${fingerprint:0:12}}"
        IMG_ALIASES+=("$display_name")
        IMG_FINGERPRINTS+=("$fingerprint")
        IMG_DESCRIPTIONS+=("$description")
        idx=$((idx + 1))
    done <<< "$image_raw"

    if [ "$idx" -eq 0 ]; then
        echo -e "${RED}未找到本地镜像。${NC}"
        return 1
    fi

    echo -e "${CYAN}可用镜像列表:${NC}\n"
    for i in "${!IMG_ALIASES[@]}"; do
        printf "  ${YELLOW}[%d]${NC} %-25s ${CYAN}%s${NC}\n" "$((i+1))" "${IMG_ALIASES[$i]}" "${IMG_DESCRIPTIONS[$i]}"
    done

    echo ""
    read -rp "选择镜像编号: " img_choice

    local img_idx=$((img_choice - 1))
    if [ "$img_idx" -ge 0 ] && [ "$img_idx" -lt "$idx" ]; then
        if [ -n "${IMG_ALIASES[$img_idx]}" ] && [ "${IMG_ALIASES[$img_idx]}" != "${IMG_FINGERPRINTS[$img_idx]:0:12}" ]; then
            SELECTED_IMAGE="${IMG_ALIASES[$img_idx]}"
        else
            SELECTED_IMAGE="${IMG_FINGERPRINTS[$img_idx]}"
        fi
        echo -e "\n已选择镜像: ${GREEN}${SELECTED_IMAGE}${NC} (${IMG_DESCRIPTIONS[$img_idx]})"
        return 0
    else
        echo -e "${RED}无效编号。${NC}"
        return 1
    fi
}

do_rebuild() {
    echo -e "\n${CYAN}=== 重装容器 ===${NC}"

    if ! pick_containers "选择要重装的容器:"; then
        echo -e "${YELLOW}未选择任何容器。${NC}"
        return
    fi

    if ! select_image; then
        return
    fi

    echo -e "\n${RED}!!! 警告: 重装将清除容器内所有数据 !!!${NC}"
    echo -e "${YELLOW}即将使用镜像 [${SELECTED_IMAGE}] 重装以下容器:${NC}\n"
    for c in "${PICKED_CONTAINERS[@]}"; do
        echo -e "  - $c"
    done
    echo ""
    read -rp "确认重装？输入 YES 继续: " confirm

    if [ "$confirm" != "YES" ]; then
        echo -e "${YELLOW}已取消重装。${NC}"
        return
    fi

    local success=0
    local fail=0
    echo ""
    for c in "${PICKED_CONTAINERS[@]}"; do
        echo -ne "  正在重装 ${c}... "
        if incus rebuild "$SELECTED_IMAGE" "$c" --force 2>&1; then
            echo -e "${GREEN}重装成功${NC}"
            success=$((success + 1))
        else
            echo -e "${RED}重装失败${NC}"
            fail=$((fail + 1))
        fi
    done

    echo -e "\n${GREEN}完成: ${success} 个成功${NC}"
    [ "$fail" -gt 0 ] && echo -e "${RED}失败: ${fail} 个${NC}"

    echo ""
    read -rp "是否立即重新扫描？(Y/n): " rescan
    if [[ ! "$rescan" =~ ^[Nn]$ ]]; then
        do_scan
    fi
}

# === 主流程 ===

do_scan

if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
    exit 0
fi

while true; do
    echo -e "${CYAN}请选择操作:${NC}"
    echo -e "  ${YELLOW}1${NC}) 暂停全部检测到的容器"
    echo -e "  ${YELLOW}2${NC}) 选择指定容器暂停"
    echo -e "  ${YELLOW}3${NC}) 仅列出容器名（不做操作）"
    echo -e "  ${YELLOW}4${NC}) 重装容器（选择镜像重装）"
    echo -e "  ${YELLOW}5${NC}) 重新扫描"
    echo -e "  ${YELLOW}0${NC}) 退出"
    echo ""
    read -rp "请输入选项 [0-5]: " choice

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
            if pick_containers "选择要暂停的容器:"; then
                echo ""
                echo -e "${YELLOW}即将暂停以下容器:${NC}"
                for c in "${PICKED_CONTAINERS[@]}"; do
                    echo -e "  - $c"
                done
                echo ""
                read -rp "确认暂停？(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    for c in "${PICKED_CONTAINERS[@]}"; do
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
            echo -e "\n${CYAN}检测到哪吒探针的容器列表:${NC}\n"
            for c in "${INFECTED_CONTAINERS[@]}"; do
                echo "$c"
            done
            echo ""
            ;;
        4)
            if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
                echo -e "${YELLOW}当前没有检测到的容器，请先扫描。${NC}\n"
            else
                do_rebuild
            fi
            ;;
        5)
            do_scan
            if [ ${#INFECTED_CONTAINERS[@]} -eq 0 ]; then
                echo -e "\n${GREEN}已无问题容器，是否退出？(Y/n): ${NC}"
                read -rp "" quit
                if [[ ! "$quit" =~ ^[Nn]$ ]]; then
                    exit 0
                fi
            fi
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
