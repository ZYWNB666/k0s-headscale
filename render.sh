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
need K0S_USE_EXISTING_BINARY
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

# calico-node 镜像(repository 机制: 代理已配时 host 改写为 <代理>, 版本保持 k0s 默认)
if [ -n "${K0S_REGISTRY_PROXY:-}" ]; then
  CALICO_NODE_IMAGE="${K0S_REGISTRY_PROXY}/k0sproject/calico-node:v3.32.1-2"
else
  CALICO_NODE_IMAGE="quay.io/k0sproject/calico-node:v3.32.1-2"
fi
export CALICO_NODE_IMAGE
echo ">>> 渲染 k0s/manifests/calico-tailscale-route.yaml (image=${CALICO_NODE_IMAGE})"
envsubst '$CALICO_NODE_IMAGE' < k0s/manifests/calico-tailscale-route.yaml.tpl > k0s/manifests/calico-tailscale-route.yaml

# ----------------------------------------------------------------------------
# 2. k0s/k0sctl.yaml (条件逻辑: 存储后端)
# ----------------------------------------------------------------------------
# 存储后端: 留空 = k0s 默认 etcd; 填 kine 数据源 = 外部 MySQL/Postgres
if [ -n "${K0S_KINE_DATASOURCE:-}" ]; then
  STORAGE_BLOCK="          type: kine
          kine:
            dataSource: \"${K0S_KINE_DATASOURCE}\""
else
  STORAGE_BLOCK="          type: etcd"
fi

# 镜像仓库代理: 只改写 registry host, 版本仍用 k0s 自带的正确版本
# (spec.images.repository — 见 k0s images.go overrideRepository, issue #8199 的教训:
#  不要手动钉镜像版本, 钉错会造成模板/镜像错配)
if [ -n "${K0S_REGISTRY_PROXY:-}" ]; then
  IMAGES_BLOCK="        images:
          # 只改写 registry host: quay.io/xxx → <代理>/xxx, 版本保持 k0s 默认
          # 路径式代理填 harbor.example.com/quay.io; 域名式填 quay.harbor.example.com
          repository: ${K0S_REGISTRY_PROXY}"
else
  IMAGES_BLOCK="        # 不指定 images/repository — 用 k0s 自带的正确镜像版本(v3.32.1-2 等)"
fi

echo ">>> 渲染 k0s/k0sctl.yaml"
cat > k0s/k0sctl.yaml <<EOF
# =============================================================================
# 由 render.sh 从 .env 生成 — 含 Tailscale/Headscale 组网全部网络修复
# 部署只需一条命令: k0sctl apply --config k0s/k0sctl.yaml
#
# 修复的持久化(全部由 k0sctl apply 自动完成, 零 hook、零手动脚本):
#   1. 配置层(k0s.yaml): Calico VXLAN/VTEP/envVars(API直连)/kube-proxy IPVS/node-ip
#   2. 集群层(manifest): calico-tailscale-route DaemonSet — k0s 自动 apply 并持续调和,
#      节点重启后 k0s 拉起即自动恢复(修复 pod→tailnet 的 fwmark 策略路由泄漏)
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
      useExistingK0s: ${K0S_USE_EXISTING_BINARY}
      installFlags:
        # 指定 Tailscale IP 作为 node-ip(跨地域组网必需, 否则 kubelet 选物理网卡 IP)
        - --kubelet-extra-args=--node-ip=${K0S_CONTROLLER_IP}
      ssh:
        address: ${K0S_CONTROLLER_IP}
        user: ${K0S_CONTROLLER_SSH_USER}
        port: ${K0S_CONTROLLER_SSH_PORT}
        keyPath: ${K0S_CONTROLLER_SSH_KEY}
      # 上传文件到 controller(k0sctl 在 apply 阶段自动 scp)
      files:
        # tailnet 路由修复 → k0s manifest(特权 DaemonSet, k0s 自动 apply, 开机自愈)
        # 作用: calico 给 pod 出向包打 0x80000 fwmark, tailscale 策略路由令其查
        # main 表, main 表缺 tailnet 路由会导致 pod→tailnet 流量从物理网卡漏出
        - src: manifests/calico-tailscale-route.yaml
          dstDir: /var/lib/k0s/manifests/calico-tailscale
          perm: "0644"
      # 无任何 hooks — 全部修复走 k0s 原生机制:
      #   配置层: calico(vxlan/VTEP/envVars) + kubeProxy(ipvs) + node-ip(见上方)
      #   集群层: k0s manifest 目录自动 apply(DaemonSet 路由修复)
      # 注: k0sproject/calico-node:v3.32.1-2 不需要 adminnetworkpolicies CRD
      #     (k0s 补丁版 felix 对缺失 CRD 优雅降级), 勿再补 CRD/RBAC manifest

    # --- worker ---
    - role: worker
      hostname: ${K0S_WORKER_HOST}
      useExistingK0s: ${K0S_USE_EXISTING_BINARY}
      installFlags:
        - --kubelet-extra-args=--node-ip=${K0S_WORKER_IP}
      ssh:
        address: ${K0S_WORKER_IP}
        user: ${K0S_WORKER_SSH_USER}
        port: ${K0S_WORKER_SSH_PORT}
        keyPath: ${K0S_WORKER_SSH_KEY}
      # worker 无 files/manifest — 路由修复 DaemonSet 由 controller 侧 manifest
      # 经 DaemonSet 控制器自动分发到所有节点, 无需向 worker 上传任何东西

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
              # calico-node(hostNetwork) 直连 API server, 不经 Service IP/IPVS,
              # 避免 kube-proxy 未就绪时的鸡生蛋依赖。
              # kubelet 仅在 pod spec 未声明时才注入同名 service env(kubelet_pods.go
              # "Append remaining service env vars"), 此处声明即优先生效, 无重复。
              KUBERNETES_SERVICE_HOST: ${K0S_CONTROLLER_IP}
              KUBERNETES_SERVICE_PORT: "6443"
            # 注意: 不要设置 FELIX_NFTABLESMODE=Enabled!
            # k0sproject/calico-node 镜像内无 nft 二进制, felix 会 panic 死循环(table.go 411)。
            # v3.32.1-2 默认 iptables+ipset 模式工作正常(容器内 ipset 已是新版,
            # 老笔记的 ipset panic 是 v3.29.3 时代的问题)。
            # FELIX_DEFAULTENDPOINTTOHOSTACTION/FELIX_HEALTHENABLED 模板已内置正确值, 无需设置。
          # kube-proxy 用 IPVS(iptables 模式下 Service 在 pod 内不通)
          kubeProxy:
            disabled: false
            mode: ipvs
            ipvs:
              scheduler: rr
              strictARP: false

${IMAGES_BLOCK}

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
echo "   k0s/manifests/calico-tailscale-route.yaml"
echo "============================================================"
echo "下一步:"
echo "  1. 部署 Headscale 控制面:  见 headscale/README.md"
echo "  2. 一键部署 k0s 集群:       ./deploy.sh        (全新/裸节点)"
echo "                             ./deploy.sh --reset (重装已有集群)"
