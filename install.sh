#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v9 (修复黑名单长端口列表问题)
# Airport Node Final Security Shield v9 - Long Port List Fix

echo "✅ RUNNING SCRIPT VERSION 9 (INTERACTIVE MODE WITH CHUNKING)"
echo "🛡️ 欢迎使用机场节点最终安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# --- 辅助函数：分块应用规则 ---
# iptables的multiport模块一次最多只支持15个端口。此函数将长列表分块处理。
apply_rules_in_chunks() {
    local fw_cmd="$1"
    local proto="$2"
    local action="$3"
    local port_list_str="$4"
    local fw_type="$5"
    local mode_info="$6" # "白名单" 或 "黑名单"

    # 将逗号分隔的字符串转换为数组
    IFS=',' read -r -a port_array <<< "$port_list_str"
    
    local chunk_size=15
    local i=0
    while [ $i -lt ${#port_array[@]} ]; do
        # 从数组中提取一个块
        chunk=("${port_array[@]:i:chunk_size}")
        # 将块转换回逗号分隔的字符串
        chunk_str=$(IFS=,; echo "${chunk[*]}")
        
        # 应用规则
        "$fw_cmd" -A OUTPUT -p "$proto" -m multiport --dports "$chunk_str" -j "$action"
        
        local log_symbol="✅"
        local log_action_text="允许"
        if [ "$action" = "DROP" ]; then
            log_symbol="🚫"
            log_action_text="阻止"
        fi
        echo "  [$log_symbol] ($fw_type) $mode_info: ${log_action_text}出站 $proto 端口 (块): $chunk_str"
        
        i=$((i + chunk_size))
    done
}


# --- 交互式模式选择 ---
MODE=""
while [[ "$MODE" != "whitelist" && "$MODE" != "blacklist" ]]; do
    echo "请选择要应用的防火墙模式:"
    echo "  1) 白名单模式 (推荐 - 更安全): 仅允许核心服务端口，阻止所有其他端口。"
    echo "  2) 黑名单模式 (较宽松): 允许所有端口，仅阻止已知的风险端口。"
    read -p "请输入选项 [1 或 2]: " choice
    case "$choice" in
        1 ) MODE="whitelist";;
        2 ) MODE="blacklist";;
        * ) echo "❌ 无效输入。请输入 1 或 2。";;
    esac
done

echo "您已选择: $MODE 模式"
echo "🛡️ 正在启动安全防护部署..."
if [ "$MODE" = "whitelist" ]; then
    echo "策略：默认阻止所有出站连接，仅放行指定的核心流量。"
else
    echo "策略：默认放行所有出站连接，仅阻止已知的风险端口。"
fi
echo "════════════════════════════════════════════════════════════════════"

# --- 配置区 (白名单/黑名单定义) ---

# 白名单模式配置
ALLOWED_TCP_PORTS="32400,8096,8008,53,80,443"
ALLOWED_UDP_PORTS="53"

# 黑名单模式配置
BLOCKED_TCP_PORTS="21,22,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,3389,5432,5632,5900,5984,6379,7001,8000,8080,8161,9043,9200,11211,27017,50000,50070"
BLOCKED_UDP_PORTS="161" # SNMP

# --- 脚本核心 ---

# 检查root权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：此脚本需要root权限运行。请使用 sudo bash $0"
  exit 1
fi

FW_COMMANDS=("iptables" "ip6tables")

# 备份当前规则
BACKUP_FILE_V4="/tmp/iptables_backup_final_$(date +%Y%m%d_%H%M%S).v4.rules"
BACKUP_FILE_V6="/tmp/ip6tables_backup_final_$(date +%Y%m%d_%H%M%S).v6.rules"
echo "🔄 正在备份当前规则..."
iptables-save > "$BACKUP_FILE_V4"
ip6tables-save > "$BACKUP_FILE_V6"
echo "✅ 备份完成。"

for fw in "${FW_COMMANDS[@]}"; do
    FW_TYPE="IPv$( if [ "$fw" = "iptables" ]; then echo "4"; else echo "6"; fi )"
    echo "⚙️  正在为 $fw ($FW_TYPE) 使用 $MODE 模式重建规则..."

    $fw -F OUTPUT
    echo "  [🧹] 已清空 $fw 的 OUTPUT 链。"

    $fw -P OUTPUT ACCEPT

    $fw -A OUTPUT -o lo -j ACCEPT
    echo "  [✅] ($FW_TYPE) 允许本地回环 (lo) 流量"

    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo "  [✅] ($FW_TYPE) 允许已建立的连接"
    
    if [ "$fw" = "iptables" ]; then
        $fw -A OUTPUT -p icmp -j ACCEPT
    else
        $fw -A OUTPUT -p icmpv6 -j ACCEPT
    fi
    echo "  [✅] ($FW_TYPE) 允许 ICMP 流量"

    if [ "$MODE" = "whitelist" ]; then
        echo "  [INFO] 应用白名单规则..."
        apply_rules_in_chunks "$fw" "tcp" "ACCEPT" "$ALLOWED_TCP_PORTS" "$FW_TYPE" "白名单"
        apply_rules_in_chunks "$fw" "udp" "ACCEPT" "$ALLOWED_UDP_PORTS" "$FW_TYPE" "白名单"
        $fw -P OUTPUT DROP
        echo "  [🔒] ($FW_TYPE) 默认出站策略已设置为 DROP。白名单模式激活！"

    elif [ "$MODE" = "blacklist" ]; then
        echo "  [INFO] 应用黑名单规则..."
        apply_rules_in_chunks "$fw" "tcp" "DROP" "$BLOCKED_TCP_PORTS" "$FW_TYPE" "黑名单"
        apply_rules_in_chunks "$fw" "udp" "DROP" "$BLOCKED_UDP_PORTS" "$FW_TYPE" "黑名单"
        echo "  [🔓] ($FW_TYPE) 默认出站策略为 ACCEPT。黑名单模式激活！"
    fi
done

# --- 保存规则以实现持久化 ---
echo "💾 正在永久保存防火墙规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    if command -v apt-get &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent || true
    fi
    iptables-save > /etc/iptables/rules.v4 2>/dev/null
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
fi

echo "🎉 部署完成！您的机场节点已根据 '$MODE' 模式配置了新的防火墙策略。"
echo "════════════════════════════════════════════════════════════════════"
echo "📜 当前 IPv4 出站规则摘要:"
iptables -L OUTPUT -n --line-numbers
echo ""
echo "📜 当前 IPv6 出站规则摘要:"
ip6tables -L OUTPUT -n --line-numbers
echo ""
echo "✅ 脚本执行完毕。祝您使用愉快！"
