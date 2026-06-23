#!/bin/bash
# incus 定时任务一键配置脚本 (每30分钟执行一次)

CRON_SCRIPT="/usr/local/bin/incus_cron.sh"

echo "📦 正在配置定时任务调度外壳..."

# 写入后台调度脚本
cat << 'EOF' > "$CRON_SCRIPT"
#!/bin/bash
# 显式引入环境变量，防止 Cron 找不到命令
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"

LOG_FILE="/var/log/incus_clean.log"

# 创建临时文件与防泄漏钩子
TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# 设置 10 分钟超时防卡死，执行并捕获输出
timeout 10m bash -c 'curl -sLf https://raw.githubusercontent.com/2113087020/incus/main/incus.sh | bash' > "$TMP_OUT" 2>&1

# 检查输出中是否包含违规重装的特征关键字
if grep -q "发现违规特征" "$TMP_OUT"; then

    # 日志体积限制 100KB (约102400字节)
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt 102400 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "--- $(date '+%Y-%m-%d %H:%M:%S') 日志超 100KB 已裁剪 ---" >> "$LOG_FILE"
    fi

    # 写入单行时间戳标题
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] 触发自动重装 ===" >> "$LOG_FILE"
    
    # 精简日志：只提取核心干货动作并去除 ANSI 颜色乱码
    grep -E "发现违规特征|重装成功|重装失败|处理报告" "$TMP_OUT" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE"
    
    # 每次记录完毕加空行分隔
    echo "" >> "$LOG_FILE"
fi
EOF

echo "🔐 赋予外壳脚本执行权限..."
chmod +x "$CRON_SCRIPT"

echo "⏰ 正在配置每半小时定时任务 (Crontab)..."
# 自动过滤旧任务并追加新任务
(crontab -l 2>/dev/null | grep -v "incus_cron.sh" ; echo "*/30 * * * * $CRON_SCRIPT") | crontab -

echo "------------------------------------------------"
echo "✅ 定时任务配置完成！"
echo "ℹ️  提示：系统每 30 分钟默默检测，【只有抓到违规进程时】才会将极简日志写入：$LOG_FILE"
