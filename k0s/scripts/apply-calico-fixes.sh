#!/bin/bash
# =============================================================================
# k0s + Tailscale/Headscale 组网 — Calico 修复脚本(幂等, 可重复执行)
# =============================================================================
# 在 k0sctl apply 完成、集群基本可用后, 在 controller 上以 root 执行一次。
# 修复 k0s v1.36 在 overlay-over-WireGuard 环境下无法通过 k0s.yaml 配置的剩余
# Calico 问题(CRD/RBAC 版本不匹配、kube-controllers loadbalancer 不兼容、
# nftables 放行规则)。
#
# 用法:
#   sudo K0S_CONTROLLER_IP=100.64.0.1 K0S_WORKER_IP=100.64.0.8 \
#        POD_CIDR=10.244.0.0/16 ./apply-calico-fixes.sh
# 不带参数时会尝试读取仓库根的 .env。
#
# 幂等: 所有操作均声明式或带去重, reset 后重新 apply 集群可再次安全运行。
# =============================================================================
set -euo pipefail

# ---- 定位仓库根与 .env ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"
NFT_SCRIPT="$SCRIPT_DIR/apply-nftables-rules.sh"
NFT_UNIT="$SCRIPT_DIR/../systemd/k0s-calico-nftables.service"

# 从 .env 读默认值(命令行参数优先)
if [ -f "$REPO_ROOT/.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$REPO_ROOT/.env"; set +a
fi

K="${K:-k0s kubectl}"
POD_CIDR="${K0S_POD_CIDR:-${POD_CIDR:-10.244.0.0/16}}"
CONTROLLER_IP="${K0S_CONTROLLER_IP:-${CONTROLLER_IP:-100.64.0.1}}"
WORKER_IP="${K0S_WORKER_IP:-${WORKER_IP:-}}"
SSH_USER="${K0S_CONTROLLER_SSH_USER:-root}"
# worker 列表(空格分隔, 支持多 worker); 默认取单个 WORKER_IP
WORKERS="${K0S_WORKER_IPS:-$WORKER_IP}"

echo "============================================================"
echo " k0s + Tailscale Calico 修复"
echo "   controller : $CONTROLLER_IP"
echo "   workers    : ${WORKERS:-<无>}"
echo "   pod CIDR   : $POD_CIDR"
echo "   kubectl    : $K"
echo "============================================================"

# 等待 API server 可用
echo ">>> 等待 API server 就绪..."
for i in $(seq 1 60); do
  if $K get --raw='/healthz' >/dev/null 2>&1; then echo "    API server 就绪"; break; fi
  sleep 5
  [ "$i" = 60 ] && { echo "ERROR: API server 60s 内未就绪, 先确认集群状态"; exit 1; }
done

# ---- 1. 应用 manifest: CRD + RBAC(adminnetworkpolicies / kube-controllers) ----
echo ">>> 1/5 应用 Calico CRD + RBAC manifest..."
$K apply -f "$MANIFESTS_DIR/" --server-side --force-conflicts 2>/dev/null \
  || $K apply -f "$MANIFESTS_DIR/"

# ---- 2. calico-kube-controllers: 禁用不兼容的 loadbalancer controller ----
#    (k0s 模板 v3.32 默认启用, 镜像 v3.29.3 不支持 → FATAL)
#    kubectl set env 是幂等的: 已存在则更新, 不存在则新增
echo ">>> 2/5 配置 calico-kube-controllers 环境变量..."
$K set env deploy -n kube-system calico-kube-controllers \
  ENABLED_CONTROLLERS=node,policy,profile,workloadendpoint \
  KUBERNETES_SERVICE_HOST="$CONTROLLER_IP" \
  KUBERNETES_SERVICE_PORT=6443

# ---- 3. calico-node: 显式指定 API server 地址(跨 Tailscale 确定性可达) ----
#    IP_AUTODETECTION_METHOD / FELIX_* 已由 k0sctl.yaml 的 envVars 原生持久化,
#    此处只补 KUBERNETES_SERVICE_HOST(标准注入变量, 用 set env 安全覆盖)
echo ">>> 3/5 配置 calico-node API server 地址..."
$K set env ds -n kube-system calico-node \
  KUBERNETES_SERVICE_HOST="$CONTROLLER_IP" \
  KUBERNETES_SERVICE_PORT=6443

# ---- 4. 重启 Calico pod 使新 env / RBAC 生效 ----
echo ">>> 4/5 重启 Calico 组件..."
$K delete pod -n kube-system -l k8s-app=calico-node --ignore-not-found 2>/dev/null || true
$K delete pod -n kube-system -l k8s-app=calico-kube-controllers --ignore-not-found 2>/dev/null || true

echo "    等待 calico-node 就绪(最多 90s)..."
$K rollout status ds -n kube-system calico-node --timeout=90s 2>/dev/null || \
  echo "    (calico-node rollout 未在 90s 内完成, 继续后续步骤, 稍后会自愈)"
$K rollout status deploy -n kube-system calico-kube-controllers --timeout=90s 2>/dev/null || \
  echo "    (calico-kube-controllers 未在 90s 内完成, 稍后会自愈)"

# ---- 5. 安装 nftables 持久化(systemd)并立即应用一次 ----
echo ">>> 5/5 安装 nftables 放行规则(本机 + worker)..."
install_nft_local() {
  install -m 0755 "$NFT_SCRIPT" /usr/local/sbin/apply-nftables-rules.sh
  install -m 0644 "$NFT_UNIT"  /etc/systemd/system/k0s-calico-nftables.service
  # 写入本节点 POD_CIDR(覆盖单元默认值)
  mkdir -p /etc/systemd/system/k0s-calico-nftables.service.d
  cat > /etc/systemd/system/k0s-calico-nftables.service.d/override.conf <<EOF
[Service]
Environment=POD_CIDR=$POD_CIDR
EOF
  systemctl daemon-reload
  systemctl enable k0s-calico-nftables.service 2>/dev/null || true
  POD_CIDR="$POD_CIDR" /usr/local/sbin/apply-nftables-rules.sh
}

# 本机(controller)
install_nft_local

# 每个 worker: scp 脚本与单元, 远程安装 + 立即应用
for w in $WORKERS; do
  [ -z "$w" ] && continue
  echo "    -> worker $w"
  scp -o StrictHostKeyChecking=no -q \
    "$NFT_SCRIPT" "$SSH_USER@$w:/usr/local/sbin/apply-nftables-rules.sh" 2>/dev/null \
    || { echo "    ! scp 脚本到 $w 失败, 跳过(请手动安装)"; continue; }
  scp -o StrictHostKeyChecking=no -q \
    "$NFT_UNIT" "$SSH_USER@$w:/etc/systemd/system/k0s-calico-nftables.service" 2>/dev/null \
    || { echo "    ! scp 单元到 $w 失败, 跳过"; continue; }
  ssh -o StrictHostKeyChecking=no "$SSH_USER@$w" "
    chmod 0755 /usr/local/sbin/apply-nftables-rules.sh
    mkdir -p /etc/systemd/system/k0s-calico-nftables.service.d
    printf '[Service]\nEnvironment=POD_CIDR=%s\n' '$POD_CIDR' \
      > /etc/systemd/system/k0s-calico-nftables.service.d/override.conf
    systemctl daemon-reload
    systemctl enable k0s-calico-nftables.service 2>/dev/null || true
    POD_CIDR='$POD_CIDR' /usr/local/sbin/apply-nftables-rules.sh
  " 2>/dev/null || echo "    ! worker $w 远程执行失败, 请手动检查"
done

# ---- 最终状态 ----
echo ""
echo "============================================================"
echo " 修复完成。当前状态:"
echo "============================================================"
$K get nodes
echo ""
$K get pods -A

cat <<'TIP'

>>> 跨节点 pod 通信验证(在 controller 执行):
  k0s kubectl run nettest --image=nginx --replicas=2
  k0s kubectl get pod -o wide        # 确认两个 pod 调度到不同节点
  k0s kubectl exec nettest -- ping <对端 pod IP>

>>> 若仍有 0/1 pod:
  k0s kubectl delete pod -A --field-selector=status.phase!=Running
  # 等 60s 后再查, Calico 自愈
TIP
