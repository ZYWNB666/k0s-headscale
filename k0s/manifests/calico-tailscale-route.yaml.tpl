# =============================================================================
# calico × tailscale 路由修复 — 特权 DaemonSet(k0s manifest, 自动分发到所有节点)
# =============================================================================
# 问题: calico 给 pod 出向包打 0x80000 fwmark(rpf-skip 用), 而 tailscale 的
# 策略路由规则 "fwmark 0x80000 → lookup main" 优先于其 table 52; main 表缺
# tailnet(100.64.0.0/10)路由时, pod→tailnet 流量命中默认路由从物理网卡漏出,
# 导致 worker 上 konnectivity agent 连不上 server、pod 访问 tailnet 地址全超时。
#
# 机制: hostNetwork 容器内 `ip route replace 100.64.0.0/10 dev tailscale0 table main`,
# 每 30s 幂等调和一次 —— 节点重启后 k0s 拉起本 DaemonSet 即自动恢复, 无需 systemd/脚本。
#
# 说明: 本文件是模板, 由 render.sh 渲染(镜像地址跟随 .env 的 K0S_REGISTRY_PROXY);
# 渲染产物经 k0sctl files 上传到 /var/lib/k0s/manifests/, k0s 自动 apply 并持续调和。
# =============================================================================
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: calico-tailscale-route
  namespace: kube-system
  labels:
    app.kubernetes.io/name: calico-tailscale-route
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: calico-tailscale-route
  template:
    metadata:
      labels:
        app.kubernetes.io/name: calico-tailscale-route
    spec:
      hostNetwork: true          # 直接处于宿主网络命名空间, 不依赖 CNI
      dnsPolicy: ClusterFirstWithHostNet
      nodeSelector:
        kubernetes.io/os: linux
      tolerations:
        - operator: Exists
      containers:
        - name: route-fix
          # 复用 calico-node 镜像(calico-node 先于本 DS 拉取过, IfNotPresent 零开销)
          image: ${CALICO_NODE_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]
          command:
            - /bin/sh
            - -c
            - |
              while true; do
                if ip link show tailscale0 >/dev/null 2>&1; then
                  if ip route replace 100.64.0.0/10 dev tailscale0 table main 2>/dev/null; then
                    echo "$(date -Is) route ok: 100.64.0.0/10 dev tailscale0 (main)"
                  else
                    echo "$(date -Is) WARN: ip route replace failed"
                  fi
                else
                  echo "$(date -Is) tailscale0 not present yet"
                fi
                sleep 30
              done
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
