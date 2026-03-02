#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v13
# 更新：增加 SSH (22端口) 5秒/次 频率限制，修复所有语法兼容性问题

echo "✅ RUNNING SCRIPT VERSION 13"
echo "🛡️ 欢迎使用机场节点安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# 1. 基础检查
if [ "$EUID" -ne 0 ]; then
    echo "❌ 错误：请使用 root 权限运行"
    exit 1
fi

# 2. 立即清理恶意进程
echo "🔥 步骤 1: 清理扫描工具进程..."
pkill -9 -f "sshpass|hydra|medusa|ncrack|masscan" 2>/dev/null || true

# 3. 彻底重置防火墙 (IPv4 & IPv6)
echo "🧹 步骤 2: 重置防火墙规则..."
for tool in iptables ip6tables; do
    $tool -P INPUT ACCEPT
    $tool -P FORWARD ACCEPT
    $tool -P OUTPUT ACCEPT
    $tool -F && $tool -X && $tool -Z
    $tool -t nat -F 2>/dev/null
    $tool -t mangle -F 2>/dev/null
done

# 4. 交互模式选择
echo "请选择模式: 1) 白名单  2) 黑名单"
read -p "请输入 [1 或 2]: " choice

# 5. 配置定义
# 黑名单端口（已剔除22，由下方独立规则处理）
BLOCKED_TCP_1="21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632"
BLOCKED_TCP_2="5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070"
ALLOWED_TCP="80,443,53,32400,8096,8008"

# 6. 核心逻辑应用
for fw in iptables ip6tables; do
    FW_TYPE="IPv$( [ "$fw" = "iptables" ] && echo "4" || echo "6" )"
    echo "⚙️ 正在配置 $FW_TYPE 规则..."

    # --- 基础规则 ---
    $fw -A INPUT -i lo -j ACCEPT
    $fw -A OUTPUT -o lo -j ACCEPT
    $fw -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    [ "$fw" = "iptables" ] && $fw -A OUTPUT -p icmp -j ACCEPT || $fw -A OUTPUT -p icmpv6 -j ACCEPT

    # --- SSH (22端口) 5秒频率限制逻辑 ---
    # 入站限制 (别人连我)
    $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_SPEED_LIMIT
    $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 5 --hitcount 2 --name SSH_SPEED_LIMIT -j DROP
    $fw -A INPUT -p tcp --dport 22 -j ACCEPT

    # 出站限制 (我连别人)
    $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT_LIMIT
    $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 5 --hitcount 2 --name SSH_OUT_LIMIT -j DROP
    $fw -A OUTPUT -p tcp --dport 22 -j ACCEPT

    # --- 模式规则 ---
    if [ "$choice" = "1" ]; then
        # 白名单模式
        $fw -A OUTPUT -p tcp -m multiport --dports "$ALLOWED_TCP" -j ACCEPT
        $fw -A OUTPUT -p udp --dport 53 -j ACCEPT
        $fw -P OUTPUT DROP
    else
        # 黑名单模式
        $fw -A OUTPUT -p tcp -m multiport --dports "$BLOCKED_TCP_1" -j DROP
        $fw -A OUTPUT -p tcp -m multiport --dports "$BLOCKED_TCP_2" -j DROP
        $fw -A OUTPUT -p udp --dport 161 -j DROP
        $fw -P OUTPUT ACCEPT
    fi
done

# 7. 保存持久化
echo "💾 步骤 3: 永久保存规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables.rules
    # 尝试开机加载
    [ -f /etc/rc.local ] && ! grep -q "iptables-restore" /etc/rc.local && sed -i '/^exit 0/i iptables-restore < /etc/iptables.rules' /etc/rc.local
fi

echo "════════════════════════════════════════════════════════════════════"
echo "🎉 部署完成！"
echo "✅ SSH (22端口) 已设置为 5秒/次 频率限制。"
echo "📜 当前 IPv4 规则摘要:"
iptables -L OUTPUT -n --line-numbers
