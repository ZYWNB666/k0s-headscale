#!/usr/bin/env python3
"""校验 render.sh 的渲染逻辑(纯内存,不写文件)。
读取 .env.example, 在内存里复刻 k0sctl.yaml 的条件生成逻辑,
用两种存储/代理组合验证 YAML 合法性与关键字段。
也校验 headscale 模板的 envsubst 占位符与 .env 变量名一致。
"""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            # 剥离行内注释: bash 中 " #..." 才算注释(空格+#), "val#x" 不算
            cmt = re.search(r'\s+#', line)
            if cmt:
                line = line[:cmt.start()]
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    return env

def parse_env_example():
    return load_env(os.path.join(REPO, '.env.example'))

def gen_image(name, img_prefix, repo, ver):
    return f"          {name}:\n            image: {img_prefix}quay.io/{repo}\n            version: {ver}\n"

def build_k0sctl(env, kine_ds='', registry=''):
    img_prefix = (registry + '/') if registry else ''
    # 镜像 render.sh: storage 块自带 10 空格缩进, 顶格插入(下方 storage: 为 8 空格)
    if kine_ds:
        storage = ('          type: kine\n'
                   '          kine:\n'
                   f'            dataSource: "{kine_ds}"')
    else:
        storage = '          type: etcd'
    lines = []
    lines.append("apiVersion: k0sctl.k0sproject.io/v1beta1")
    lines.append("kind: Cluster")
    lines.append("metadata:")
    lines.append(f"  name: {env['K0S_CLUSTER_NAME']}")
    lines.append("spec:")
    lines.append("  hosts:")
    for role, host, ip, user, port, key in [
        ('controller+worker', env['K0S_CONTROLLER_HOST'], env['K0S_CONTROLLER_IP'], env['K0S_CONTROLLER_SSH_USER'], env['K0S_CONTROLLER_SSH_PORT'], env['K0S_CONTROLLER_SSH_KEY']),
        ('worker', env['K0S_WORKER_HOST'], env['K0S_WORKER_IP'], env['K0S_WORKER_SSH_USER'], env['K0S_WORKER_SSH_PORT'], env['K0S_WORKER_SSH_KEY']),
    ]:
        noTaints = "\n      noTaints: true" if role.startswith('controller') else ""
        lines.append(f"    - role: {role}{noTaints}")
        lines.append(f"      hostname: {host}")
        lines.append("      installFlags:")
        lines.append(f"        - --kubelet-extra-args=--node-ip={ip}")
        lines.append("      ssh:")
        lines.append(f"        address: {ip}")
        lines.append(f"        user: {user}")
        lines.append(f"        port: {port}")
        lines.append(f"        keyPath: {key}")
        lines.append("      hooks:")
        lines.append("        apply:")
        lines.append("          before:")
        lines.append("            - apt-get update -y >/dev/null 2>&1 || true")
        lines.append("            - apt-get install -y ipset >/dev/null 2>&1 || true")
        lines.append("          after:")
        lines.append(f"            - POD_CIDR={env['K0S_POD_CIDR']} /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true")
    lines.append("  k0s:")
    lines.append(f"    version: {env['K0S_VERSION']}")
    lines.append("    versionChannel: stable")
    lines.append("    dynamicConfig: false")
    lines.append("    config:")
    lines.append("      apiVersion: k0s.k0sproject.io/v1beta1")
    lines.append("      kind: ClusterConfig")
    lines.append("      metadata:")
    lines.append(f"        name: {env['K0S_CLUSTER_NAME']}")
    lines.append("      spec:")
    lines.append("        api:")
    lines.append(f"          address: {env['K0S_CONTROLLER_IP']}")
    lines.append(f"          externalAddress: {env['K0S_CONTROLLER_IP']}")
    lines.append("          port: 6443")
    lines.append("          k0sApiPort: 9443")
    lines.append("          sans:")
    lines.append(f"            - {env['K0S_CONTROLLER_IP']}")
    lines.append("            - 127.0.0.1")
    lines.append("        storage:")
    lines.append(storage)
    lines.append("        network:")
    lines.append("          provider: calico")
    lines.append(f"          podCIDR: {env['K0S_POD_CIDR']}")
    lines.append(f"          serviceCIDR: {env['K0S_SERVICE_CIDR']}")
    lines.append("          calico:")
    lines.append("            mode: vxlan")
    lines.append("            overlay: Always")
    lines.append(f"            ipAutodetectionMethod: interface={env['TAILSCALE_IFACE']}")
    lines.append("            envVars:")
    lines.append("              FELIX_NFTABLESMODE: Enabled")
    lines.append("              FELIX_DEFAULTENDPOINTTOHOSTACTION: ACCEPT")
    lines.append('              FELIX_HEALTHENABLED: "true"')
    lines.append("          kubeProxy:")
    lines.append("            disabled: false")
    lines.append("            mode: ipvs")
    lines.append("            ipvs:")
    lines.append("              scheduler: rr")
    lines.append("              strictARP: false")
    lines.append("        images:")
    lines.append(gen_image('konnectivity', img_prefix, 'k0sproject/apiserver-network-proxy-agent', 'v0.36.0-k0s.0').rstrip('\n'))
    lines.append(gen_image('metricsserver', img_prefix, 'k0sproject/metrics-server', 'v0.9.0-k0s.0').rstrip('\n'))
    lines.append(gen_image('kubeproxy', img_prefix, 'k0sproject/kube-proxy', 'v1.36.3-1').rstrip('\n'))
    lines.append(gen_image('coredns', img_prefix, 'k0sproject/coredns', '1.14.6-k0s.0').rstrip('\n'))
    lines.append(gen_image('pause', img_prefix, 'k0sproject/pause', '3.10.2-0').rstrip('\n'))
    lines.append("          calico:")
    lines.append("            cni:")
    lines.append(f"              image: {img_prefix}quay.io/calico/cni")
    lines.append("              version: v3.29.3")
    lines.append("            node:")
    lines.append(f"              image: {img_prefix}quay.io/calico/node")
    lines.append("              version: v3.29.3")
    lines.append("            kubecontrollers:")
    lines.append(f"              image: {img_prefix}quay.io/calico/kube-controllers")
    lines.append("              version: v3.29.3")
    lines.append("        telemetry:")
    lines.append("          enabled: false")
    lines.append("  options:")
    lines.append("    wait:")
    lines.append("      enabled: true")
    lines.append("    drain:")
    lines.append("      enabled: true")
    lines.append("      gracePeriod: 2m")
    lines.append("      timeout: 5m")
    lines.append("      force: true")
    lines.append("      ignoreDaemonSets: true")
    lines.append("      deleteEmptyDirData: true")
    return "\n".join(lines) + "\n"

def check_k0sctl(env, kine_ds, registry, label):
    try:
        import yaml
    except ImportError:
        print(f"[{label}] PyYAML 未安装,跳过 YAML 解析(仅生成)")
        return True
    text = build_k0sctl(env, kine_ds, registry)
    d = yaml.safe_load(text)
    spec = d['spec']; k0s = spec['k0s']['config']['spec']
    ok = True
    def chk(cond, msg):
        nonlocal ok
        print(f"  [{'OK' if cond else 'FAIL'}] {msg}")
        ok = ok and cond
    chk(d['kind'] == 'Cluster', "kind=Cluster")
    chk(k0s['storage']['type'] == ('kine' if kine_ds else 'etcd'), f"storage={k0s['storage']['type']}")
    if kine_ds:
        chk(k0s['storage']['kine']['dataSource'] == kine_ds, "kine dataSource 正确")
    chk(k0s['network']['calico']['mode'] == 'vxlan', "calico.mode=vxlan")
    chk(k0s['network']['calico']['overlay'] == 'Always', "calico.overlay=Always")
    chk(k0s['network']['calico']['ipAutodetectionMethod'] == f"interface={env['TAILSCALE_IFACE']}", "ipAutodetectionMethod=tailscale0")
    ev = k0s['network']['calico']['envVars']
    chk(ev['FELIX_NFTABLESMODE'] == 'Enabled', "FELIX_NFTABLESMODE=Enabled")
    chk(ev['FELIX_DEFAULTENDPOINTTOHOSTACTION'] == 'ACCEPT', "defaultEndpointToHostAction=ACCEPT")
    chk(ev['FELIX_HEALTHENABLED'] == 'true', "healthEnabled=true")
    chk(k0s['network']['kubeProxy']['mode'] == 'ipvs', "kubeProxy.mode=ipvs")
    prefix = (registry + '/') if registry else ''
    chk(k0s['images']['calico']['node']['image'] == f"{prefix}quay.io/calico/node", f"calico.node.image 前缀={'有' if prefix else '无'}")
    chk(k0s['images']['konnectivity']['image'] == f"{prefix}quay.io/k0sproject/apiserver-network-proxy-agent", "konnectivity 镜像前缀")
    hosts = spec['hosts']
    chk(len(hosts) == 2, "2 个 host")
    chk(hosts[0]['role'] == 'controller+worker', "host0=controller+worker")
    chk(hosts[1]['role'] == 'worker', "host1=worker")
    chk(hosts[0]['installFlags'][0].endswith(env['K0S_CONTROLLER_IP']), "controller node-ip flag")
    chk(hosts[1]['installFlags'][0].endswith(env['K0S_WORKER_IP']), "worker node-ip flag")
    print(f"[{label}] {'PASS' if ok else 'FAIL'}\n")
    return ok

def check_headscale_templates(env):
    """校验模板里的 ${VAR} 都能在 .env 找到对应键(防变量名拼写不一致)。"""
    print("=== 校验 headscale 模板占位符 ===")
    ok = True
    for tpl in ['headscale/config/config.yaml.tpl', 'headscale/caddy/Caddyfile.tpl']:
        with open(os.path.join(REPO, tpl)) as f:
            content = f.read()
        vars_in_tpl = set(re.findall(r'\$\{([A-Z0-9_]+)\}', content))
        missing = {v for v in vars_in_tpl if v not in env}
        print(f"  [{tpl}] 占位符: {sorted(vars_in_tpl)}")
        if missing:
            ok = False
            print(f"    FAIL: .env 缺少 {missing}")
        else:
            print(f"    OK: 全部能在 .env.example 找到")
    print()
    return ok

def check_manifests():
    """校验所有 manifest YAML 合法。"""
    print("=== 校验 k0s manifest YAML ===")
    try:
        import yaml
    except ImportError:
        print("  PyYAML 未安装,跳过")
        return True
    ok = True
    mdir = os.path.join(REPO, 'k0s', 'manifests')
    for fn in sorted(os.listdir(mdir)):
        if not fn.endswith('.yaml'):
            continue
        path = os.path.join(mdir, fn)
        with open(path) as f:
            text = f.read()
        docs = list(yaml.safe_load_all(text))
        kinds = [d.get('kind') for d in docs if d]
        print(f"  [{fn}] {len(docs)} doc(s): {kinds}")
        ok = ok and all(d is not None for d in docs)
    print()
    return ok

def main():
    env = parse_env_example()
    ok = True
    ok = check_headscale_templates(env) and ok
    ok = check_manifests() and ok
    print("=== 校验 k0sctl 渲染(4 种组合)===")
    ok = check_k0sctl(env, '', '', '默认 etcd + 直连') and ok
    ok = check_k0sctl(env, 'mysql://k0s:pw@tcp(db.example.com:3306)/k0s_kine', '', 'kine + 直连') and ok
    ok = check_k0sctl(env, '', 'harbor.example.com', 'etcd + 代理') and ok
    ok = check_k0sctl(env, 'mysql://k0s:pw@tcp(db.example.com:3306)/k0s_kine', 'harbor.example.com', 'kine + 代理') and ok
    print("=" * 50)
    print("全部通过" if ok else "存在失败项")
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
