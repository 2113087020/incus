#!/bin/bash
# incus 定时任务一键配置脚本 (适配 v3.1 - 极致纯净日志版)

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"

echo -e "\n📦 正在配置定时任务调度外壳..."

# 写入后台调度脚本
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
# 显式引入环境变量
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

LOG_FILE="/var/log/incus_clean.log"

# 创建临时文件与防泄漏钩子
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# 设置 10 分钟全局超时，并在 curl 层增加网络超时
timeout 10m bash -c 'curl -sLf --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/2113087020/incus/main/incus.sh | bash' > "$TMP_OUT" 2>&1

# 🚨 【核心判断】如果全文没有“发现违规特征”，则直接静默退出，不写入任何日志！
if grep -q "发现违规特征" "$TMP_OUT"; then

    # 日志体积限制 100KB (约102400字节)
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已裁剪 ---" >> "$LOG_FILE"
    fi

    # 写入单行时间戳标题
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 拦截与重装记录 ===" >> "$LOG_FILE"
    
    # 极致精简日志：只提取“违规原因”和“重装结果”
    grep -E "发现违规特征|重装成功|重装失败" "$TMP_OUT" | \
    sed -E 's/\r/\n/g' | \
    sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' | \
    grep -E "发现违规特征|重装成功|重装失败" >> "$LOG_FILE"
    
    # 每次记录完毕加空行分隔
    echo "" >> "$LOG_FILE"
fi
EOF

echo "🔐 赋予外壳脚本执行权限..."
chmod +x "$CRON_SCRIPT"

echo "⏰ 正在配置每 5 分钟高频安全检测 (Crontab)..."
(crontab -l 2>/dev/null | grep -v "incus_cron.sh" ; echo "*/5 * * * * $CRON_SCRIPT") | crontab -

echo "------------------------------------------------"
echo "✅ 定时任务配置完成！"
echo "ℹ️  只有当抓到“内鬼”时，才会在日志中留下一笔，平时绝对安静。"
echo "📂 日志路径：$LOG_FILE"
