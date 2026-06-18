#!/bin/bash
# incus 容器哪吒探针检测并自动重装脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 在这里指定你想要重装的 Alpine 镜像（默认拉取官方最新的 alpine）
# 如果你本地有特定别名，可以改写为例如 "alpine/3.20"
ALPINE_IMAGE="images:alpine/latest"

do_scan() {
    echo -e "\n${CYAN}=======================================${NC}"
    echo -e "${CYAN} Incus 容器哪吒探针自动重装工具${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    RUNNING_CONTAINERS=$(incus list -f csv -c ns | grep -i ',RUNNING$' | cut -d',' -f1)

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

        # 单次 exec 命中立刻短路；跳过自身 PID 避免误匹配脚本自己
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
            # 换行打印提示，避免刷新覆盖
            printf "\r${RED}[!] 发现探针: %-40s${NC}\n" "$container"
            echo -e "${YELLOW}   ↳ 🔄 正在强制重装为 Alpine Linux...${NC}"
            
            # 直接触发重装，彻底清除原容器内所有数据
            if incus rebuild "$ALPINE_IMAGE" "$container" --force >/dev/null 2>&1; then
                echo -e "${GREEN}   ↳ ✅ 重装成功！${NC}\n"
            else
                echo -e "${RED}   ↳ ❌ 重装失败（请检查本地或远程 Alpine 镜像是否存在）${NC}\n"
            fi
        fi
    done 3<<< "$RUNNING_CONTAINERS"

    # 清理最后一次 printf 的残留行
    printf "\r%-60s\n" ""
    echo -e "${CYAN}=======================================${NC}"
    echo -e "${CYAN} 扫描与自动清理完成${NC}"
    echo -e "${CYAN}=======================================${NC}\n"

    if [ "$INFECTED_COUNT" -eq 0 ]; then
        echo -e "${GREEN}安全：所有运行中的容器均未发现哪吒探针。${NC}"
    else
        echo -e "${YELLOW}处理报告：共发现并自动重装了 ${RED}${INFECTED_COUNT}${NC} 个高风险容器。${NC}"
    fi
}

# === 执行主流程 ===
do_scan
