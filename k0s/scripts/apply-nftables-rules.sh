#!/bin/bash
# =============================================================================
# 应用 Calico 网络放行规则 — 让 pod 流量在 Tailscale overlay 上正常工作
# =============================================================================
# 解决的问题(节点重启后 nft/iptables 规则会丢, 故需本脚本 + systemd 单元重应用):
#
#   问题13: IPVS 把 Service IP DNAT 到本机 Tailscale IP, 包走 INPUT 链,
#           Calico 的 INPUT 链默认丢弃来自 pod 网络(10.244.0.0/16)的包。
#           → 在 iptables INPUT 链最前放行 pod 网段。
#
#   问题14: 跨节点 pod 流量走 FORWARD 链, 默认 policy DROP。
#           → 在 FORWARD 链最前放行 cali 接口进出。
#
#   额外: 清理陈旧的 nft calico 表。若 felix 曾以 nftables 模式运行过(或人为设置过
#   FELIX_NFTABLESMODE=Enabled), 会遗留 `table ip calico` 并挂在 forward/input hook
#   上, 与 iptables 模式的 cali-* 链并行处理包, 导致新连接被过期策略 DROP
#   (表现为 pod 全部不通但节点 Ready)。iptables 模式下该表属陈旧遗物, 直接删除。
#
# 幂等: 每条规则带 comment 标记, 重复执行不会产生重复规则。
# 健壮: 开机早执行时 Calico 尚未建链, 本脚本会等待其出现。
#
# 用法:
#   sudo POD_CIDR=10.244.0.0/16 ./apply-nftables-rules.sh
# 由 systemd 单元 k0s-calico-nftables.service 在开机后调用, 也可手动执行。
# =============================================================================
set -u

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
WAIT_SECS="${WAIT_SECS:-90}"

# ---------------------------------------------------------------------------
# 0. 清理陈旧的 nft calico 表(iptables 模式下felix 不使用它们)
#    存在即删: felix 若真的运行 nftables 模式会在启动时重建
# ---------------------------------------------------------------------------
for t in "ip calico" "ip6 calico"; do
  if nft list table $t >/dev/null 2>&1; then
    nft delete table $t && echo "  - 已删除陈旧 nft 表: $t"
  fi
done

# 等待某 nft 链存在(Calico 在开机后由 calico-node 重建 iptables-nft 链)
wait_chain() {
  local family="$1" table="$2" chain="$3"
  for _ in $(seq 1 "$WAIT_SECS"); do
    if nft list chain "$family" "$table" "$chain" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "WARN: nft 链 $family $table $chain 在 ${WAIT_SECS}s 内未出现, 跳过"
  return 1
}

# 幂等插入: 链中已有该标记则跳过
ensure_rule() {
  local family="$1" table="$2" chain="$3" marker="$4"; shift 4
  wait_chain "$family" "$table" "$chain" || return 0
  if nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "$marker"; then
    return 0
  fi
  # insert 到链首, 确保在 Calico DROP 规则之前生效
  nft insert rule "$family" "$table" "$chain" "$@" comment "\"$marker\"" 2>/dev/null \
    && echo "  + $family $table $chain: $*" \
    || echo "  ! $family $table $chain: 插入失败($*)"
}

echo "=== 应用 Calico 网络放行规则 (POD_CIDR=$POD_CIDR) ==="

# ---------------------------------------------------------------------------
# 问题18: pod → tailnet(100.64.0.0/10) 流量从物理网卡漏出
#   calico 给 pod 出向包打 0x80000 标记(rpf-skip), tailscale 的策略规则
#   "fwmark 0x80000 → lookup main" 优先于其 table 52, 而 main 表没有 tailnet
#   路由 → 命中默认路由(物理网卡) → 包被丢弃(konnectivity agent 无法连 server)。
#   修复: 在 main 表补一条 tailnet 路由。MASQ 会自动改用 tailscale0 的地址作源。
# ---------------------------------------------------------------------------
if ip link show tailscale0 >/dev/null 2>&1; then
  if ! ip route show table main | grep -q "^100.64.0.0/10"; then
    ip route replace 100.64.0.0/10 dev tailscale0 table main \
      && echo "  + main 表: 100.64.0.0/10 dev tailscale0"
  else
    echo "  = main 表 tailnet 路由已存在"
  fi
fi

# 问题13: 放行 pod 网段到本机的 INPUT 流量(Service DNAT 后走 INPUT;
#         kubelet 探针 / konnectivity 等依赖此路径)
ensure_rule ip filter INPUT k0s-ts-in-ipt ip saddr "$POD_CIDR" accept

# 问题14: 放行 cali 接口的 FORWARD 流量(跨节点 pod 通信)
ensure_rule ip filter FORWARD k0s-ts-fwd-in  iifname "cali*" accept
ensure_rule ip filter FORWARD k0s-ts-fwd-out oifname "cali*" accept

echo "=== 网络放行规则应用完成 ==="
