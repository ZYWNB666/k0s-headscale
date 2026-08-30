#!/bin/bash
# =============================================================================
# 一键部署 — preflight(二进制保障) + k0sctl apply + kubeconfig + 部署后自检
# =============================================================================
# 用法:
#   cp .env.example .env && vi .env     # 填一次
#   ./deploy.sh                          # 全新/裸节点安装
#   ./deploy.sh --reset                  # 卸载旧集群后全新重装(reset + 清 kine)
#
# 流程:
#   1. [--reset] 卸载旧集群(k0sctl reset)
#   2. 清空 kine 数据库(配置了外部存储时; 脏数据会导致 worker 无法就绪)
#   3. 渲染配置(render.sh, 幂等)
#   4. preflight: 逐节点确保 k0s 二进制存在(多级回退: 节点已有 → 本地 cache/k0s
#      → K0S_BINARY_URL → GitHub 官方源)
#   5. k0sctl apply —— 所有网络修复由 files+hooks 自动完成
#   6. 导出 kubeconfig + 最终健康检查(nodes / pods 全 Ready + worker CNI 验证)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# --reset: 先卸载旧集群(含 k0s 二进制)再全新安装; 不带参数 = 仅在裸节点上安装
DO_RESET=0
[ "${1:-}" = "--reset" ] && DO_RESET=1

[ -f .env ] || { echo "ERROR: 缺少 .env — 先 cp .env.example .env 并填写"; exit 1; }
set -a; . .env; set +a

# ---- 0. (可选)卸载旧集群 ----
if [ "$DO_RESET" = "1" ] && [ -f k0s/k0sctl.yaml ]; then
  echo ">>> --reset: 卸载旧集群..."
  k0sctl reset --config k0s/k0sctl.yaml --force || echo "  (reset 报错继续 — 节点可能已是裸机)"
fi

# ---- 0.5 [--reset 时] 清空 kine 数据库 ----
# 仅在 --reset(全新重装)时清理: 脏 kine 数据会导致 worker 无法就绪;
# 不带 --reset 对在跑集群重执行时严禁清库(会毁掉在线集群状态)
wipe_kine() {
  [ -n "${K0S_KINE_DATASOURCE:-}" ] || return 0
  if [ "${K0S_WIPE_KINE:-true}" != "true" ]; then
    echo ">>> kine 清理已跳过(K0S_WIPE_KINE=false)"
    return 0
  fi
  local creds
  creds=$(echo "$K0S_KINE_DATASOURCE" | sed -E 's|^mysql://([^:]+):([^@]+)@tcp\(([^:]+):([0-9]+)\)/(.+)$|\1 \2 \3 \4 \5|')
  if [ "$creds" = "$K0S_KINE_DATASOURCE" ]; then
    echo "WARN: 无法解析 K0S_KINE_DATASOURCE(仅支持 mysql:// 格式), 跳过 kine 清理"
    return 0
  fi
  local u p h pt db
  read -r u p h pt db <<< "$creds"
  echo ">>> 清空 kine 数据库 ${db} @ ${h}:${pt} ..."
  if command -v mysql >/dev/null 2>&1; then
    MYSQL_PWD="$p" mysql -h "$h" -P "$pt" -u"$u" \
      -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\` CHARACTER SET utf8mb4;"
  else
    echo "WARN: 本机无 mysql 客户端, 跳过 — 部署若失败请手动清库后重试"
  fi
}
[ "$DO_RESET" = "1" ] && wipe_kine || true

# ---- 1. 渲染(幂等; .env 更新过或产物缺失才重渲染) ----
if [ ! -f k0s/k0sctl.yaml ] || [ .env -nt k0s/k0sctl.yaml ]; then
  ./render.sh
fi

# ---- 2. preflight: 逐节点 k0s 二进制保障(多级回退) ----
#   ① 节点已有  ② 本地 cache/k0s(scp 推送)  ③ K0S_BINARY_URL  ④ GitHub 官方源
# $1=IP $2=节点名 $3=SSH用户 $4=SSH端口 $5=SSH私钥
preflight() {
  local ip="$1" name="$2" user="$3" port="$4" key="$5"
  echo ">>> preflight ${name}(${ip}) ..."
  local key_expanded="${key/#\~/$HOME}"
  local ssh_opts=(-o ConnectTimeout=15 -o StrictHostKeyChecking=no -p "$port" -i "$key_expanded")
  local scp_opts=(-o ConnectTimeout=15 -o StrictHostKeyChecking=no -P "$port" -i "$key_expanded")

  if ssh "${ssh_opts[@]}" "${user}@${ip}" '[ -x /usr/local/bin/k0s ]'; then
    echo "    节点已有 k0s 二进制 — OK"
    return 0
  fi

  if [ -f "$ROOT/cache/k0s" ]; then
    echo "    推送本地 cache/k0s ..."
    scp -q "${scp_opts[@]}" "$ROOT/cache/k0s" "${user}@${ip}:/usr/local/bin/k0s"
    ssh "${ssh_opts[@]}" "${user}@${ip}" 'chmod +x /usr/local/bin/k0s'
  elif [ -n "${K0S_BINARY_URL}" ]; then
    echo "    从 K0S_BINARY_URL 下载(约 250MB, 请耐心)..."
    ssh "${ssh_opts[@]}" "${user}@${ip}" "curl -fsSL --retry 3 '${K0S_BINARY_URL}' -o /usr/local/bin/k0s && chmod +x /usr/local/bin/k0s"
  else
    # 最后回退: GitHub 官方 release(国内慢, 仅兜底; + 需 URL 编码为 %2B)
    local tag="v${K0S_VERSION/+/%2B}"
    echo "    从 GitHub release 下载(兜底, 可能很慢)..."
    ssh "${ssh_opts[@]}" "${user}@${ip}" "curl -fsSL --retry 3 'https://github.com/k0sproject/k0s/releases/download/${tag}/k0s-${tag}-amd64' -o /usr/local/bin/k0s && chmod +x /usr/local/bin/k0s"
  fi

  ssh "${ssh_opts[@]}" "${user}@${ip}" 'k0s version' && echo "    OK"
}

echo "============================================================"
echo " k0s over Tailscale 一键部署"
echo "   controller : ${K0S_CONTROLLER_IP} (${K0S_CONTROLLER_HOST})"
echo "   worker     : ${K0S_WORKER_IP} (${K0S_WORKER_HOST})"
echo "============================================================"

preflight "${K0S_CONTROLLER_IP}" "${K0S_CONTROLLER_HOST}" \
          "${K0S_CONTROLLER_SSH_USER}" "${K0S_CONTROLLER_SSH_PORT}" "${K0S_CONTROLLER_SSH_KEY}"
preflight "${K0S_WORKER_IP}" "${K0S_WORKER_HOST}" \
          "${K0S_WORKER_SSH_USER}" "${K0S_WORKER_SSH_PORT}" "${K0S_WORKER_SSH_KEY}"

# ---- 3. apply(所有修复由 files + hooks 自动完成) ----
k0sctl apply --config k0s/k0sctl.yaml

# ---- 4. kubeconfig + 最终健康检查 ----
k0sctl kubeconfig --config k0s/k0sctl.yaml > kubeconfig
chmod 600 kubeconfig
export KUBECONFIG="$ROOT/kubeconfig"

echo ""
echo "============================================================"
echo " 部署后自检"
echo "============================================================"
FAIL=0

echo "--- 节点 ---"
kubectl get nodes
N_NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{c++} END{print c+0}')
[ "$N_NOTREADY" = "0" ] || { echo "!! 有节点未 Ready"; FAIL=1; }

echo "--- kube-system pods ---"
kubectl get pods -n kube-system
N_NOTREADY=$(kubectl get pods -n kube-system --no-headers | awk '{split($2,a,"/"); if ($2!="Completed" && a[1]!=a[2]) c++} END{print c+0}')
[ "$N_NOTREADY" = "0" ] || { echo "!! 有 pod 未 Ready"; FAIL=1; }

echo "--- worker CNI 验证(在 ${K0S_WORKER_HOST} 起一个 pause pod) ---"
# 先等 calico-node rollout 结束(env 注入会触发一轮滚动, 立即测会有竞争)
kubectl rollout status ds -n kube-system calico-node --timeout=300s >/dev/null 2>&1 || true
# pause 镜像与 k0s 自带版本一致; 代理已配时经代理拉取(repository 机制已含 /quay.io 路径)
if [ -n "${K0S_REGISTRY_PROXY:-}" ]; then
  PAUSE_IMAGE="${K0S_REGISTRY_PROXY}/k0sproject/pause:3.10.2-0"
else
  PAUSE_IMAGE="quay.io/k0sproject/pause:3.10.2-0"
fi
NETTEST_OK=0
for try in 1 2 3; do
  kubectl delete pod nettest -n default --force --grace-period=0 >/dev/null 2>&1 || true
  kubectl run nettest -n default --image="$PAUSE_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"${K0S_WORKER_HOST}\"}}" >/dev/null 2>&1 || true
  if kubectl wait pod nettest -n default --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    POD_IP=$(kubectl get pod nettest -n default -o jsonpath='{.status.podIP}')
    echo "  nettest Ready @${K0S_WORKER_HOST}, podIP=${POD_IP} — CNI 正常(第 ${try} 次尝试)"
    kubectl delete pod nettest -n default --force --grace-period=0 >/dev/null 2>&1 || true
    NETTEST_OK=1
    break
  fi
done
kubectl delete pod nettest -n default --force --grace-period=0 >/dev/null 2>&1 || true
[ "$NETTEST_OK" = "1" ] || { echo "!! nettest 未 Ready(worker CNI 异常)"; FAIL=1; }

if [ "$FAIL" = "0" ]; then
  echo ""
  echo "============================================================"
  echo " 部署成功 — 集群健康"
  echo "   kubeconfig : $ROOT/kubeconfig"
  echo "   使用: export KUBECONFIG=$ROOT/kubeconfig"
  echo "============================================================"
else
  echo ""
  echo "!! 部署完成但有组件未就绪, 按 docs/troubleshooting.md 排查"
  exit 1
fi
