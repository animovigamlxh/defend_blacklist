#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v12 (终极集成版)
# 更新：全量清理旧规则 + 恶意进程清除 + SSH 双向智能限速 + 攻击审计日志

echo "✅ RUNNING SCRIPT VERSION 12 (THE ULTIMATE SHIELD)"
echo "🛡️ 欢迎使用机场节点终极安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# --- 1. 基础检查与环境准备 ---
[ "$EUID" -ne 0 ] && echo "❌ 错误：请使用 root 运行" && exit 1

# 获取当前管理 IP
if [ -n "$SSH_CLIENT" ]; then
    MY_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    echo "✅ 检测到管理 IP: $MY_IP (会话受保护)"
fi

# --- 2. 立即停止潜在攻击进程 (参考您的脚本) ---
echo "🔥 步骤 1: 正在清理活跃的扫描工具进程..."
pkill -9 -f "sshpass|hydra|medusa|ncrack|masscan" 2>/dev/null || true
echo "✅ 内存清理完成。"

# --- 3. 彻底重置防火墙 (Deep Clean) ---
echo "🧹 步骤 2: 正在深度清空所有旧规则..."
FW_TOOLS=("iptables" "ip6tables")
for tool in "${FW_TOOLS[@]}"; do
    $tool -P INPUT ACCEPT
    $tool -P FORWARD ACCEPT
    $tool -P OUTPUT ACCEPT
    $tool -F && $tool -X && $tool -Z
    $tool -t nat -F 2>/dev/null
    $tool -t mangle -F 2>/dev/null
done
echo "✅ 已恢复到干净的默认状态。"

# --- 4. 模式选择 ---
MODE=""
while [[ "$MODE" != "whitelist" && "$MODE" != "blacklist" ]]; do
    echo "请选择运行模式:"
    echo "  1) 白名单 (极度严苛，仅允许核心流量)"
    echo "  2) 黑名单 (兼容性好，仅封禁已知风险)"
    read -p "请输入 [1 或 2]: " choice
    [ "$choice" = "1" ] && MODE="whitelist"
    [ "$choice" = "2" ] && MODE="blacklist"
done

# --- 5. 配置定义 ---
ALLOWED_TCP="32400,8096,8008,53,80,443"
ALLOWED_UDP="53"
BLOCKED_TCP="21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632,5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070"

# --- 6. 辅助函数 ---
apply_rules_in_chunks() {
    local fw_cmd="$1"; local proto="$2"; local action="$3"; local port_list="$4"
    IFS=',' read -r -a port_array <<< "$port_list"
    for ((i=0; i<${#port_array[@]}; i+=15)); do
        chunk=$(IFS=,; echo "${port_array[*]:i:15}")
        "$fw_cmd" -A OUTPUT -p "$proto" -m multiport --dports "$chunk" -j "$
