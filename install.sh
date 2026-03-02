#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v11
# 更新：执行前全量清空旧规则 + SSH (22端口) 30秒频率限制

echo "✅ RUNNING SCRIPT VERSION 11 (CLEAN SLATE + SSH LIMIT)"
echo "🛡️ 欢迎使用机场节点最终安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# --- 检查root权限 ---
[ "$EUID" -ne 0 ] && echo "❌ 错误：请使用 sudo bash 运行" && exit 1

# --- 1. 彻底清空旧规则 (预防冲突) ---
echo "🧹 正在深度清理旧的防火墙规则..."
FW_TOOLS=("iptables" "ip6tables")

for tool in "${FW_TOOLS[@]}"; do
    # 设置默认策略为 ACCEPT，防止清空规则时立即断开 SSH
    $tool -P INPUT ACCEPT
    $tool -P FORWARD ACCEPT
    $tool -P OUTPUT ACCEPT
    
    # 清空所有规则链
    $tool -F 
    # 删除所有自定义链
    $tool -X 
    # 清空所有计数器
    $tool -Z 
    # 清空 nat 和 mangle 表 (如果存在)
    $tool -t nat -F 2>/dev/null
    $tool -t mangle -F 2>/dev/null
done
echo "✅ 旧规则已全部抹除。现在是干净的状态。"

# --- 2. 模式选择 ---
MODE=""
while [[ "$MODE" != "whitelist" && "$MODE" != "blacklist" ]]; do
    echo "请选择模式: 1) 白名单 (严苛)  2) 黑名单 (宽松)"
    read -p "请输入 [1 或 2]: " choice
    [ "$choice" = "1" ] && MODE="whitelist"
    [ "$choice" = "2" ] && MODE="blacklist"
done

# --- 3. 配置定义 ---
ALLOWED_TCP="32400,8096,8008,53,80,443"
ALLOWED_UDP="53"
# 黑名单不含22，22由下方独立规则控制频率
BLOCKED_TCP="21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632,5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070"
BLOCKED_UDP="161"

# --- 4. 辅助函数：分块应用规则 ---
apply_rules_in_chunks() {
    local fw_cmd="$1"; local proto="$2"; local action="$3"
    local port_list="$4"; local fw_type="$5"; local mode_info="$6"
    IFS=',' read -r -a port_array <<< "$port_list"
    local i=0
    while [ $i -lt ${#port_array[@]} ]; do
        chunk=("${port_array[@]:i:15}")
        chunk_str=$(IFS=,; echo "${chunk[*]}")
        "$fw_cmd" -A OUTPUT -p "$proto" -m multiport --dports "$chunk_str" -j "$action"
        i=$((i + 15))
    done
}

# --- 5. 核心规则部署 ---
for fw in "${FW_TOOLS[@]}"; do
    FW_TYPE="IPv$( [ "$fw" = "iptables" ] && echo "4" || echo "6" )"
    echo "⚙️  正在配置 $FW_TYPE ($MODE)..."

    # 基础放行
    $fw -A INPUT -i lo -j ACCEPT
    $fw -A OUTPUT -o lo -j ACCEPT
    $fw -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # ICMP (Ping)
    [ "$fw" = "iptables" ] && $fw -A OUTPUT -p icmp -j ACCEPT || $fw -A OUTPUT -p icmpv6 -j ACCEPT

    if [ "$MODE" = "whitelist" ]; then
        apply_rules_in_chunks "$fw" "tcp" "ACCEPT" "$ALLOWED_TCP" "$FW_TYPE" "白名单"
        apply_rules_in_chunks "$fw" "udp" "ACCEPT" "$ALLOWED_UDP" "$FW_TYPE" "白名单"
        # 即使是白名单，SSH也需要单独放行并限速
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_LIMIT
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_LIMIT -j DROP
        $fw -A INPUT -p tcp --dport 22 -j ACCEPT
        
        $fw -P OUTPUT DROP
        echo "  [🔒] $FW_TYPE 默认策略已设为 DROP"
    else
        # 黑名单模式
        apply_rules_in_chunks "$fw" "tcp" "DROP" "$BLOCKED_TCP" "$FW_TYPE" "黑名单"
        apply_rules_in_chunks "$fw" "udp" "DROP" "$BLOCKED_UDP" "$FW_TYPE" "黑名单"

        # SSH 30秒速率限制 (入站+出站)
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_LIMIT
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_LIMIT -j DROP
        $fw -A INPUT -p tcp --dport 22 -j ACCEPT

        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT_LIMIT
        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_OUT_LIMIT -j DROP
        $fw -A OUTPUT -p tcp --dport 22 -j ACCEPT
        
        $fw -P OUTPUT ACCEPT
        echo "  [🔓] $FW_TYPE 默认策略已设为 ACCEPT"
    fi
done

# --- 6. 持久化 ---
echo "💾 正在永久保存规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
fi

echo "🎉 部署完成！旧规则已清理，新策略已生效。"
echo "════════════════════════════════════════════════════════════════════"
