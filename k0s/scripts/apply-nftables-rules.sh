#!/bin/bash
# =============================================================================
# 应用 Calico nftables 放行规则 — 让 pod 流量在 Tailscale overlay 上正常工作
# =============================================================================
# 解决两类问题(节点重启后 nft 规则会丢, 故需本脚本 + systemd 单元重应用):
#
#   问题13: IPVS 把 Service IP DNAT 到本机 Tailscale IP, 包走 INPUT 链,
#           Calico nft INPUT 链默认丢弃来自 pod 网络(10.244.0.0/16)的包。
#           → 在 INPUT 链最前放行 pod 网段。
#
#   问题14: 跨节点 pod 流量走 FORWARD 链, nft ip filter FORWARD 默认 policy DROP,
#           Calico dispatch 链未正确放行 cali 接口。
#           → 在 FORWARD 链最前放行 cali* 接口进出。
#
# 幂等: 每条规则带 comment 标记, 重复执行不会产生重复规则。
# 健壮: 开机早执行时 Calico 的 nft 表/链可能还没建好, 本脚本会等待其出现。
#
# 用法:
#   sudo POD_CIDR=10.244.0.0/16 ./apply-nftables-rules.sh
# 由 systemd 单元 k0s-calico-nftables.service 在开机后调用, 也可手动执行。
# =============================================================================
set -u

POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
WAIT_SECS="${WAIT_SECS:-90}"

# 等待某 nft 表存在(Calico 在开机后由 calico-node 重建 ip calico 表)
wait_table() {
  local family="$1" table="$2"
  for _ in $(seq 1 "$WAIT_SECS"); do
    if nft list table "$family" "$table" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "WARN: nft 表 $family $table 在 ${WAIT_SECS}s 内未出现(Calico 可能未就绪), 跳过该表规则"
  return 1
}

# 等待某 nft 链存在
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

echo "=== 应用 Calico nftables 放行规则 (POD_CIDR=$POD_CIDR) ==="

# 问题13: 放行 pod 网段到本机的 INPUT 流量(Service DNAT 后走 INPUT)
ensure_rule ip calico filter-INPUT k0s-ts-in-calico ip saddr "$POD_CIDR" accept
ensure_rule ip filter  INPUT      k0s-ts-in-ipt   ip saddr "$POD_CIDR" accept

# 问题14: 放行 cali 接口的 FORWARD 流量(跨节点 pod 通信)
ensure_rule ip filter FORWARD k0s-ts-fwd-in  iifname "cali*" accept
ensure_rule ip filter FORWARD k0s-ts-fwd-out oifname "cali*" accept

echo "=== nftables 规则应用完成 ==="
