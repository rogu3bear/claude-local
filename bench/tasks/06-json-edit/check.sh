jq -e '.version=="1.3.0" and .engines.node==">=20" and .name=="demo-app" and .dependencies["left-pad"]=="^1.3.0" and .scripts.test=="echo ok"' package.json >/dev/null 2>&1 || exit 1
