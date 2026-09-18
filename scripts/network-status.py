#!/usr/bin/env python3
"""make network-status用。

make statusがコンテナの起動状況を見せるのに対し、こちらは「誰が誰と話せるか」
(NetworkPolicy、ADR 0018)と「その通信路の実プロトコル」(Envoyサイドカーの静的bootstrap
設定、ADR 0012/0015/0019/0020/0028のmTLS化)を突き合わせて表示する。

Envoyのenvoy.yamlはConfigMap変更をホットリロードしない(insights.md)ため、ここで表示する
プロトコルは「ConfigMapに書かれている内容」であって「今動いているPodに実際に反映済みの内容」
とは限らない(Pod再起動が必要)。NetworkPolicy側は逆にkubectlで見えるものがそのまま
今のクラスタで有効なルールである。
"""
import json
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent


def kubectl_json(args):
    try:
        proc = subprocess.run(
            ["kubectl", *args, "-o", "json"], capture_output=True, text=True, timeout=15
        )
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def fetch_configmap_data(namespace, name, key):
    try:
        proc = subprocess.run(
            ["kubectl", "get", "configmap", name, "-n", namespace,
             "-o", f"jsonpath={{.data.{key}}}"],
            capture_output=True, text=True, timeout=15,
        )
    except FileNotFoundError:
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return proc.stdout


def discover_envoy_configmaps():
    """repo内のk8s/**/*envoy-configmap.yamlからConfigMap名・namespaceの一覧だけを得る
    (中身は使わない。中身は必ずkubectlから生で取る。理由は上記docstring参照)。"""
    pairs = []
    for f in sorted(REPO_ROOT.glob("k8s/*/*envoy-configmap.yaml")):
        for doc in yaml.safe_load_all(f.read_text()):
            if not doc or doc.get("kind") != "ConfigMap":
                continue
            meta = doc.get("metadata", {})
            ns, name = meta.get("namespace"), meta.get("name")
            if ns and name:
                pairs.append((ns, name))
    return pairs


def tls_summary(transport_socket):
    """transport_socketからプロトコル種別(mTLS/plaintext等)と、SPIFFE ID許可/検証リストを返す。"""
    if not transport_socket:
        return "plaintext", []
    typed = transport_socket.get("typed_config", {}) or {}
    type_url = typed.get("@type", "")
    ctx = typed.get("common_tls_context", {}) or {}
    valctx = (ctx.get("combined_validation_context") or {}).get("default_validation_context") or {}
    sans = [
        m.get("matcher", {}).get("exact")
        for m in valctx.get("match_typed_subject_alt_names", []) or []
        if m.get("matcher", {}).get("exact")
    ]
    if "DownstreamTlsContext" in type_url:
        mode = "mTLS必須" if typed.get("require_client_certificate") else "TLS(サーバー証明書のみ)"
    elif "UpstreamTlsContext" in type_url:
        mode = "mTLS"
    else:
        mode = "TLS"
    return mode, sans


def socket_addr(node):
    return ((node or {}).get("address", {}) or {}).get("socket_address", {}) or {}


def parse_envoy_yaml(raw):
    """他Podから到達しうるlistener(ingress)と、他Podへ向かうcluster(egress)だけを返す。
    127.0.0.1宛て/pipe宛て(spire_agentのUDSやapp_upstreamの同一Pod内ループバック)は
    NetworkPolicyの管轄外なのでここで除外する。"""
    doc = yaml.safe_load(raw)
    sr = (doc or {}).get("static_resources", {}) or {}

    listeners = []
    for l in sr.get("listeners", []) or []:
        addr = socket_addr(l)
        host, port = addr.get("address"), addr.get("port_value")
        if host in (None, "127.0.0.1"):
            continue
        for fc in l.get("filter_chains", []) or [{}]:
            mode, sans = tls_summary(fc.get("transport_socket"))
            listeners.append({"name": l.get("name"), "port": port, "protocol": mode, "peer_spiffe": sans})

    clusters = []
    for c in sr.get("clusters", []) or []:
        lb_endpoints = (
            (((c.get("load_assignment") or {}).get("endpoints") or [{}])[0]).get("lb_endpoints") or [{}]
        )
        addr = socket_addr(lb_endpoints[0].get("endpoint") if lb_endpoints else None)
        host, port = addr.get("address"), addr.get("port_value")
        if host in (None, "127.0.0.1"):
            continue
        mode, sans = tls_summary(c.get("transport_socket"))
        clusters.append({"name": c.get("name"), "dest": host, "port": port, "protocol": mode, "peer_spiffe": sans})

    return listeners, clusters


def pod_selector_label(selector):
    labels = (selector or {}).get("matchLabels") or {}
    if "app" in labels:
        return labels["app"]
    if labels:
        return ",".join(f"{k}={v}" for k, v in labels.items())
    return "(namespace内の全Pod)"


def format_ports(ports):
    if not ports:
        return "全ポート"
    return ",".join(f"{p.get('protocol', 'TCP').lower()}/{p.get('port', '*')}" for p in ports)


def print_networkpolicies():
    print("=== NetworkPolicy(通信許可。ADR 0018) ===")
    data = kubectl_json(["get", "networkpolicy", "-A"])
    if data is None:
        print("(クラスタ未到達)")
        return
    items = data.get("items", [])
    if not items:
        print("(NetworkPolicyが1件も見つかりません)")
        return
    items.sort(key=lambda np: (np["metadata"]["namespace"], np["metadata"]["name"]))
    for np in items:
        ns = np["metadata"]["namespace"]
        name = np["metadata"]["name"]
        spec = np.get("spec", {})
        app = pod_selector_label(spec.get("podSelector"))
        print(f"\n[{ns}] {name}  (対象Pod: app={app})")
        ingress = spec.get("ingress", []) or []
        egress = spec.get("egress", []) or []
        if "Ingress" in spec.get("policyTypes", []) and not ingress:
            print("  ingress: (ルールなし = 全遮断)")
        for rule in ingress:
            froms = [pod_selector_label(f.get("podSelector")) for f in rule.get("from", []) or []] or ["(すべての送信元)"]
            print(f"  ingress ← {', '.join(froms)}  [{format_ports(rule.get('ports'))}]")
        if "Egress" in spec.get("policyTypes", []) and not egress:
            print("  egress: (ルールなし = 全遮断)")
        for rule in egress:
            tos = [pod_selector_label(t.get("podSelector")) for t in rule.get("to", []) or []] or ["(すべての宛先)"]
            print(f"  egress  → {', '.join(tos)}  [{format_ports(rule.get('ports'))}]")


def print_protocols():
    print("\n=== Envoyサイドカーの実プロトコル ===")
    print("(静的bootstrap設定はホットリロードされないため、直近でConfigMapを更新したのに")
    print(" Pod未再起動の場合は実際の挙動と食い違うことがある。insights.md参照)")
    for ns, name in discover_envoy_configmaps():
        raw = fetch_configmap_data(ns, name, "envoy\\.yaml")
        print(f"\n[{ns}] {name}")
        if raw is None:
            print("  (クラスタ未到達、またはConfigMap未適用)")
            continue
        try:
            listeners, clusters = parse_envoy_yaml(raw)
        except yaml.YAMLError as e:
            print(f"  (envoy.yamlの解析に失敗: {e})")
            continue
        if not listeners and not clusters:
            print("  (他Podとの通信なし。同一Pod内ループバックのみ)")
        for l in listeners:
            peer = f"  [許可SPIFFE ID: {', '.join(l['peer_spiffe'])}]" if l["peer_spiffe"] else ""
            print(f"  listen :{l['port']} ({l['name']})  {l['protocol']}{peer}")
        for c in clusters:
            peer = f"  [検証SPIFFE ID: {', '.join(c['peer_spiffe'])}]" if c["peer_spiffe"] else ""
            print(f"  egress → {c['dest']}:{c['port']} ({c['name']})  {c['protocol']}{peer}")


def main():
    print_networkpolicies()
    print_protocols()


if __name__ == "__main__":
    sys.exit(main())
