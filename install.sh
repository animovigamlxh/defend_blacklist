#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v13.2 (深度修复版)
echo "✅ 正在深度重构防火墙规则..."

# 1. 彻底清空，确保没有残留的全放行规则
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F && iptables -X && iptables -Z

# 2. 基础安全：仅允许本地回环和已建立连接
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p icmp -j ACCEPT

# 3. SSH 入站限速 (3秒/次)
# 先记录/更新状态，如果 3s 内超过 1 次（hitcount 2）就 DROP
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_IN
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 3 --hitcount 2 --name SSH_IN -j DROP
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 4. SSH 出站限速 (3秒/次)
# 同样逻辑，防止本节点攻击他人
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 3 --hitcount 2 --name SSH_OUT -j DROP
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# 5. 应用黑名单 (分块处理)
iptables -A OUTPUT -p tcp -m multiport --dports 21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632 -j DROP
iptables -A OUTPUT -p tcp -m multiport --dports 5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070 -j DROP
iptables -A OUTPUT -p udp --dport 161 -j DROP

# 6. 保存
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables.rules
fi

echo "------------------------------------------------"
echo "✅ 修复完成！请核对下方的规则列表："
iptables -L OUTPUT -n --line-numbers
