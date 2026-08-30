# 问题排查手册

k0s 在 Tailscale/Headscale overlay 上部署时遇到的 17 个问题,按现象归类。
每条给出:现象 → 根因 → 定位命令 → 修复(对应本仓库的哪一层)。

## 目录
- [网络互通类](#网络互通类)
- [Calico 组件异常类](#calico-组件异常类)
- [节点与组件就绪类](#节点与组件就绪类)
- [部署与镜像类](#部署与镜像类)

---

## 网络互通类

### 1. 跨节点 pod 完全不通
- **现象**:`ping` 跨节点 pod IP 全丢,`kubectl exec` 进 pod 也无法访问 Service。
- **根因**:kube-router 用 IPIP(IP 协议号 4)封装 pod 流量,WireGuard 只转发 TCP/UDP/ICMP,
  IPIP 包被 Tailscale 隧道丢弃。
- **定位**:`kubectl get nodes -o wide` 看 CNI;tailscale 节点间 `tcpdump proto 4` 看不到包通过。
- **修复**:k0sctl.yaml `network.provider: calico` + `calico.mode: vxlan`(UDP 4789,可穿越 WireGuard)。

### 2. 跨节点 pod 不通,但同节点正常
- **现象**:同节点 pod 互访正常,跨节点 pod 不通。
- **根因**:Calico 自动检测节点 IP 做 VXLAN VTEP,选了物理网卡 IP(如 192.168.x.x),
  跨 Tailscale 节点路由不到该 IP。
- **定位**:`kubectl get nodes -o jsonpath='{.items[*].status.addresses}'` 看 node IP;
  在 calico-node pod 里 `ip -d link show vxlan.calico` 看 VTEP local IP 是否为 Tailscale IP。
- **修复**:k0sctl.yaml `calico.ipAutodetectionMethod: interface=tailscale0`。

### 3. pod 无法访问 Service ClusterIP
- **现象**:pod 内 `curl 10.96.0.1` 超时,但 node 上 `curl` 正常。
- **根因**:kube-proxy iptables 模式下,Service DNAT 后的包走 FORWARD 链,被 Calico
  "Unknown interface" DROP。
- **定位**:`iptables-save | grep -i cali` 看 FORWARD 链计数;
  `kubectl logs -n kube-system -l k8s-app=kube-proxy`。
- **修复**:k0sctl.yaml `network.kubeProxy.mode: ipvs`(IPVS 在 PREROUTING 完成 DNAT)。

### 4. 节点重启后跨节点 pod 流量再次不通
- **现象**:重启前一切正常,重启后跨节点 pod / pod→Service 又被丢。
- **根因**:nftables 规则只存内存,Calico 重启只重建自己的链,不重建额外的 pod 网段放行规则。
- **定位**:`nft list ruleset | grep 10.244` 看放行规则是否还在。
- **修复**:`k0s-calico-nftables.service` 开机自动重应用(由 apply-calico-fixes.sh 安装)。

---

## Calico 组件异常类

### 5. calico-node 一直 0/1 或反复重启
- **现象**:`kubectl get pods -n kube-system` 里 calico-node 不 Ready 或 CrashLoopBackOff。
- **根因(可能之一)**:容器内打包的 ipset v7.11 不支持内核的 `hash:ip` revision 6,felix panic。
- **定位**:`kubectl logs -n kube-system -l k8s-app=calico-node | grep -i panic`。
- **修复**:k0sctl.yaml `calico.envVars.FELIX_NFTABLESMODE: Enabled`(用 nftables 代替 ipset);
  k0sctl hook 顺带 `apt install ipset` 升级宿主机 ipset 作安全网。

### 6. calico-kube-controllers FATAL 退出 / RBAC forbidden / adminnetworkpolicies 报错
- **现象**:calico-kube-controllers 报 `Invalid controller 'loadbalancer'` FATAL,
  或 `serviceaccounts is forbidden`,或 calico-node 报
  `the server could not find the requested resource (get adminnetworkpolicies...)`。
- **根因**:镜像与模板版本错配。⚠️ 这通常是**自己造成的**——在 k0sctl.yaml 的
  `spec.images.calico` 里手动钉了旧版本/上游镜像名(如 `quay.io/calico/node:v3.29.3`),
  而 k0s 的 chart 模板来自 v3.32.1。k0s 自带默认是配套的
  `quay.io/k0sproject/calico-*:v3.32.1-2`(-2 后缀是 k0s 的补丁号)。
  详见 https://github.com/k0sproject/k0s/issues/8199
- **定位**:`kubectl get ds -n kube-system calico-node -o jsonpath='{.spec.template.spec.containers[0].image}'`
  对照 k0s 常量 `pkg/constant/constant.go` 的 Calico*ImageVersion。
- **修复**:**删掉 spec.images.calico 覆盖**,让 k0s 用自带版本;需要代理时只用
  `spec.images.repository` 改写 registry host(不碰版本)。

### 7. calico-node 报 "adminnetworkpolicies 资源不存在"
- **现象**:felix 日志反复 list `adminnetworkpolicies` 失败,calico-node 不 ready。
- **根因**:k0s 自带的 `static/manifests/calico/CustomResourceDefinition/` 只有 19 个 CRD,
  不含 `adminnetworkpolicies` / `baselineadminnetworkpolicies`(v3.32 felix 会 watch 它们)。
  这是 k0s 打包遗漏(issue #8199),与镜像版本无关,版本对了也缺。
- **定位**:`kubectl get crd | grep adminnetworkpolicy`(为空即缺)。
- **修复**:manifest `00-adminnetworkpolicies-crd.yaml` + `01-calico-admin-network-policies-rbac.yaml`
  (由 k0sctl files 上传到 /var/lib/k0s/manifests/ 自动 apply)。

### 8. calico-node 报 "adminnetworkpolicies 资源不存在 / forbidden"
- **现象**:felix 日志反复 list `adminnetworkpolicies` 失败,calico-node 不 ready。
- **根因**:k0s v1.36 的 calico_init/ CRD 目录缺这两个 CRD(只有 19 个旧 CRD),
  但 v3.32 模板的 felix 会 watch 它们。
- **定位**:`kubectl get crd | grep adminnetworkpolicy`(为空即缺)。
- **修复**:manifest `00-adminnetworkpolicies-crd.yaml` + `01-...-rbac.yaml`。

---

## 节点与组件就绪类

### 9. 节点 NotReady
- **现象**:部分节点长期 NotReady。
- **根因**:kubelet 自动选物理网卡 IP 作 node-ip,跨 Tailscale 节点访问不到该 IP,
  API server 与 kubelet 通信失败。
- **定位**:`kubectl get nodes -o wide`,看 INTERNAL-IP 是否为 Tailscale IP(100.64.x.x)。
- **修复**:k0sctl.yaml `installFlags: [--kubelet-extra-args=--node-ip=<Tailscale_IP>]`。

### 10. Calico 默认阻断 pod 到 host 的管理流量
- **现象**:pod 无法 ping 同节点 host,部分依赖 host 网络的健康检查失败。
- **根因**:FelixConfiguration 默认 `defaultEndpointToHostAction=DROP`。
- **定位**:`kubectl get felixconfiguration default -o yaml | grep defaultEndpointToHostAction`。
- **修复**:k0sctl.yaml `calico.envVars.FELIX_DEFAULTENDPOINTTOHOSTACTION: ACCEPT`。

### 11. calico-node 健康检查不响应
- **现象**:calico-node readiness 探针失败。
- **根因**:FelixConfiguration 默认 `healthEnabled=false`,健康端点不响应。
- **定位**:`kubectl get felixconfiguration default -o yaml | grep healthEnabled`。
- **修复**:k0sctl.yaml `calico.envVars.FELIX_HEALTHENABLED: "true"`。

### 12. FelixConfiguration 的 nftablesMode 为 Auto(无效)
- **现象**:Calico 行为不确定,nft 模式时灵时不灵。
- **根因**:k0s 默认 `nftablesMode=Auto` 在该版本下不是有效值。
- **定位**:`kubectl get felixconfiguration default -o yaml | grep nftablesMode`。
- **修复**:k0sctl.yaml `calico.envVars.FELIX_NFTABLESMODE: Enabled`(与问题5同源)。

---

## 部署与镜像类

### 13. k0s 二进制下载慢/超时
- **现象**:k0sctl apply 卡在下载 k0s 二进制(249MB),最终超时。
- **根因**:GitHub 下载到国内极慢。
- **修复**:用国内镜像下载 k0s 二进制后,k0sctl 设 `useExistingK0s: true` 用本地二进制。

### 14. 镜像拉取失败/超时
- **现象**:pod ImagePullBackOff,Docker 日志显示 registry 请求超时。
- **根因(可能)**:Docker daemon 配了失效的 socks5 代理,所有 registry 请求都走代理超时。
- **定位**:`systemctl cat docker | grep -i proxy`;`docker pull` 测试。
- **修复**:移除失效代理配置(`rm /etc/systemd/system/docker.service.d/http-proxy.conf`),重启 Docker。

### 15. kine 数据库脏数据导致重装失败
- **现象**:`k0sctl apply` 在 manifest deployer 阶段报版本冲突,无法部署。
- **根因**:多次失败部署在 kine 数据库留下脏数据。
- **修复**:重装前清空 kine 数据库(`DROP DATABASE k0s_kine; CREATE DATABASE k0s_kine;`)。

### 16. CentOS 7 节点部署失败
- **现象**:CentOS 7 节点 kubelet 起不来。
- **根因**:k0s v1.36 强制要求 cgroup v2,CentOS 7 内核 3.10 只有 cgroup v1。
- **修复**:只使用支持 cgroup v2 的节点(Ubuntu 22.04+/Debian 12/CentOS 8+ 升级内核)。

### 17. quay.io / docker.io 直连拉取慢
- **现象**:拉取 calico/coredns 等镜像很慢或失败。
- **根因**:国内直连境外 registry 不稳定。
- **修复**:`.env` 设 `K0S_REGISTRY_PROXY`(如 `harbor.example.com/quay.io`),render.sh 生成
  `spec.images.repository` —— k0s 只改写 registry 主机名,**版本仍用 k0s 自带值**。
  ⚠️ 不要用 `spec.images.calico.*` 手动钉镜像名/版本来实现代理——那是造成问题 6 的根源。

---

## 速查:节点不通的排查顺序

```
kubectl get nodes -o wide
  └─ INTERNAL-IP 是 Tailscale IP?  → 否: 检查 installFlags node-ip(问题9)
  └─ Ready?                         → 否: kubectl describe node, 看 kubelet 日志

kubectl get pods -n kube-system
  └─ calico-node Running?           → 否: 看 panic(问题5) / CRD(问题8)
  └─ calico-kube-controllers?       → 否: 看 FATAL(问题6) / RBAC(问题7)

kubectl get felixconfiguration default -o yaml
  └─ nftablesMode=Enabled?          → 否(问题5/12)
  └─ healthEnabled=true?            → 否(问题11)
  └─ defaultEndpointToHostAction?   → DROP(问题10)

nft list ruleset | grep 10.244      → 无放行规则(问题4, 重应用 nft 脚本)
```
