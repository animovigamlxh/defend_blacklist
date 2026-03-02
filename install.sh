elif [ "$MODE" = "blacklist" ]; then
        echo "  [INFO] 应用黑名单规则..."
        # 1. 处理原本的黑名单端口（排除 22 端口，因为它现在有特殊规则）
        # 注意：确保你的 BLOCKED_TCP_PORTS 变量中不包含 22
        apply_rules_in_chunks "$fw" "tcp" "DROP" "$BLOCKED_TCP_PORTS" "$FW_TYPE" "黑名单"
        apply_rules_in_chunks "$fw" "udp" "DROP" "$BLOCKED_UDP_PORTS" "$FW_TYPE" "黑名单"

        # 2. 针对 22 端口 (SSH) 的速率限制规则
        echo "  [🛡️] ($FW_TYPE) 正在配置 SSH (22) 频率限制: 每 30 秒仅允许 1 次连接"
        
        # --- 入站限制 (防止外部连接过于频繁) ---
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_LIMIT
        $fw -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_LIMIT -j DROP
        $fw -A INPUT -p tcp --dport 22 -j ACCEPT
        
        # --- 出站限制 (防止节点主动对外扫描/连接) ---
        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --set --name SSH_OUT_LIMIT
        $fw -A OUTPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 30 --hitcount 2 --name SSH_OUT_LIMIT -j DROP
        $fw -A OUTPUT -p tcp --dport 22 -j ACCEPT

        echo "  [✅] ($FW_TYPE) SSH 速率限制已激活。"
        echo "  [🔓] ($FW_TYPE) 默认出站策略为 ACCEPT。黑名单模式激活！"
