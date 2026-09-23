#!/bin/bash
# 変更のあったサービスのイメージだけビルド・ロールアウトする(make deployの軽量版。deploy済みの
# クラスタへ、編集後の再ビルド・再反映を素早く行うための開発ループ用コマンド)。
#
# docker buildはレイヤーキャッシュが効くため未変更サービスもすぐ終わるが、各Deploymentは
# 固定タグ:local + imagePullPolicy: IfNotPresent(k8s/*/deployment.yaml)なので、イメージを
# 再ビルド・再importしてもマニフェスト自体は変化せずkubectl applyでは検知できない
# (Envoy/SPIREサイドカー込みのPodなのでrollout restartは軽くない。全サービス無条件restartは
# 避けたい)。そこでビルド前後のイメージID(docker image inspect)を比較し、実際に変わった
# サービスだけkubectl rollout restartする。
#
# 前提: make up && make deploy が完了済みであること(Secret・DB等の初期化はここでは行わない)。
set -euo pipefail

NAMESPACE=gekko

SERVICES=(account-service analyst-attribute-service fraud-detection-engine fraud-mcp-server fraud-agent frontend keycloak)

image_id() {
  docker image inspect --format '{{.Id}}' "gekko07/$1:local" 2>/dev/null || true
}

changed=()
for svc in "${SERVICES[@]}"; do
  before=$(image_id "$svc")
  echo "==> $svc をビルド中..."
  make "build-$svc"
  after=$(image_id "$svc")
  if [ "$before" != "$after" ]; then
    changed+=("$svc")
  fi
done

if [ "${#changed[@]}" -eq 0 ]; then
  echo "==> 変更されたイメージはありません。ロールアウトは不要です。"
  exit 0
fi

echo "==> 変更を検知したサービス: ${changed[*]}"
for svc in "${changed[@]}"; do
  kubectl -n "$NAMESPACE" rollout restart "deployment/$svc"
done
# rollout statusはPodがReadyになるまでブロックする。ここが終わるまでこのコマンド自体を
# 完了させない(動作確認は反映完了後に行うことがほとんどのため、待機を明確にする)。
for svc in "${changed[@]}"; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$svc" --timeout=180s
done
echo "==> 反映完了: ${changed[*]}"
