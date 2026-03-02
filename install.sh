#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v13.3
# 修复内容：强制移除全局 ACCEPT 规则，确保限速和黑名单生效

echo "✅ 正在执行 v13.3 深度修复脚本..."

# 1. 彻底重置
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F && iptables -X && iptables -Z

# 2. 基础放行 (精准限制到 lo 网卡)
# 注意：这里使用 -I (Insert) 确保它们排在最前面
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# 3. SSH 入站限速 (3秒/次)
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_IN
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 3 --hitcount 2 --name SSH_IN -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 4. SSH 出站限速 (3秒/次)
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 3 --hitcount 2 --name SSH_OUT -j DROP
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# 5. 应用黑名单
# 分块处理以绕过 multiport 15个端口限制
iptables -A OUTPUT -p tcp -m multiport --dports 21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632 -j DROP
iptables -A OUTPUT -p tcp -m multiport --dports 5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070 -j DROP
iptables -A OUTPUT -p udp --dport 161 -j DROP

# 6. --- 关键修复步骤 ---
# 检查是否生成了多余的全局放行规则并将其删除
# 逻辑：如果第一条规则是 ACCEPT 且没有绑定网卡(lo)，则删除它
global_accept=$(iptables -L OUTPUT 1 -n | grep "ACCEPT" | grep "0.0.0.0/0" | grep -v "lo")
if [ -n "$global_accept" ]; then
    echo "⚠️ 检测到多余的全局放行规则，正在移除以确保黑名单生效..."
    iptables -D OUTPUT 1
fi

# 7. 持久化保存
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables.rules
fi

echo "------------------------------------------------"
echo "🎉 部署完成！请检查下方输出，确保第1条显示为 'lo' 而不是 '0.0.0.0/0'"
iptables -L OUTPUT -n --line-numbers
