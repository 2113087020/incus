#!/bin/bash
# incus 容器哪吒探针检测与智能自动重装脚本 (增强兼容版)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 智能获取最适合重装的镜像
get_best_image() {
    # 1. 尝试在本地镜像中寻找带有 "alpine" 关键字的镜像指纹
    local local_alpine=$(incus image list local: -f csv -c fd 2>/dev/null | grep -i "alpine" | head -n1 | cut -d',' -f1)
    if [ -n "$local_alpine" ]; then
        echo "$local_alpine"
        return 0
    fi

    # 2. 如果没有 Alpine，寻找本地任意一个可用镜像的指纹（别管什么系统，先洗干净再说）
    local local_any=$(incus image list local: -f csv -c f 2>/dev/null | head -n1)
    if [ -n "$local_any" ]; then
        echo "$local_any"
        return 0
    fi

    # 3. 如果本地彻底没有镜像，兜底使用官方远程源
    echo "images:alpine/latest"
}

do_scan() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} Incus 容器哪吒探针自动重装工具 (v2.0)${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    # 自动探测目标镜像
    TARGET_IMAGE=$(get_best_image)
    echo -e "🔧 适配环境：已自动选择重装目标镜像 -> ${GREEN}${TARGET_IMAGE}${NC}"
    if [[ "$TARGET_IMAGE" != images:* ]]; then
        echo -e "ℹ️  提示：该镜像是从你本地缓存中智能匹配的，重装无需消耗外网流量。"
    else
        echo -e "⚠️  警告：本地未发现任何缓存镜像，将尝试从官方远程源拉取。"
    fi
    echo "------------------------------------------------"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns 2>/dev/null | grep -i ',RUNNING$' | cut -d',' -f1)

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
        HIT=$(incus exec "$container" -- sh -c '
            SELF=$$
            for f in /proc/[0-9]*/cmdline; do
                [ -f "$f" ] || continue
                p="${f%/cmdline}"; p="${p#/proc/}"
                [ "$p" = "$SELF" ] && continue
                if xargs -0 < "$f" 2>/dev/null | grep -qiE "nezha[-_]?agent"; then
                    echo HIT; exit 0
                fi
            done
            for p in /opt/nezha/agent/nezha-agent /usr/local/bin/nezha-agent /usr/local/bin/nezha_agent /root/nezha-agent /etc/init.d/nezha-agent /etc/systemd/system/nezha-agent.service; do
                [ -e "$p" ] && echo HIT && exit 0
            done
        ' </dev/null 2>/dev/null)

        if [ "$HIT" = "HIT" ]; then
            INFECTED_COUNT=$((INFECTED_COUNT + 1))
            printf "\r${RED}[!] 发现探针: %-40s${NC}\n" "$container"
            echo -e "${YELLOW}   ↳ 🔄 正在强制重装...${NC}"
            
            # 执行强制重装
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
        echo -e "${GREEN}安全：所有运行中的容器均未发现哪吒探针。${NC}"
    else
        echo -e "${YELLOW}处理报告：共自动清洗并重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险容器。${NC}"
    fi
}

# === 执行主流程 ===
do_scan
