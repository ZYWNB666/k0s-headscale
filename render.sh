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
# 修复的持久化三层(全部由 k0sctl apply 自动完成, 无需手动跑脚本):
#   1. 配置层(k0s.yaml): Calico VXLAN/VTEP/Felix/kube-proxy/node-ip — k0s 写入节点, 重启自愈
#   2. 集群层(manifest): CRD/RBAC — 经 files 上传到 /var/lib/k0s/manifests/, k0s 自动 apply
#   3. 节点层(systemd): nft 规则 — 经 files 上传脚本+单元, apply.after hook 启用, 开机自愈
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
        # adminnetworkpolicies CRD + RBAC → k0s 自动 apply(集群级持久)
        # (k0s 自带的 19 个 Calico CRD 缺这两个, v3.32 felix 会 watch)
        - src: manifests/00-adminnetworkpolicies-crd.yaml
          dstDir: /var/lib/k0s/manifests/calico-fixes
          perm: "0644"
        - src: manifests/01-calico-admin-network-policies-rbac.yaml
          dstDir: /var/lib/k0s/manifests/calico-fixes
          perm: "0644"
        # nftables 放行规则脚本 + systemd 单元(节点级持久)
        - src: scripts/apply-nftables-rules.sh
          dstDir: /usr/local/sbin
          perm: "0755"
        - src: systemd/k0s-calico-nftables.service
          dstDir: /etc/systemd/system
          perm: "0644"
      hooks:
        apply:
          before:
            # 升级宿主机 ipset(Calico iptables 模式的安全网)
            # 注: k0s 二进制的保障在 deploy.sh 的 preflight 完成 —— k0sctl 对
            # useExistingK0s 的校验发生在其内部 hook 之前, 不能靠 hook 补
            - apt-get update -y >/dev/null 2>&1 || true
            - apt-get install -y ipset >/dev/null 2>&1 || true
          after:
            # 注册 nft 规则为开机自启服务(节点重启自愈)
            - mkdir -p /etc/systemd/system/k0s-calico-nftables.service.d
            - printf '[Service]\\nEnvironment=POD_CIDR=${K0S_POD_CIDR}\\n' > /etc/systemd/system/k0s-calico-nftables.service.d/override.conf
            - systemctl daemon-reload
            - systemctl enable k0s-calico-nftables.service
            # 清陈旧 nft 表 + INPUT/FORWARD 放行 + main 表 tailnet 路由(脚本内部等待链出现, 最多 180s)
            - POD_CIDR=${K0S_POD_CIDR} WAIT_SECS=180 /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true
            # calico-node 直连 API server(绕开 Service IP 依赖, hostNetwork 组件确定性可达);
            # 带 5 分钟重试: 等 apiserver 与 calico 资源出现(幂等, set env 已存在则更新)
            - for i in \$(seq 1 60); do k0s kubectl set env ds -n kube-system calico-node KUBERNETES_SERVICE_HOST=${K0S_CONTROLLER_IP} KUBERNETES_SERVICE_PORT=6443 >/dev/null 2>&1 && break; sleep 5; done
            - for i in \$(seq 1 60); do k0s kubectl set env deploy -n kube-system calico-kube-controllers KUBERNETES_SERVICE_HOST=${K0S_CONTROLLER_IP} KUBERNETES_SERVICE_PORT=6443 >/dev/null 2>&1 && break; sleep 5; done
            # 终局收敛: 等 kube-system 全部 Ready(最多 4 分钟);
            # 超时则删除 calico-node / konnectivity-agent 让其在健康网络下重建
            # (agent 曾在网络未通时启动会僵死不重试), 再等 3 分钟。
            # 注意: k0sctl 对 hook 做 os.ExpandEnv, 美元符号变量会被吃掉 — 此处禁止使用 shell 变量
            - k0s kubectl wait pod -n kube-system --all --for=condition=Ready --timeout=240s >/dev/null 2>&1 || { sleep 5; k0s kubectl delete pod -n kube-system -l k8s-app=calico-node --ignore-not-found >/dev/null 2>&1; k0s kubectl delete pod -n kube-system -l k8s-app=konnectivity-agent --ignore-not-found >/dev/null 2>&1; k0s kubectl wait pod -n kube-system --all --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true; }

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
      files:
        # worker 不需要 manifest(只在 controller apply), 但需要 nft 规则
        - src: scripts/apply-nftables-rules.sh
          dstDir: /usr/local/sbin
          perm: "0755"
        - src: systemd/k0s-calico-nftables.service
          dstDir: /etc/systemd/system
          perm: "0644"
      hooks:
        apply:
          before:
            - apt-get update -y >/dev/null 2>&1 || true
            - apt-get install -y ipset >/dev/null 2>&1 || true
          after:
            - mkdir -p /etc/systemd/system/k0s-calico-nftables.service.d
            - printf '[Service]\\nEnvironment=POD_CIDR=${K0S_POD_CIDR}\\n' > /etc/systemd/system/k0s-calico-nftables.service.d/override.conf
            - systemctl daemon-reload
            - systemctl enable k0s-calico-nftables.service
            # 清陈旧 nft 表 + 放行规则 + tailnet 路由(等待 Calico 链出现, 最多 180s)
            - POD_CIDR=${K0S_POD_CIDR} WAIT_SECS=180 /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true

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
echo "============================================================"
echo "下一步:"
echo "  1. 部署 Headscale 控制面:  见 headscale/README.md"
echo "  2. 部署 k0s 集群(一键):     k0sctl apply --config k0s/k0sctl.yaml"
echo "     (所有网络修复由 k0sctl 自动完成, 无需手动跑脚本)"
echo "  3. 排障(可选):              bash k0s/scripts/apply-calico-fixes.sh"
