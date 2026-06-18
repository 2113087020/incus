#!/bin/bash
# incus 定时任务一键配置脚本 (每30分钟执行一次)

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"

echo "📦 正在更新定时任务调度外壳..."

# 写入后台调度脚本
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
# 显式引入环境变量，防止 Cron 找不到 incus 或 curl 命令
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

LOG_FILE="/var/log/incus_clean.log"

# 【日志体积限制】如果日志超过 5MB (5242880 字节)，则只保留最后 1000 行
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 5242880 ]; then
    tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') 日志达到上限，已自动裁剪 ===" >> "$LOG_FILE"
fi

# 记录执行时间并调用你的 GitHub 远程脚本
echo "=== 自动任务启动: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"

# 动态拉取并运行新的脚本地址，同时将输出追加到日志
curl -sLf https://raw.githubusercontent.com/2113087020/incus/main/incus.sh | bash >> "$LOG_FILE" 2>&1

echo "=== 自动任务结束 ===" >> "$LOG_FILE"
EOF

echo "🔐 赋予外壳脚本执行权限..."
chmod +x "$CRON_SCRIPT"

echo "⏰ 正在配置每半小时定时任务 (Crontab)..."
# 自动过滤掉旧的同名任务，并添加新任务 (*/30 代表每30分钟执行一次)
(crontab -l 2>/dev/null | grep -v "incus_cron.sh" ; echo "*/30 * * * * $CRON_SCRIPT") | crontab -

echo "------------------------------------------------"
echo "✅ 恭喜：定时任务已更新！"
echo "ℹ️  提示：系统现在每 30 分钟会自动执行一次检测。"
echo "📄 运行日志路径: /var/log/incus_clean.log"
