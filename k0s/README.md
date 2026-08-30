# k0s 集群部署(跨 Tailscale/Headscale)

在已组网的 Tailscale 节点上部署 k0s,已固化全部 overlay-over-WireGuard 网络修复。

## 前提

1. 两台(或以上)机器已接入同一个 Headscale tailnet,`tailscale0` 网卡存在
2. 部署机(controller)对全部节点有免密 SSH(`ssh root@<tailscale-ip>` 能通)
3. 每台节点已安装 k0s 二进制(`k0s version` 能跑),或允许 k0sctl 自动下载
4. 若用外部存储(kine),数据库已建好且为空;默认 etcd 可忽略

## 修复的持久化(零 hook, 全部由 k0s 原生机制自动完成)

本仓库的修复全部走 k0s 原生机制,确保节点重启、集群重装后都不丢:

| 层 | 内容 | 持久化机制 | 由谁完成 |
|----|------|-----------|---------|
| **配置层**(k0s.yaml) | Calico VXLAN、VTEP 用 tailscale0、calico-node API 直连(envVars)、kube-proxy IPVS、node-ip、镜像代理(repository) | k0s 写入节点,重启自愈 | k0sctl apply 自动写入 |
| **集群层**(k0s manifest) | `calico-tailscale-route` 特权 DaemonSet: 调和 main 表 tailnet 路由(修复 calico fwmark × tailscale 策略路由的流量漏出) | k0s 自动 apply 并持续调和;节点重启后 k0s 拉起即恢复 | k0sctl `files` 上传到 `/var/lib/k0s/manifests/` |

> 不需要 adminnetworkpolicies CRD/RBAC(k0sproject/calico-node v3.32.1-2 补丁版
> felix 对缺失 CRD 优雅降级,实测验证);不需要 nftables 放行脚本;
> 不需要 systemd 单元;不需要任何 post-apply hook。

## 部署

一条命令(含渲染、二进制保障、apply、自检):
```bash
./deploy.sh              # 全新/裸节点
./deploy.sh --reset      # 卸载旧集群(含清 kine)后全新重装
```

k0sctl apply 阶段自动完成:
1. `files` 上传路由修复 manifest 到 controller 的 `/var/lib/k0s/manifests/`
2. 安装 k0s 并按 k0s.yaml 配置 Calico VXLAN + VTEP + envVars + kube-proxy IPVS
3. DaemonSet 由 k0s 分发到所有节点,开机自动调和 tailnet 路由

## 验证

```bash
export KUBECONFIG=$PWD/kubeconfig   # deploy.sh 已生成

kubectl get nodes                       # 全部 Ready
kubectl get pods -n kube-system         # 含 calico-tailscale-route 双节点 Running

# 跨节点 pod 通信
kubectl run nettest --image=nginx --replicas=2
kubectl get pod -o wide                 # 两个 pod 在不同节点
kubectl exec nettest -- ping <对端 pod IP>
```

## 多 worker 扩展

`k0sctl.yaml` 模板默认两个节点(controller+worker 和一个 worker)。加更多 worker:
- 在 `.env` 增加该 worker 的 IP 变量
- 编辑 `render.sh` 的 k0sctl 生成段,复制 worker host 块并改 IP
- 路由修复 DaemonSet 自动覆盖新节点,无需额外操作

## 排查

见 [docs/troubleshooting.md](../docs/troubleshooting.md),覆盖 17 个已知问题的根因与定位方法。
