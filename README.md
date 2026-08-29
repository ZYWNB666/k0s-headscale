# k0s-headscale

> 在 **Headscale 异地组网**(自建 Tailscale 控制面)上开箱即用地部署 **k0s** Kubernetes 集群,
> 已固化所有 overlay-over-WireGuard 环境下的网络修复。

## 为什么需要这个项目

直接照 k0s 官方文档部署到 Headscale/Tailscale 网络上**一定**会踩坑,因为 k0s 的默认配置
假设节点在同一二层网络或通过 BGP/原生路由互通。一旦 pod 流量要穿越 WireGuard 隧道,
以下默认行为全部失效:

| 默认行为 | 为什么在 Tailscale 上坏 | 本项目的修复 |
|---------|------------------------|-------------|
| kube-router 用 IPIP(协议号 4)封装 | WireGuard 只转发 TCP/UDP/ICMP,IPIP 包被丢弃 | 改用 **Calico VXLAN**(UDP 4789) |
| kubelet 自动选物理网卡 IP 做 node-ip | 跨 Tailscale 节点不可达 | `installFlags` 显式指定 Tailscale IP |
| Calico 自动检测物理 IP 做 VTEP | 跨 Tailscale 节点不可达 | `calico.ipAutodetectionMethod: interface=tailscale0` |
| Felix 用 ipset | 容器内 ipset v7.11 与内核 revision 不兼容,panic | `FELIX_NFTABLESMODE=Enabled` 切 nftables |
| Felix 默认 DROP pod→host | 正常管理流量被阻断 | `FELIX_DEFAULTENDPOINTTOHOSTACTION=ACCEPT` |
| kube-proxy iptables 模式 | Service DNAT 后包走 FORWARD 被 Calico DROP | `kubeProxy.mode: ipvs` |
| k0s v1.36 Calico 版本错配(模板 v3.32 / 镜像 v3.29) | adminnetworkpolicies CRD 缺失、kube-controllers RBAC 不全、loadbalancer controller 不兼容 | manifest 补 CRD/RBAC + `kubectl set env` 禁用 loadbalancer |
| nftables INPUT/FORWARD 默认 DROP | pod→Service 和跨节点 pod 流量被丢 | systemd 单元开机自动重应用放行规则 |

这些修复散落在 k0sctl.yaml(原生持久)、manifest(集群级持久)和 systemd(节点级持久)
三层,本仓库把它们整合成一次可重复的部署流程。

## 仓库结构

```
.
├── .env.example              # 所有可配置项(域名/IP/CIDR/存储/镜像代理),唯一需要你改的地方
├── render.sh                 # 把 .env 渲染成真实配置(config.yaml/Caddyfile/k0sctl.yaml)
├── headscale/                # 自建 Tailscale 控制面
│   ├── docker-compose.yaml   # Caddy(TLS) + Headscale(HTTP/STUN/DERP),host network
│   ├── config/
│   │   ├── config.yaml.tpl   # Headscale 配置模板
│   │   ├── acl.hujson        # ACL(默认全通;含细化模板 acl-detailed.hujson)
│   │   └── acl-detailed.hujson
│   ├── caddy/Caddyfile.tpl   # Caddy 反代模板(单端口分流 /web 和 /api)
│   └── README.md             # 控制面部署步骤
├── k0s/                      # k0s 集群
│   ├── k0sctl.yaml           # 由 render.sh 生成(已 gitignore)
│   ├── manifests/            # Calico CRD/RBAC 补丁(集群级持久)
│   │   ├── 00-adminnetworkpolicies-crd.yaml
│   │   ├── 01-calico-admin-network-policies-rbac.yaml
│   │   └── 02-calico-kube-controllers-rbac.yaml
│   ├── scripts/
│   │   ├── apply-calico-fixes.sh    # 部署后修复(幂等,可重复执行)
│   │   └── apply-nftables-rules.sh  # nft 放行规则(幂等)
│   ├── systemd/
│   │   └── k0s-calico-nftables.service  # 开机自动重应用 nft 规则
│   └── README.md             # 集群部署步骤
├── scripts/
│   └── validate-render.py    # 校验渲染逻辑与 YAML 合法性
└── docs/
    └── troubleshooting.md    # 17 个问题的根因与排查
```

## 快速开始

### 前提
- 至少 2 台 Linux 机器(controller + worker),已接入同一个 Headscale tailnet
- 两台都已安装 Tailscale 客户端并 `tailscale up` 成功,`tailscale0` 网卡存在
- 一个域名(指向控制面机器的公网 IP)+ TLS 证书
- 部署机(controller)有到所有节点的免密 SSH

### 三步部署
```bash
# 1. 填写你的真实值
cp .env.example .env && vi .env

# 2. 渲染配置
./render.sh

# 3a. 部署 Headscale 控制面(见 headscale/README.md)
cd headscale && docker compose up -d

# 3b. 部署 k0s 集群
k0sctl apply --config k0s/k0sctl.yaml
# 3c. 应用 Calico 修复(幂等,reset 重装后需重跑)
bash k0s/scripts/apply-calico-fixes.sh
```

### 验证
```bash
k0sctl kubeconfig --config k0s/k0sctl.yaml > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

kubectl get nodes          # 两个节点都 Ready
kubectl get pods -A        # calico-node / calico-kube-controllers 全 Running

# 跨节点 pod 通信验证
kubectl run nettest --image=nginx --replicas=2
kubectl get pod -o wide    # 确认两个 pod 落在不同节点
kubectl exec nettest -- ping <对端 pod IP>
```

## 安全须知

- `.env`(含真实域名/IP/口令)、`certs/`(TLS 私钥)、`data/`(Headscale noise/derp 私钥 + SQLite)、
  `kubeconfig` 全部已 `.gitignore`,**不会**进入仓库。
- 仓库里只有模板(`.tpl`)和示例(`.env.example`),不含任何真实凭证。
- 推送前请确认 `git status` 没有意外文件。

## 文档
- [Headscale 控制面部署](headscale/README.md)
- [k0s 集群部署](k0s/README.md)
- [问题排查手册](docs/troubleshooting.md)

## License
MIT
