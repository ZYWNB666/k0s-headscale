## Headscale 配置 — 异地组网控制面
## 本文件是模板,由根目录 ./render.sh 渲染为 config.yaml(占位符来自 .env, 见 .env.example)。
## 架构: Caddy(TLS 终结, 3477/tcp) -> headscale(plain HTTP, 8080)

# 客户端连接地址(对外 HTTPS, 经 Caddy 反代)
server_url: https://${HEADSCALE_DOMAIN}:${HEADSCALE_PORT}

# 监听地址(仅本地, 由 Caddy 反代)
listen_addr: 127.0.0.1:8080

# metrics/debug 端点(仅本地; 用 9092 避开 k0s Calico felix 的 9091)
metrics_listen_addr: 127.0.0.1:9092

# gRPC 管理 API(仅本地, 不对外暴露)
grpc_listen_addr: 127.0.0.1:50443

# 信任的反代 CIDR(Docker 默认网段), 便于正确记录客户端真实 IP
trusted_proxies:
  - 172.16.0.0/12

# TS2021 Noise 协议私钥(缺失时自动生成)
noise:
  private_key_path: /var/lib/headscale/noise_private.key

# Tailnet IP 分配段(必须用 CGNAT/ULA 标准段, 不要改动)
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

# DERP 中继(自建, 打洞失败时兜底)
derp:
  server:
    # 启用内嵌 DERP 服务器(server_url 已为 https, 满足 TLS 要求)
    enabled: true
    region_id: 999
    region_code: ${DERP_REGION_CODE}
    region_name: "${DERP_REGION_NAME}"
    # 仅本 tailnet 节点可用, 拒绝外部客户端
    verify_clients: true
    # STUN 监听(UDP, 用于 NAT 穿越, 必须对外开放)
    stun_listen_addr: "0.0.0.0:${HEADSCALE_STUN_PORT}"
    private_key_path: /var/lib/headscale/derp_server_private.key
    automatically_add_embedded_derp_region: true
  # 不加载 Tailscale 官方 DERP 列表, 仅用自建中继(国内更稳定)
  urls: []
  paths: []
  auto_update_enabled: true

# 不使用 headscale 自带 TLS(Caddy 负责 TLS 终结)
tls_cert_path: ""
tls_key_path: ""

# 数据库(SQLite, 官方推荐)
database:
  type: sqlite
  gorm:
    prepare_stmt: true
    parameterized_queries: true
    skip_err_record_not_found: true
    slow_threshold: 1000
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true

# 日志
log:
  level: info
  format: text

# ACL 访问控制策略
policy:
  mode: file
  path: /etc/headscale/acl.hujson

# DNS / MagicDNS
dns:
  magic_dns: true
  # 必须与 server_url 域名不同
  base_domain: ${HEADSCALE_MAGICDNS_BASE}
  override_local_dns: true
  nameservers:
    global:
      - ${UPSTREAM_DNS_1}
      - ${UPSTREAM_DNS_2}
  search_domains: []
  extra_records: []
