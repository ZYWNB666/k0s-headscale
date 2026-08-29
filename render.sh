#!/bin/bash
# =============================================================================
# 渲染入口 — 把 .env 填入模板, 生成真实配置
# =============================================================================
# 用法:
#   cp .env.example .env && vi .env     # 填入你的真实值
#   ./render.sh                         # 生成下列文件(已 .gitignore)
#     headscale/config/config.yaml
#     headscale/caddy/Caddyfile
#     k0s/k0sctl.yaml
#
# 生成的文件含真实域名/IP/口令, 不要提交。模板(.tpl)与脚本本身可安全提交。
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${1:-.env}"
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: 未找到 $ENV_FILE。请先 cp .env.example .env 并填写。"
  exit 1
fi

# 加载环境变量
set -a; . "$ENV_FILE"; set +a

# 校验必填项
need() { [ -n "${!1:-}" ] || { echo "ERROR: .env 缺少 $1"; exit 1; }; }
need HEADSCALE_DOMAIN
need HEADSCALE_PORT
need HEADSCALE_STUN_PORT
need HEADSCALE_MAGICDNS_BASE
need DERP_REGION_CODE
need DERP_REGION_NAME
need UPSTREAM_DNS_1
need UPSTREAM_DNS_2
need K0S_CLUSTER_NAME
need K0S_VERSION
need K0S_CONTROLLER_HOST
need K0S_CONTROLLER_IP
need K0S_WORKER_HOST
need K0S_WORKER_IP
need K0S_POD_CIDR
need K0S_SERVICE_CIDR
need TAILSCALE_IFACE

command -v envsubst >/dev/null 2>&1 || { echo "ERROR: 需要 envsubst (gettext-runtime)。apt install gettext-base / yum install gettext"; exit 1; }

# ----------------------------------------------------------------------------
# 1. Headscale config.yaml + Caddyfile (envsubst, 仅替换指定变量)
# ----------------------------------------------------------------------------
HEAD_VARS='${HEADSCALE_DOMAIN}:${HEADSCALE_PORT}:${HEADSCALE_STUN_PORT}:${HEADSCALE_MAGICDNS_BASE}:${DERP_REGION_CODE}:${DERP_REGION_NAME}:${UPSTREAM_DNS_1}:${UPSTREAM_DNS_2}:${HEADSCALE_IMAGE}'

echo ">>> 渲染 headscale/config/config.yaml"
envsubst "$HEAD_VARS" < headscale/config/config.yaml.tpl > headscale/config/config.yaml

echo ">>> 渲染 headscale/caddy/Caddyfile"
envsubst '$HEADSCALE_DOMAIN:$HEADSCALE_PORT' < headscale/caddy/Caddyfile.tpl > headscale/caddy/Caddyfile

# ----------------------------------------------------------------------------
# 2. k0s/k0sctl.yaml (条件逻辑: 镜像代理前缀 / 存储后端)
# ----------------------------------------------------------------------------
# 镜像代理前缀: 留空 = 直连; 填值 = 所有镜像走该代理(harbor.example.com/quay.io/...)
IMG_PREFIX=""
[ -n "${K0S_REGISTRY_PROXY:-}" ] && IMG_PREFIX="${K0S_REGISTRY_PROXY}/"

# 存储后端: 留空 = k0s 默认 etcd; 填 kine 数据源 = 外部 MySQL/Postgres
if [ -n "${K0S_KINE_DATASOURCE:-}" ]; then
  STORAGE_BLOCK="          type: kine
          kine:
            dataSource: \"${K0S_KINE_DATASOURCE}\""
else
  STORAGE_BLOCK="          type: etcd"
fi

# 拼装 images 块(用前缀变量, 留空时即为直连地址)
gen_image() { printf '          %s:\n            image: %squay.io/%s\n            version: %s\n' "$1" "$IMG_PREFIX" "$2" "$3"; }

echo ">>> 渲染 k0s/k0sctl.yaml"
cat > k0s/k0sctl.yaml <<EOF
# =============================================================================
# 由 render.sh 从 .env 生成 — 含 Tailscale/Headscale 组网全部网络修复
# 部署: k0sctl apply --config k0s/k0sctl.yaml
# 部署后还需执行一次: k0s/scripts/apply-calico-fixes.sh (处理 k0s 无法配置的项)
# =============================================================================
apiVersion: k0sctl.k0sproject.io/v1beta1
kind: Cluster
metadata:
  name: ${K0S_CLUSTER_NAME}
spec:
  hosts:
    # --- controller(+ worker), 通过 Tailscale IP 访问 ---
    - role: controller+worker
      noTaints: true
      hostname: ${K0S_CONTROLLER_HOST}
      installFlags:
        # 指定 Tailscale IP 作为 node-ip(跨地域组网必需, 否则 kubelet 选物理网卡 IP)
        - --kubelet-extra-args=--node-ip=${K0S_CONTROLLER_IP}
      ssh:
        address: ${K0S_CONTROLLER_IP}
        user: ${K0S_CONTROLLER_SSH_USER}
        port: ${K0S_CONTROLLER_SSH_PORT}
        keyPath: ${K0S_CONTROLLER_SSH_KEY}
      hooks:
        apply:
          before:
            # 升级宿主机 ipset(Calico nftables 模式的安全网; 真正生效靠 FELIX_NFTABLESMODE)
            - apt-get update -y >/dev/null 2>&1 || true
            - apt-get install -y ipset >/dev/null 2>&1 || true
          after:
            # 部署后立即应用 nft 放行规则(节点重启由 systemd 单元重应用)
            - POD_CIDR=${K0S_POD_CIDR} /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true

    # --- worker ---
    - role: worker
      hostname: ${K0S_WORKER_HOST}
      installFlags:
        - --kubelet-extra-args=--node-ip=${K0S_WORKER_IP}
      ssh:
        address: ${K0S_WORKER_IP}
        user: ${K0S_WORKER_SSH_USER}
        port: ${K0S_WORKER_SSH_PORT}
        keyPath: ${K0S_WORKER_SSH_KEY}
      hooks:
        apply:
          before:
            - apt-get update -y >/dev/null 2>&1 || true
            - apt-get install -y ipset >/dev/null 2>&1 || true
          after:
            - POD_CIDR=${K0S_POD_CIDR} /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true

  k0s:
    version: ${K0S_VERSION}
    versionChannel: stable
    dynamicConfig: false
    config:
      apiVersion: k0s.k0sproject.io/v1beta1
      kind: ClusterConfig
      metadata:
        name: ${K0S_CLUSTER_NAME}
      spec:
        api:
          # 绑定 Tailscale IP, worker 经组网访问 API server
          address: ${K0S_CONTROLLER_IP}
          externalAddress: ${K0S_CONTROLLER_IP}
          port: 6443
          k0sApiPort: 9443
          sans:
            - ${K0S_CONTROLLER_IP}
            - 127.0.0.1

        storage:
${STORAGE_BLOCK}

        network:
          # Calico VXLAN(UDP 4789) — 能穿越 Tailscale/WireGuard 隧道;
          # kube-router 的 IPIP(协议号4)会被 WireGuard 丢弃, 不可用。
          provider: calico
          podCIDR: ${K0S_POD_CIDR}
          serviceCIDR: ${K0S_SERVICE_CIDR}
          calico:
            mode: vxlan
            overlay: Always
            # 强制 Calico 用 Tailscale 网卡 IP 做 VXLAN VTEP
            # (默认自动检测会选物理网卡 IP, 跨 Tailscale 节点不可达)
            ipAutodetectionMethod: interface=${TAILSCALE_IFACE}
            envVars:
              # Felix 用 nftables 代替 ipset(容器内 ipset v7.11 与内核不兼容会 panic)
              FELIX_NFTABLESMODE: Enabled
              # 默认 DROP 会阻断 pod→host; 改 ACCEPT
              FELIX_DEFAULTENDPOINTTOHOSTACTION: ACCEPT
              # 开启健康端点, 否则 calico-node readiness 探针失败
              FELIX_HEALTHENABLED: "true"
          # kube-proxy 用 IPVS(iptables 模式下 Service 在 pod 内不通)
          kubeProxy:
            disabled: false
            mode: ipvs
            ipvs:
              scheduler: rr
              strictARP: false

        # 镜像(可选经仓库代理拉取)
        images:
$(gen_image konnectivity k0sproject/apiserver-network-proxy-agent v0.36.0-k0s.0)
$(gen_image metricsserver k0sproject/metrics-server v0.9.0-k0s.0)
$(gen_image kubeproxy k0sproject/kube-proxy v1.36.3-1)
$(gen_image coredns k0sproject/coredns 1.14.6-k0s.0)
$(gen_image pause k0sproject/pause 3.10.2-0)
          calico:
            cni:
              image: ${IMG_PREFIX}quay.io/calico/cni
              version: v3.29.3
            node:
              image: ${IMG_PREFIX}quay.io/calico/node
              version: v3.29.3
            kubecontrollers:
              image: ${IMG_PREFIX}quay.io/calico/kube-controllers
              version: v3.29.3

        telemetry:
          enabled: false

  options:
    wait:
      enabled: true
    drain:
      enabled: true
      gracePeriod: 2m
      timeout: 5m
      force: true
      ignoreDaemonSets: true
      deleteEmptyDirData: true
EOF

echo ""
echo "============================================================"
echo " 渲染完成。生成的文件:"
echo "   headscale/config/config.yaml"
echo "   headscale/caddy/Caddyfile"
echo "   k0s/k0sctl.yaml"
echo "============================================================"
echo "下一步:"
echo "  1. 部署 Headscale 控制面:  见 headscale/README.md"
echo "  2. 部署 k0s 集群:          k0sctl apply --config k0s/k0sctl.yaml"
echo "  3. 应用 Calico 修复:        bash k0s/scripts/apply-calico-fixes.sh"
