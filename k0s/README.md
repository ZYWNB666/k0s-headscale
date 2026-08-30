# k0s 集群部署(跨 Tailscale/Headscale)

在已组网的 Tailscale 节点上部署 k0s,已固化全部 overlay-over-WireGuard 网络修复。

## 前提

1. 两台(或以上)机器已接入同一个 Headscale tailnet,`tailscale0` 网卡存在
2. 部署机(controller)对全部节点有免密 SSH(`ssh root@<tailscale-ip>` 能通)
3. 每台节点已安装 k0s 二进制(`k0s version` 能跑),或允许 k0sctl 自动下载
4. 若用外部存储(kine),数据库已建好且为空;默认 etcd 可忽略

## 修复的三层持久化(全部由 k0sctl apply 自动完成)

本仓库的修复分布在三层,确保节点重启、集群重装后都不丢:

| 层 | 内容 | 持久化机制 | 由谁完成 |
|----|------|-----------|---------|
| **配置层**(k0s.yaml) | Calico VXLAN、VTEP 用 tailscale0、Felix nftables/放行/健康、kube-proxy IPVS、node-ip、镜像代理 | k0s 写入节点,重启自愈 | k0sctl apply 自动写入 |
| **集群层**(manifest) | adminnetworkpolicies CRD + RBAC、calico-kube-controllers 完整 RBAC | 存于 etcd/kine,永久 | k0sctl `files` 上传到 `/var/lib/k0s/manifests/`,k0s 自动 apply |
| **节点层**(systemd) | nftables INPUT/FORWARD 放行规则 | `k0s-calico-nftables.service` 开机重应用 | k0sctl `files` 上传脚本+单元,`apply.after` hook 启用 |
| **运行时**(kubectl) | 禁用 calico-kube-controllers loadbalancer | 环境变量 | k0sctl `apply.after` hook `kubectl set env` |

> 以上全部在 `k0sctl apply` 一条命令内自动完成,**无需手动跑任何脚本**。

## 部署步骤

### 1. 生成配置

在仓库根目录:
```bash
cp .env.example .env && vi .env      # 填节点 IP/CIDR/存储/镜像代理等
./render.sh                          # 生成 k0s/k0sctl.yaml
```

### 2. 一键部署集群

```bash
k0sctl apply --config k0s/k0sctl.yaml
```

k0sctl 会自动完成全部工作:
1. 在每个节点装 k0s,按 `installFlags` 设 Tailscale IP 为 node-ip
2. `apply.before` hook 装 ipset
3. 按 k0s.yaml 配置 Calico VXLAN + Felix envVars + kube-proxy IPVS,拉起控制面
4. `files` 上传 manifest 到 controller 的 `/var/lib/k0s/manifests/`(k0s 自动 apply CRD/RBAC)
5. `files` 上传 nft 脚本 + systemd 单元到所有节点
6. `apply.after` hook:启用 nft systemd 服务、首次应用 nft 规则、禁用 loadbalancer controller

### 3. 验证

```bash
k0sctl kubeconfig --config k0s/k0sctl.yaml > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

kubectl get nodes                       # 全部 Ready
kubectl get pods -n kube-system         # calico-node / calico-kube-controllers Running

# 跨节点 pod 通信
kubectl run nettest --image=nginx --replicas=2
kubectl get pod -o wide                 # 两个 pod 在不同节点
kubectl exec nettest -- ping <对端 pod IP>
```

## 重装/重置流程

```bash
k0sctl reset --config k0s/k0sctl.yaml --force
# 若用 kine: 清空数据库  (mysql: DROP DATABASE k0s_kine; CREATE DATABASE k0s_kine;)
k0sctl apply --config k0s/k0sctl.yaml    # 重新一键部署,所有修复自动重做
```

> 如果 `k0sctl apply` 中途因网络等原因失败(hook 没跑到),可手动补救一次:
> `bash k0s/scripts/apply-calico-fixes.sh`(幂等,可安全重复执行)。

## 多 worker 扩展

`k0sctl.yaml` 模板默认两个节点(controller+worker 和一个 worker)。加更多 worker:
- 在 `.env` 增加该 worker 的 IP 变量
- 编辑 `render.sh` 的 k0sctl 生成段,复制 worker host 块并改 IP
- `apply-calico-fixes.sh` 会自动 SSH 到 `.env` 里列出的所有 worker 安装 nft 规则
  (设 `K0S_WORKER_IPS="ip1 ip2 ip3"` 空格分隔多 worker)

## 排查

见 [docs/troubleshooting.md](../docs/troubleshooting.md),覆盖 17 个已知问题的根因与定位方法。
