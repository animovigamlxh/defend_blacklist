#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v10
# 更新：增加了对 22 端口 (SSH) 的出入站 30s 频率限制

echo "✅ RUNNING SCRIPT VERSION 10 (WITH SSH RATE LIMIT)"
echo "🛡️ 欢迎使用机场节点最终安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# --- 辅助函数：分块应用规则 ---
apply_rules_in_chunks() {
    local fw_cmd="$1"
    local proto="$2"
    local action="$3"
    local port_list_str="$4"
    local fw_type="$5"
    local mode_info="$6"

    IFS=',' read -r -a port_array <<< "$port_list_str"
    local chunk_size=15
    local i=0
    while [ $i -lt ${#port_array[@]} ]; do
        chunk=("${port_array[@]:i:chunk_size}")
        chunk_str=$(IFS=,; echo "${chunk[*]}")
        "$fw_cmd" -A OUTPUT -p "$proto" -m multiport --dports "$chunk_str" -j "$action"
        
        local log_symbol="✅"; [ "$action" = "DROP" ] && log_symbol="🚫"
        echo "  [$log_symbol] ($fw_type) $mode_info: ${action}出站 $proto 端口: $chunk_str"
        i=$((i + chunk_size))
    done
}

# --- 交互式选择 ---
MODE=""
while [[ "$MODE" != "whitelist" && "$MODE" != "blacklist" ]]; do
    echo "请选择模式: 1) 白名单  2) 黑名单"
    read -p "请输入 [1 或 2]: " choice
    [ "$choice" = "1" ] && MODE="whitelist"
    [ "$choice" = "2" ] && MODE="blacklist"
done

# --- 配置区 ---
ALLOWED_TCP_PORTS="32400,8096,8008,53,80,443"
ALLOWED_UDP_PORTS="53"

# 注意：黑名单中不要包含 22，我们会单独处理它
BLOCKED_TCP_PORTS="21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632,5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070"
BLOCKED_UDP_PORTS="161"

[ "$EUID" -ne 0 ] && echo "❌ 请使用 root 运行" && exit 1

FW_COMMANDS=("iptables" "ip6tables")

for fw in "${FW_COMMANDS[@]}"; do
    FW_TYPE="IPv$( [ "$fw" = "iptables" ] && echo "4" || echo "6" )"
    echo "⚙️  正在配置 $FW_TYPE..."

    # 重置并允许基础流量
    $fw -F OUTPUT
    $fw -F INPUT 2>/dev/null # 清理输入链以便重新设置 SSH 限制
    $fw -P OUTPUT ACCEPT
    $fw -A OUTPUT -o lo -j ACCEPT
    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    $fw -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    if [ "$fw" = "iptables" ]; then $fw -A OUTPUT -p icmp -j ACCEPT; else $fw -A OUTPUT -p icmpv6 -j ACCEPT; fi

    if [ "$MODE" = "whitelist" ]; then
        apply_rules_in_chunks "$fw" "tcp" "ACCEPT" "$ALLOWED_TCP_PORTS" "$FW_TYPE" "白名单"
        apply_rules_in_chunks "$fw" "udp" "ACCEPT" "$ALLOWED_UDP_PORTS" "$FW_TYPE" "白名单"
        $fw -P OUTPUT DROP
    else
        # 黑名单模式：应用普通黑名单
        apply_rules_in_chunks "$fw" "tcp" "DROP" "$BLOCKED_TCP_PORTS" "$FW_TYPE" "黑名单"
        apply_rules_in_chunks "$fw" "udp" "DROP" "$BLOCKED_UDP_PORTS" "$FW_TYPE" "黑名单"

        # --- 特殊处理：SSH (22端口) 30秒频率限制 ---
        echo "  [🛡️] ($FW_TYPE) 正在配置 SSH 速率限制 (30秒/次)..."
        
        # 入站限制：防止外部暴力破解
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_LIMIT
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_LIMIT -j DROP
        $fw -A INPUT -p tcp --dport 22 -j ACCEPT

        # 出站限制：防止节点对外扫描
        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT_LIMIT
        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_OUT_LIMIT -j DROP
        $fw -A OUTPUT -p tcp --dport 22 -j ACCEPT
    fi
done

# 保存规则
echo "💾 正在保存规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
fi

echo "🎉 部署完成！SSH 限制已生效。"
