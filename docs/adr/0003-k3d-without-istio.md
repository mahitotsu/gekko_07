# ADR 0003: ローカル実行基盤にk3d（Istioは当面不採用）を採用

- **Status**: Accepted
- **Date**: 2026-09-13

## Context

AWS Bedrock AgentCore（Gateway/Runtime/Identity）上での構築を検討したが、固定費が高く試行錯誤に向かないと判断し、ローカルのKubernetes互換環境で検証する方針に転換した。ローカルKubernetes環境として、Docker上で動く軽量な選択肢（k3d、kind、minikube）を比較した上でk3dを選定した（決め手はDocker Composeからの移行コストの低さと、ビルトインLoadBalancer/Ingressコントローラの取り回しの良さ）。

サイドカー（Envoy + ext_authz）をPodに載せる方法として、以下を検討した。

| 手段 | 評価 |
|---|---|
| **素のEnvoyを手動サイドカーとして構成（採用）** | 5サービス程度なら手書きPod specの重複は大きな負担にならない。bootstrap yaml・ext_authz設定・ヘッダー許可リストが全て見える化され、学習目的と相性が良い |
| Istio（`AuthorizationPolicy` CUSTOM + `extensionProviders.envoyExtAuthzHttp`） | サイドカー自動注入、宣言的なext_authz配線、mTLSが副産物として手に入る。ただしistiod・sidecar injection webhook・関連CRDという新しい制御プレーンが丸ごと乗り、学習対象が本来のテーマ（token exchangeのサイドカー移譲）から拡散する |

## Decision

- ローカルKubernetes基盤に**k3d**を採用する
- サイドカーは**素のEnvoyを手動構成**する。Istioは当面採用しない

## Consequences

- Istioの主要な付加価値（自動サイドカー注入、mTLS、トラフィック管理）は得られないが、今回の検証目的には不要
- 素のEnvoy構成で作った`ext_authz`サービスは標準プロトコルに従う限りIstioからもそのまま呼べるため、将来Istio導入を追加検証したくなった場合も作り捨てにならない
- k3dのWSL2環境での既知の制約（cgroup v1非互換）に実機で遭遇し、対応した。詳細は[insights.md](../insights.md)を参照
