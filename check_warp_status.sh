#!/bin/bash

# WARP配置状态检查脚本

echo "====== WARP配置状态检查 ======"
echo ""

# 1. 检查nodes.json文件位置
echo "1. 查找nodes.json文件:"
for dir in /data /etc/sing-box ~/.sing-box ./data; do
    if [[ -f "$dir/nodes.json" ]]; then
        echo "  找到: $dir/nodes.json"
        NODES_FILE="$dir/nodes.json"
    fi
done

if [[ -z "$NODES_FILE" ]]; then
    echo "  ❌ 未找到nodes.json文件"
    exit 1
fi

echo ""

# 2. 检查节点的warp_outbound字段
echo "2. 节点WARP状态:"
jq -r '.nodes[] | "\(.port)|\(.protocol)|\(.warp_outbound // "未设置")"' "$NODES_FILE" 2>/dev/null | while IFS='|' read -r port protocol warp; do
    if [[ "$warp" == "true" ]]; then
        echo "  ✓ 端口 $port ($protocol): WARP已启用"
    else
        echo "  - 端口 $port ($protocol): WARP未启用"
    fi
done

echo ""

# 3. 统计启用WARP的节点数
echo "3. 启用WARP的节点统计:"
warp_count=$(jq -r '[.nodes[] | select(.warp_outbound == true)] | length' "$NODES_FILE" 2>/dev/null)
echo "  启用WARP的节点数: $warp_count"

echo ""

# 4. 检查WARP配置文件
echo "4. WARP配置文件:"
if [[ -f "/etc/wireguard/wgcf-profile.conf" ]]; then
    echo "  ✓ /etc/wireguard/wgcf-profile.conf 存在"

    # 读取关键配置
    private_key=$(grep "^PrivateKey" /etc/wireguard/wgcf-profile.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')
    endpoint=$(grep "^Endpoint" /etc/wireguard/wgcf-profile.conf | cut -d= -f2 | tr -d ' ' | tr -d '\r')

    if [[ -n "$private_key" && -n "$endpoint" ]]; then
        echo "  ✓ 配置有效 (Endpoint: $endpoint)"
    else
        echo "  ❌ 配置不完整"
    fi
else
    echo "  ❌ WARP配置文件不存在"
fi

echo ""

# 5. 检查sing-box配置中的WARP出站
echo "5. sing-box配置中的WARP:"
for config in /etc/sing-box/config.json ~/.sing-box/config.json ./config.json; do
    if [[ -f "$config" ]]; then
        echo "  检查: $config"

        # 检查是否有warp-out出站
        warp_out=$(jq -r '.outbounds[] | select(.tag == "warp-out") | .tag' "$config" 2>/dev/null)
        if [[ -n "$warp_out" ]]; then
            echo "  ✓ WARP出站已配置"

            # 检查有多少inbound绑定了WARP
            detour_count=$(jq -r '[.inbounds[] | select(.detour == "warp-out")] | length' "$config" 2>/dev/null)
            echo "  ✓ 绑定WARP的入站数: $detour_count"

            # 列出绑定WARP的端口
            if [[ "$detour_count" -gt 0 ]]; then
                echo "  绑定WARP的端口:"
                jq -r '.inbounds[] | select(.detour == "warp-out") | .listen_port' "$config" 2>/dev/null | while read -r p; do
                    echo "    - $p"
                done
            fi
        else
            echo "  ❌ 未找到WARP出站"
        fi
        break
    fi
done

echo ""

# 6. 检查config_generator.sh版本
echo "6. config_generator.sh版本检查:"
for cg_path in ./modules/config_generator.sh /root/s-singbox/modules/config_generator.sh; do
    if [[ -f "$cg_path" ]]; then
        if grep -q "检测到.*个节点启用WARP出站" "$cg_path" 2>/dev/null; then
            echo "  ✓ $cg_path 包含最新的WARP检测代码"
        else
            echo "  ❌ $cg_path 未包含最新的WARP检测代码"
        fi
        break
    fi
done

echo ""
echo "====== 检查完成 ======"
