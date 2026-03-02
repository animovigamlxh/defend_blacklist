#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v13.7 (仅限出站频率版)
echo "✅ 正在部署脚本：放开入站限制，仅锁定出站频率..."

# 1. 彻底清空，确保没有干扰
iptables -F && iptables -X && iptables -Z

# 2. 状态放行：保证当前连接不断开
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 3. 【核心修改】入站规则：完全放开 SSH (由 SSH 服务自身处理验证)
# 不再对入站做 recent 计数，避免被攻击者干扰
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

# 4. 【核心修改】出站规则：严格限制 (防止对外爆破)
# 允许你连别人，但如果你的机器在 20秒内发起超过 10个新连接，则判定为异常并拦截
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT_ONLY
iptables -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 20 --hitcount 10 --name SSH_OUT_ONLY -j DROP
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT

# 5. 黑名单拦截 (保持不变)
iptables -A OUTPUT -p tcp -m multiport --dports 21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632 -j DROP
iptables -A OUTPUT -p tcp -m multiport --dports 5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070 -j DROP
iptables -A OUTPUT -p udp --dport 161 -j DROP

# 6. 清理之前的干扰记录
echo / > /proc/net/xt_recent/SSH_OUT_ONLY 2>/dev/null

# 7. 持久化
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables.rules
fi

echo "------------------------------------------------"
echo "🎉 部署完成！"
echo "👉 入站：不再限制频率（解决被攻击导致的误杀问题）。"
echo "👉 出站：保持 20s/10次 频率限制（防止对外爆破投诉）。"
