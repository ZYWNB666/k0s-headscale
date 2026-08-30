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

def build_k0sctl(env, kine_ds='', registry=''):
    # registry 参数保留兼容但不再使用 — images 块已删除, 用 k0s 自带正确版本
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
    is_controller = True
    for role, host, ip, user, port, key in [
        ('controller+worker', env['K0S_CONTROLLER_HOST'], env['K0S_CONTROLLER_IP'], env['K0S_CONTROLLER_SSH_USER'], env['K0S_CONTROLLER_SSH_PORT'], env['K0S_CONTROLLER_SSH_KEY']),
        ('worker', env['K0S_WORKER_HOST'], env['K0S_WORKER_IP'], env['K0S_WORKER_SSH_USER'], env['K0S_WORKER_SSH_PORT'], env['K0S_WORKER_SSH_KEY']),
    ]:
        noTaints = "\n      noTaints: true" if is_controller else ""
        lines.append(f"    - role: {role}{noTaints}")
        lines.append(f"      hostname: {host}")
        lines.append(f"      useExistingK0s: {env.get('K0S_USE_EXISTING_BINARY', 'false')}")
        lines.append("      installFlags:")
        lines.append(f"        - --kubelet-extra-args=--node-ip={ip}")
        lines.append("      ssh:")
        lines.append(f"        address: {ip}")
        lines.append(f"        user: {user}")
        lines.append(f"        port: {port}")
        lines.append(f"        keyPath: {key}")
        lines.append("      files:")
        if is_controller:
            # controller: 上传 adminnetworkpolicies CRD + RBAC(k0s 自带 19 CRD 缺这两个)
            for mfst in ['00-adminnetworkpolicies-crd.yaml',
                         '01-calico-admin-network-policies-rbac.yaml']:
                lines.append(f"        - src: manifests/{mfst}")
                lines.append('          dstDir: /var/lib/k0s/manifests/calico-fixes')
                lines.append('          perm: "0644"')
        lines.append("        - src: scripts/apply-nftables-rules.sh")
        lines.append("          dstDir: /usr/local/sbin")
        lines.append('          perm: "0755"')
        lines.append("        - src: systemd/k0s-calico-nftables.service")
        lines.append("          dstDir: /etc/systemd/system")
        lines.append('          perm: "0644"')
        lines.append("      hooks:")
        lines.append("        apply:")
        lines.append("          before:")
        lines.append("            - apt-get update -y >/dev/null 2>&1 || true")
        lines.append("            - apt-get install -y ipset >/dev/null 2>&1 || true")
        lines.append("          after:")
        lines.append("            - mkdir -p /etc/systemd/system/k0s-calico-nftables.service.d")
        lines.append(f"            - printf '[Service]\\\\nEnvironment=POD_CIDR={env['K0S_POD_CIDR']}\\\\n' > /etc/systemd/system/k0s-calico-nftables.service.d/override.conf")
        lines.append("            - systemctl daemon-reload")
        lines.append("            - systemctl enable k0s-calico-nftables.service")
        lines.append(f"            - POD_CIDR={env['K0S_POD_CIDR']} /usr/local/sbin/apply-nftables-rules.sh >/dev/null 2>&1 || true")
        is_controller = False
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
    # 注意: 不生成 envVars — FELIX_NFTABLESMODE 会让 felix panic(镜像无 nft 二进制),
    # 另两项模板已硬编码, 重复反而造成 env 冲突告警
    lines.append("          kubeProxy:")
    lines.append("            disabled: false")
    lines.append("            mode: ipvs")
    lines.append("            ipvs:")
    lines.append("              scheduler: rr")
    lines.append("              strictARP: false")
    if registry:
        lines.append("        images:")
        lines.append("          repository: " + registry)
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
    # calico.envVars 必须为空/不存在(见 build_k0sctl 内注释)
    ev = k0s.get('network', {}).get('calico', {}).get('envVars')
    chk(not ev, f"calico.envVars 为空(实际={ev})")
    chk(k0s['network']['kubeProxy']['mode'] == 'ipvs', "kubeProxy.mode=ipvs")
    # 镜像策略: 不钉任何版本(issue #8199 的教训)。
    # 设了代理 → 只写 repository(改写 host, 版本仍由 k0s 默认);没设 → 完全无 images 块。
    if registry:
        chk(k0s.get('images') == {'repository': registry}, f"images.repository={registry}")
        chk('calico' not in (k0s.get('images') or {}), "未钉 calico 镜像版本")
    else:
        chk('images' not in k0s, "无 images 块(用 k0s 自带正确版本)")
    hosts = spec['hosts']
    chk(len(hosts) == 2, "2 个 host")
    chk(hosts[0]['role'] == 'controller+worker', "host0=controller+worker")
    chk(hosts[1]['role'] == 'worker', "host1=worker")
    chk(hosts[0]['installFlags'][0].endswith(env['K0S_CONTROLLER_IP']), "controller node-ip flag")
    chk(hosts[1]['installFlags'][0].endswith(env['K0S_WORKER_IP']), "worker node-ip flag")
    chk(hosts[0].get('useExistingK0s') is True or hosts[0].get('useExistingK0s') is False,
        f"useExistingK0s 布尔值={hosts[0].get('useExistingK0s')}")
    # files 字段: controller 上传 2 manifest + nft 脚本/单元; worker 仅 nft 脚本/单元
    ctrl_files = hosts[0].get('files', [])
    chk(len(ctrl_files) == 4, f"controller files 数量=4 (2 manifest + 脚本 + 单元), 实际={len(ctrl_files)}")
    ctrl_dsts = {f.get('dstDir') for f in ctrl_files}
    chk('/var/lib/k0s/manifests/calico-fixes' in ctrl_dsts, "controller files 含 manifest 目标目录")
    chk('/usr/local/sbin' in ctrl_dsts, "controller files 含 nft 脚本目录")
    chk('/etc/systemd/system' in ctrl_dsts, "controller files 含 systemd 目录")
    wrk_files = hosts[1].get('files', [])
    chk(len(wrk_files) == 2, f"worker files 数量=2 (脚本 + 单元), 实际={len(wrk_files)}")
    wrk_dsts = {f.get('dstDir') for f in wrk_files}
    chk('/var/lib/k0s/manifests' not in str(wrk_dsts), "worker 不含 manifest(只在 controller)")
    # hooks.after: systemd 启用 + nft 首次应用 (不再有 loadbalancer 禁用, v3.32.1 支持)
    ctrl_after = hosts[0]['hooks']['apply']['after']
    chk(any('systemctl enable k0s-calico-nftables' in c for c in ctrl_after), "controller hook after 含 systemd enable")
    chk(any('apply-nftables-rules.sh' in c for c in ctrl_after), "controller hook after 含 nft 首次应用")
    chk(all('ENABLED_CONTROLLERS' not in c for c in ctrl_after), "controller hook after 不含 loadbalancer 禁用(v3.32.1 支持)")
    wrk_after = hosts[1]['hooks']['apply']['after']
    chk(any('systemctl enable k0s-calico-nftables' in c for c in wrk_after), "worker hook after 含 systemd enable")
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
