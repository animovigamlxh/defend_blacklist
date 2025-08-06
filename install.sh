#!/bin/bash

# 🛡️ 机场节点最终安全脚本 v8 (交互式模式选择)
# Airport Node Final Security Shield v8 - Interactive Mode Selection

echo "✅ RUNNING SCRIPT VERSION 8 (INTERACTIVE MODE)"
echo "🛡️ 欢迎使用机场节点最终安全防护脚本"
echo "════════════════════════════════════════════════════════════════════"

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

# 白名单模式配置 (当 MODE="whitelist")
ALLOWED_TCP_PORTS="32400,8096,8008,53,80,443"
ALLOWED_UDP_PORTS="53"

# 黑名单模式配置 (当 MODE="blacklist")
# 从 https://www.cnblogs.com/xiaozi/p/13296754.html 提取的常见高风险端口
BLOCKED_TCP_PORTS="21,22,23,25,445,873,1090,1099,1433,1521,2181,2375,3306,3389,5432,5632,5900,5984,6379,7001,8000,8080,8161,9043,9200,11211,27017,50000,50070"
BLOCKED_UDP_PORTS="161" # SNMP

# --- 脚本核心 ---

# 检查root权限
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误：此脚本需要root权限运行。请使用 sudo bash $0"
  exit 1
fi

FW_COMMANDS=("iptables" "ip6tables")

# 备份当前规则，仅供紧急手动恢复
BACKUP_FILE_V4="/tmp/iptables_backup_final_$(date +%Y%m%d_%H%M%S).v4.rules"
BACKUP_FILE_V6="/tmp/ip6tables_backup_final_$(date +%Y%m%d_%H%M%S).v6.rules"
echo "🔄 正在备份当前规则 (仅供紧急手动恢复)..."
iptables-save > "$BACKUP_FILE_V4"
ip6tables-save > "$BACKUP_FILE_V6"
echo "✅ 备份完成。"

for fw in "${FW_COMMANDS[@]}"; do
    FW_TYPE="IPv$( if [ "$fw" = "iptables" ]; then echo "4"; else echo "6"; fi )"
    echo "⚙️  正在为 $fw ($FW_TYPE) 使用 $MODE 模式重建规则..."

    # 1. 强制清空 (Flush) OUTPUT 链中的所有旧规则
    $fw -F OUTPUT
    echo "  [🧹] 已清空 $fw 的 OUTPUT 链。"

    # 2. 初始策略: 设为 ACCEPT，以防在规则应用期间中断连接
    $fw -P OUTPUT ACCEPT

    # 3. 核心规则 (对两种模式都通用)
    # 允许本地回环接口 (lo)
    $fw -A OUTPUT -o lo -j ACCEPT
    echo "  [✅] ($FW_TYPE) 允许本地回环 (lo) 流量"

    # 允许已建立和相关的连接 (保护当前SSH会话等)
    $fw -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo "  [✅] ($FW_TYPE) 允许已建立的连接"
    
    # 允许ICMP (Ping)
    if [ "$fw" = "iptables" ]; then
        $fw -A OUTPUT -p icmp -j ACCEPT
    else
        $fw -A OUTPUT -p icmpv6 -j ACCEPT
    fi
    echo "  [✅] ($FW_TYPE) 允许 ICMP 流量"

    if [ "$MODE" = "whitelist" ]; then
        # --- 白名单模式逻辑 ---
        echo "  [INFO] 应用白名单规则..."
        if [ -n "$ALLOWED_TCP_PORTS" ]; then
            $fw -A OUTPUT -p tcp -m multiport --dports "$ALLOWED_TCP_PORTS" -j ACCEPT
            echo "  [✅] ($FW_TYPE) 白名单: 允许出站 TCP 端口: $ALLOWED_TCP_PORTS"
        fi
        if [ -n "$ALLOWED_UDP_PORTS" ]; then
            $fw -A OUTPUT -p udp -m multiport --dports "$ALLOWED_UDP_PORTS" -j ACCEPT
            echo "  [✅] ($FW_TYPE) 白名单: 允许出站 UDP 端口: $ALLOWED_UDP_PORTS"
        fi

        # 锁定策略：将默认策略设置为 DROP
        $fw -P OUTPUT DROP
        echo "  [🔒] ($FW_TYPE) 默认出站策略已设置为 DROP。白名单模式激活！"

    elif [ "$MODE" = "blacklist" ]; then
        # --- 黑名单模式逻辑 ---
        echo "  [INFO] 应用黑名单规则..."
        if [ -n "$BLOCKED_TCP_PORTS" ]; then
            $fw -A OUTPUT -p tcp -m multiport --dports "$BLOCKED_TCP_PORTS" -j DROP
            echo "  [🚫] ($FW_TYPE) 黑名单: 阻止出站 TCP 端口: $BLOCKED_TCP_PORTS"
        fi
        if [ -n "$BLOCKED_UDP_PORTS" ]; then
            $fw -A OUTPUT -p udp -m multiport --dports "$BLOCKED_UDP_PORTS" -j DROP
            echo "  [🚫] ($FW_TYPE) 黑名单: 阻止出站 UDP 端口: $BLOCKED_UDP_PORTS"
        fi
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
