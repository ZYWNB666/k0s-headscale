# k0s over Headscale/Tailscale 异地组网部署

> 在自建 Headscale 异地组网上,一条命令部署 k0s Kubernetes 集群。
> 全部网络修复已固化进 k0s 原生配置,`k0sctl apply` 即完成,无需 apply 后执行任何脚本。

## 一、环境信息(以实际部署为例)

| 项目 | 值 |
|------|-----|
| k0s 版本 | v1.36.3+k0s.2 (Kubernetes 1.36.3) |
| k0sctl 版本 | v0.32.2 |
| controller 节点 | hs-server (100.64.0.1), Ubuntu 24.04, controller+worker |
| worker 节点 | my-nas (100.64.0.8), Debian 12, worker |
| Tailnet IP 段 | 100.64.0.0/10 (Tailscale CGNAT) |
| Tailscale 网卡 | tailscale0 |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| 存储 | 外部 MySQL (kine) 或 k0s 默认 etcd |
| 镜像代理 | Harbor (harbor.magikcloud.cn) 经 spec.images.repository 改写 |
| Calico 版本 | k0sproject/calico-node:v3.32.1-2 (k0s 自带补丁版) |

> ⚠️ **节点要求**: cgroup v2(Ubuntu 22.04+ / Debian 12+ / CentOS 8+ 升级内核),
> 两节点已接入同一个 Headscale tailnet, `tailscale0` 网卡存在。

## 二、环境准备(部署前一次性完成)

### 1. 两节点接入 Headscale 组网

```bash
# 在每台节点上:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up \
  --login-server https://<你的headscale域名>:3477 \
  --authkey <预授权密钥> \
  --accept-routes \
  --hostname <节点名>
```

验证:
```bash
tailscale status          # 两节点都在线
tailscale ping <对端 IP>  # pong = 通
ip addr show tailscale0   # 网卡存在, IP 在 100.64.0.0/10 段
```

### 2. 部署机(执行 k0sctl 的机器)到两节点免密 SSH

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
ssh-copy-id -i ~/.ssh/id_ed25519 root@100.64.0.1
ssh-copy-id -i ~/.ssh/id_ed25519 root@100.64.0.8
# 验证(无需输密码):
ssh root@100.64.0.1 'hostname'   # hs-server
ssh root@100.64.0.8 'hostname'   # MY-NAS
```

### 3. 安装 k0sctl

```bash
# 方式一: 官方脚本
curl -sSf https://get.k0s.sh | sudo sh   # 装的是 k0s, k0sctl 在 /usr/local/bin
# 方式二: 直接下载 k0sctl 二进制
# https://github.com/k0sproject/k0sctl/releases
k0sctl version   # 确认 v0.32+
```

### 4. 准备 k0s 二进制(国内必须, GitHub 直连极慢)

k0sctl 的 `useExistingK0s: true` 模式要求**每个节点已预装 k0s 二进制**,
但 `k0sctl reset` 会删掉它, 所以需要一份本地备份:

```bash
mkdir -p cache
# 从你的国内镜像源下载一次(约 250MB):
curl -fsSL https://<你的镜像源>/k0s-v1.36.3+k0s.2-amd64 -o cache/k0s
chmod +x cache/k0s
./cache/k0s version   # 确认 v1.36.3+k0s.2
```

> 也可以配置 `K0S_BINARY_URL` 让 deploy.sh 自动从该地址下载到节点,
> 或配 `K0S_USE_EXISTING_BINARY=false` 让 k0sctl 自己从 GitHub 下(国内极慢)。

### 5. (可选)准备外部 MySQL (kine)

单 controller 用 k0s 默认 etcd 即可;想用外部 MySQL:
```sql
CREATE DATABASE k0s_kine CHARACTER SET utf8mb4;
CREATE USER 'k0s'@'%' IDENTIFIED BY '<密码>';
GRANT ALL ON k0s_kine.* TO 'k0s'@'%';
```

## 三、部署(一条命令)

```bash
# 1. 填写你的真实值
cp .env.example .env && vi .env

# 2. 一键部署(渲染 + 二进制保障 + k0sctl apply + 自检)
./deploy.sh

# 重装已有集群:
./deploy.sh --reset
```

deploy.sh 自动完成:
1. **渲染** `render.sh` — 生成 k0sctl.yaml + manifest + headscale 配置
2. **二进制保障** — 逐节点确保 k0s 二进制: 节点已有 → 本地 cache/k0s (scp) → K0S_BINARY_URL → GitHub 兜底
3. **[--reset 时]** `k0sctl reset` + 清空 kine 数据库(脏数据致 worker 不就绪)
4. **k0sctl apply** — 全部网络修复在此步自动完成(见下节)
5. **自检** — nodes Ready + pods 全 1/1 + worker CNI 验证

## 四、网络问题怎么解决的(全部固化进 k0s 原生配置)

以下问题照官方文档直接部署**一定**会踩,本仓库已全部修复。
每条给出: 原因 → 官方文档为什么不行 → 本仓库怎么解决 → 配在哪里。

### 问题1: kube-router IPIP 被 Tailscale 丢弃

| | |
|---|---|
| **原因** | k0s 默认 CNI kube-router 用 IPIP(IP 协议号 4)封装 pod 流量;Tailscale(WireGuard)只转发 TCP/UDP/ICMP, IPIP 包被丢弃 |
| **官方文档** | 默认 kube-router, 在 WireGuard overlay 上跨节点 pod 完全不通 |
| **解决** | 改用 Calico VXLAN(UDP 4789 封装, 能穿越 WireGuard) |
| **配置** | `spec.network.calico.mode: vxlan` (k0sctl.yaml) |

### 问题2: kubelet 选物理网卡 IP 而非 Tailscale IP

| | |
|---|---|
| **原因** | kubelet 自动选第一个非 loopback 网卡 IP(物理网卡 192.168.x.x), 跨 Tailscale 节点访问不到 |
| **解决** | 每个 installFlags 显式指定 Tailscale IP 为 node-ip |
| **配置** | `installFlags: [--kubelet-extra-args=--node-ip=<Tailscale_IP>]` (k0sctl.yaml) |

### 问题3: Calico VTEP 自动检测到物理 IP

| | |
|---|---|
| **原因** | Calico 默认自动检测节点 IP 做 VXLAN VTEP, 选了物理网卡 IP, 跨 Tailscale 节点路由不到 |
| **解决** | 强制用 Tailscale 网卡 IP 做 VTEP |
| **配置** | `spec.network.calico.ipAutodetectionMethod: interface=tailscale0` (k0sctl.yaml) |

### 问题4: kube-proxy iptables 模式 Service 在 pod 内不通

| | |
|---|---|
| **原因** | iptables 模式下 Service DNAT 后的包走 FORWARD 链, 被 Calico "Unknown interface" DROP |
| **解决** | 切 IPVS 模式(PREROUTING 完成 DNAT) |
| **配置** | `spec.network.kubeProxy.mode: ipvs` (k0sctl.yaml) |

### 问题5: calico-node 无法连接 API server(鸡生蛋)

| | |
|---|---|
| **原因** | calico-node 是 hostNetwork 组件, 默认经 Service IP(10.96.0.1)访问 API server; 但 kube-proxy/calico 都还没就绪时 Service 不通 → felix 起不来 → 恶性循环 |
| **解决** | 给 calico-node 注入 KUBERNETES_SERVICE_HOST=<Tailscale IP>, 直连 API server, 绕开 Service 依赖。kubelet 源码(kubelet_pods.go:996)确认: pod spec 声明的 env 优先于 kubelet 自动注入的 service env, 无冲突 |
| **配置** | `spec.network.calico.envVars: {KUBERNETES_SERVICE_HOST, KUBERNETES_SERVICE_PORT}` (k0sctl.yaml) |

### 问题6: worker pod → tailnet 流量从物理网卡漏出(konnectivity agent 连不上 server)

| | |
|---|---|
| **原因** | Calico 给 pod 出向包打 `0x80000` fwmark(rpf-skip 用途);Tailscale 的策略路由规则 `fwmark 0x80000 → lookup main` 优先于其 table 52;main 表没有 tailnet(100.64.0.0/10)路由 → 命中默认路由 → 包从**物理网卡**发出 → 公网无 100.64 路由 → 蒸发。controller 因 100.64.0.1 是本机地址(rule 0 local 表)不受影响, 仅 worker 受害 |
| **现象** | worker 上 konnectivity-agent 0/1, 日志 `dial tcp 100.64.0.1:8132: i/o timeout`;worker pod 访问 Service/tailnet 全超时, 但跨节点 VXLAN pod 互 ping 正常 |
| **定位** | worker 上 `tcpdump -i any tcp port 8132` — SYN 从 enp1s0(物理)而非 tailscale0 出;`ip rule` 看到 tailscale 的 fwmark 规则 |
| **解决** | main 表补 tailnet 路由: `ip route replace 100.64.0.0/10 dev tailscale0 table main`。之后 MASQ 自动改用 tailscale0 地址作源, tailscale 认自家节点 IP |
| **配置** | `calico-tailscale-route` 特权 DaemonSet(hostNetwork + NET_ADMIN, 复用节点已有 calico-node 镜像), 每 30s 幂等调和该路由;由 k0sctl `files` 上传到 `/var/lib/k0s/manifests/`, k0s 自动 apply 并持续调和, **节点重启 k0s 拉起即恢复** (k0s/manifests/calico-tailscale-route.yaml.tpl) |

## 五、镜像怎么解决的

### 不要钉版本!(issue #8199 的教训)

之前把 Calico 镜像钉死为上游 `quay.io/calico/node:v3.29.3`,
而 k0s 的 chart 模板来自 v3.32.1 — **模板 v3.32 / 镜像 v3.29 错配**, 导致:

- calico-kube-controllers FATAL(`Invalid controller 'loadbalancer'`)
- RBAC forbidden(`serviceaccounts is forbidden`)
- felix 反复 list 不存在的 `adminnetworkpolicies` 不 ready

**k0s 自带的正确版本**(k0s 源码 pkg/constant/constant.go):

| 组件 | k0s 自带(正确) | 我们之前钉的(错误) |
|------|---------------|-------------------|
| calico/cni | `quay.io/k0sproject/calico-cni:v3.32.1-2` | `quay.io/calico/cni:v3.29.3` |
| calico/node | `quay.io/k0sproject/calico-node:v3.32.1-2` | `quay.io/calico/node:v3.29.3` |
| calico/kube-controllers | `quay.io/k0sproject/calico-kube-controllers:v3.32.1-2` | `quay.io/calico/kube-controllers:v3.29.3` |

> `-2` 后缀是 k0s 自己的补丁构建号, **不是**上游 calico 的版本。

### 正确做法: spec.images.repository 只改写 registry host

`.env` 设 `K0S_REGISTRY_PROXY=harbor.magikcloud.cn/quay.io`,
render.sh 生成 `spec.images.repository: harbor.magikcloud.cn/quay.io`。

k0s 的 `overrideRepository()`(images.go:289)只做 host 替换:
```
quay.io/k0sproject/calico-node:v3.32.1-2
  → harbor.magikcloud.cn/quay.io/k0sproject/calico-node:v3.32.1-2
```
**版本保持 k0s 自带值, 只改 registry 前缀** — 既走代理加速又不破坏版本匹配。

### adminnetworkpolicies CRD: 不需要补

k0s 自带 19 个 Calico CRD 不含 ANP 两个 CRD。
但 k0sproject/calico-node:v3.32.1-2 **补丁版 felix 对缺失 CRD 优雅降级**(实测:
删掉 ANP CRD+RBAC 后重启 calico-node, 两节点 1/1 Ready, 日志零 ANP 错误)。
issue #8199 的 ANP 症状只存在于上游 v3.29.3 镜像 — **用对自带版本就不需要补任何 CRD**。

## 六、最终验证

```bash
export KUBECONFIG=$PWD/kubeconfig   # deploy.sh 已生成

# 节点
kubectl get nodes -o wide
# 期望: 两节点 Ready, INTERNAL-IP 为 Tailscale IP(100.64.x.x)

# 组件
kubectl get pods -n kube-system
# 期望: 全部 1/1 Running, 含 calico-tailscale-route 双节点

# 跨节点 pod 通信
kubectl run nettest-a --image=<pause镜像> --overrides='{"spec":{"nodeName":"hs-server"}}'
kubectl run nettest-b --image=<pause镜像> --overrides='{"spec":{"nodeName":"my-nas"}}'
kubectl get pod -o wide
kubectl exec nettest-a -- ping <nettest-b 的 podIP>
# 期望: 0% packet loss, RTT ~10ms

# Service + DNS
kubectl exec nettest-a -- wget --no-check-certificate -q -O- https://kubernetes.default/version
# 期望: 返回 JSON(version 详情), 或 401(说明 DNS+IPVS+API 都通, 401 是鉴权正确)

# tailnet 路由(DaemonSet 是否生效)
ssh root@100.64.0.8 'ip route show table main | grep 100.64'
# 期望: 100.64.0.0/10 dev tailscale0

# 清理测试 pod
kubectl delete pod nettest-a nettest-b --force --grace-period=0
```

## 七、日常运维

```bash
# 集群状态
kubectl get nodes
kubectl get pods -A

# 重装
./deploy.sh --reset

# 查看路由 DaemonSet
kubectl get ds -n kube-system calico-tailscale-route
kubectl logs -n kube-system -l app.kubernetes.io/name=calico-tailscale-route --tail=3

# SSH 到节点
ssh root@100.64.0.1   # controller
ssh root@100.64.0.8   # worker

# node 上的 k0s 日志
journalctl -u k0scontroller -f   # controller
journalctl -u k0sworker -f       # worker
```

## 八、仓库结构

```
.env.example              # 唯一需要改的地方(域名/IP/CIDR/存储/镜像代理)
.env                      # 你的真实值(已 gitignore)
deploy.sh                 # 一键部署(渲染+二进制保障+apply+自检)
render.sh                 # .env → k0sctl.yaml + manifest + headscale 配置
cache/k0s                 # k0s 二进制备份(已 gitignore, deploy.sh 用于 scp 推送)
k0s/
  k0sctl.yaml             # 由 render.sh 生成(已 gitignore)
  manifests/
    calico-tailscale-route.yaml.tpl   # tailnet 路由 DaemonSet 模板
    calico-tailscale-route.yaml       # 渲染产物(已 gitignore)
headscale/                # 自建 Tailscale 控制面(见 headscale/README.md)
scripts/validate-render.py  # 渲染逻辑校验
docs/troubleshooting.md   # 全部问题的根因与排查(排障用)
```

## 九、排障

见 [docs/troubleshooting.md](docs/troubleshooting.md), 覆盖全部已知问题的
现象 → 根因 → 定位命令 → 修复。
