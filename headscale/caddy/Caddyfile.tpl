# Caddyfile — Headscale 控制面 + DERP 中继 + Web UI(单端口 3477)
# 本文件是模板,由根目录 ./render.sh 渲染为 Caddyfile(占位符来自 .env, 见 .env.example)。
# 证书由 acme.sh (AliDNS DNS-01) 签发后放入 ./certs/。
# 同一个 3477 端口按路径分流:
#   /web/*  → UI 静态文件
#   其余    → headscale 反代(客户端协议 /key /derp 等 + /api/* 管理API)

{
	admin off
	auto_https off
}

${HEADSCALE_DOMAIN}:${HEADSCALE_PORT} {
	tls /etc/caddy/certs/${HEADSCALE_DOMAIN}.crt /etc/caddy/certs/${HEADSCALE_DOMAIN}.key

	# ---- 根路径 / 重定向到 /web/ (浏览器访问入口) ----
	redir / /web/ permanent

	# ---- Web UI 静态资源(/web/* → 映射到 ui 目录) ----
	handle_path /web/* {
		root * /etc/caddy/ui
		encode gzip
		try_files {path} /index.html
		file_server
	}

	# ---- 其余全部反代到 headscale(客户端协议 + API) ----
	handle {
		reverse_proxy 127.0.0.1:8080 {
			header_up X-Real-IP {remote_host}
			header_up X-Forwarded-For {remote_host}
			header_up X-Forwarded-Proto {scheme}
			flush_interval -1
			transport http {
				dial_timeout 10s
				keepalive 60s
			}
		}
	}
}
