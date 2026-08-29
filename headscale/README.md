# Headscale 控制面部署

自建 Tailscale 控制面,经 Caddy 做 TLS 终结,内嵌 DERP 中继和 STUN。

## 架构

```
异地节点 ──┐
          ├──► 公网 IP:3477/tcp ──► Caddy(TLS 终结)
异地节点 ──┘         │                  │ 反代
                     │ 3478/udp ────────┼──────► Headscale STUN(NAT 穿越)
                     ▼                  ▼
              ┌─────────────────────────────────┐
              │  控制面机器(host network)        │
              │  Caddy :3477  ──►  Headscale :8080(HTTP)
              │                    Headscale :3478/udp(STUN)
              │                    Headscale :50443(gRPC, 仅本地)
              └─────────────────────────────────┘
```

- **Caddy** 负责 TLS 终结,单端口 3477 按路径分流:`/web/*` → UI 静态文件,其余 → headscale
- **Headscale** 负责控制面 + 内嵌 DERP 中继 + STUN,全部 host network 直出
- 节点间优先 P2P 直连(UDP 打洞),失败回退自建 DERP 中继

## 前提

1. 一个域名(如 `headscale.example.com`),A 记录指向控制面机器的**公网 IP**
2. 公网 IP 到控制面机器需放行并转发:
   - `3477/tcp` → 控制面机器:3477(Caddy TLS)
   - `3478/udp` → 控制面机器:3478(STUN,**必须 UDP,必须公网直通**)
3. TLS 证书。推荐 acme.sh + DNS-01(阿里云/Cloudflare),签发后把 `.crt`/`.key` 放进 `certs/`,
   文件名 = `<你的域名>.crt` / `<你的域名>.key`(与 Caddyfile 模板一致)。

## 部署步骤

### 1. 生成配置

在仓库根目录:
```bash
cp .env.example .env && vi .env      # 填 HEADSCALE_DOMAIN / 端口 / DNS 等
./render.sh                          # 生成 headscale/config/config.yaml 和 caddy/Caddyfile
```

### 2. 放置证书与 UI

```bash
mkdir -p certs ui
# 证书(文件名须与域名一致)
cp /path/to/headscale.example.com.crt certs/
cp /path/to/headscale.example.com.key certs/
chmod 600 certs/*.key

# Web UI(可选): 下载 headscale-ui 构建产物放到 ui/
# https://github.com/gurucomputing/headscale-ui/releases
```

### 3. 启动

```bash
cd headscale
docker compose up -d
docker compose ps
docker compose logs -f headscale    # 看到 "listening" 即正常
```

### 4. 创建用户与密钥

```bash
docker exec headscale headscale users create default

# 预授权密钥(给客户端 tailscale up --authkey 用),90 天可复用
docker exec headscale headscale preauthkeys create -u 1 --reusable -e 90d

# API Key(给 Web UI / 脚本调管理 API 用)
docker exec headscale apikeys create
```

> 两种 key 不要混用:预授权密钥(`hskey-auth-` 前缀)给客户端接入,API Key 给 Web 控制台。
> 混用会返回 `Unauthorized(401)`。

### 5. 验证

浏览器访问 `https://<域名>:3477/` → 自动跳转 `/web/`。
首次进入 Settings 页面,填入 Headscale URL(`https://<域名>:3477`)和 API Key,保存并测试。

## 客户端接入

在每台要加入组网的机器上:

```bash
# 安装 Tailscale 客户端
curl -fsSL https://tailscale.com/install.sh | sh

# 接入自建控制面(用预授权密钥,不是 API Key)
sudo tailscale up \
  --login-server https://<域名>:3477 \
  --authkey <预授权密钥> \
  --accept-routes \
  --hostname <节点名>
```

验证:
```bash
tailscale status          # 节点列表
tailscale ping <对端 IP>  # direct = P2P 直连,relay = 走 DERP 中继
```

## 运维

```bash
cd headscale
docker compose ps                          # 状态
docker compose logs -f                     # 实时日志
docker compose restart                     # 重启
docker compose down && docker compose up -d   # 重建

docker exec headscale headscale nodes list       # 节点列表
docker exec headscale headscale users list      # 用户列表
docker exec headscale headscale preauthkeys list

# ACL 热重载(改 config/acl.hujson 后无需重启)
docker exec headscale kill -HUP 1
```

## 常见问题

**STUN 必须公网直通。** `3478/udp` 不能被 SNAT 改写源端口,否则 NAT 穿越失败、全靠 DERP 中继。
若 `tailscale ping` 一直显示 `relay`,先排查这条。

**证书续期。** acme.sh 续期后把新证书拷进 `certs/` 并 `docker compose restart caddy`。
可写 cron 自动化。

**metrics 端口避让。** config.yaml 里 `metrics_listen_addr` 用 9092,避开 k0s Calico felix 的 9091。
若本机不部署 k0s,可改回 9090。
