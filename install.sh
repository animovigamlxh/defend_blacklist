#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v12.1 (修复 EOF 语法错误)
echo "✅ RUNNING SCRIPT VERSION 12.1"
echo "🛡️ 欢迎使用机场节点终极安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

# 1. 基础检查
[ "$EUID" -ne 0 ] && echo "❌ 错误：请使用 root 运行" && exit 1
if [ -n "$SSH_CLIENT" ]; then
    MY_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    echo "✅ 检测到管理 IP: $MY_IP (会话受保护)"
fi

# 2. 清理进程
echo "🔥 步骤 1: 正在清理活跃的扫描工具进程..."
pkill -9 -f "sshpass|hydra|medusa|ncrack|masscan" 2>/dev/null || true

# 3. 重置规则
echo "🧹 步骤 2: 正在深度清空所有旧规则..."
FW_TOOLS=("iptables" "ip6tables")
for tool in "${FW_TOOLS[@]}"; do
    $tool -P INPUT ACCEPT && $tool -P FORWARD ACCEPT && $tool -P OUTPUT ACCEPT
    $tool -F && $tool -X && $tool -Z
    $tool -t nat -F 2>/dev/null
    $tool -t mangle -F 2>/dev/null
done

# 4. 模式选择
read -p "请选择模式 [1-白名单, 2-黑名单]: " choice

# 5. 配置定义
ALLOWED_TCP="32400,8096,8008,53,80,443"
ALLOWED_UDP="53"
BLOCKED_TCP="21,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,5432,5632,5900,5984,6379,7001,8000,8161,9043,9200,11211,27017,50000,50070"

# 6. 核心逻辑
for fw in "${FW_TOOLS[@]}"; do
    FW_TYPE="IPv$( [ "$fw" = "iptables" ] && echo "4" || echo "6" )"
    echo "⚙️  正在部署 $FW_TYPE 规则..."

    # 基础放行
    $fw -A INPUT -i lo -j ACCEPT
    $fw -A OUTPUT -o lo -j ACCEPT
    $fw -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    [ "$fw" = "iptables" ] && $fw -A OUTPUT -p icmp -j ACCEPT || $fw -A OUTPUT -p icmpv6 -j ACCEPT

    # SSH 日志与限速 (30s/60s)
    $fw -A INPUT -p tcp --dport 22 -m state --state NEW -j LOG --log-prefix "SSH_IN: "
    $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_IN
    $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_IN -j DROP
    $fw -A INPUT -p tcp --dport 22 -j ACCEPT

    $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -j LOG --log-prefix "SSH_OUT: "
    $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT
    $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 2 --name SSH_OUT -j DROP
    $fw -A OUTPUT -p tcp --dport 22 -j ACCEPT

    if [ "$choice" == "1" ]; then
        # 白名单处理
        IFS=',' read -r -a ports <<< "$ALLOWED_TCP"
        for ((i=0; i<${#ports[@]}; i+=15)); do
            chunk=$(IFS=,; echo "${ports[*]:i:15}")
            $fw -A OUTPUT -p tcp -m multiport --dports "$chunk" -j ACCEPT
        done
        $fw -P OUTPUT DROP
    else
        # 黑名单处理
        IFS=',' read -r -a ports <<< "$BLOCKED_TCP"
        for ((i=0; i<${#ports[@]}; i+=15)); do
            chunk=$(IFS=,; echo "${ports[*]:i:15}")
            $fw -A OUTPUT -p tcp -m multiport --dports "$chunk" -j DROP
        done
        $fw -P OUTPUT ACCEPT
    fi
done

# 7. 持久化
echo "💾 步骤 3: 永久保存规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
fi
echo "🎉 部署完成！"
