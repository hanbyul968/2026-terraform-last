kubectl -n app set resources deploy/product --requests=cpu=50m
kubectl -n app rollout status deploy/product --timeout=120s
'{"spec":{"minReplicas":2,"maxReplicas":20,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":60}}}]}}' | Set-Content -Path "$env:TEMP\hpa-product-rollback.json" -Encoding ascii
kubectl -n app patch hpa product --type=merge --patch-file "$env:TEMP\hpa-product-rollback.json"
kubectl -n app set resources deploy/user --requests=cpu=100m
kubectl -n app rollout status deploy/user --timeout=120s
'{"spec":{"minReplicas":2,"maxReplicas":32,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":25}}}]}}' | Set-Content -Path "$env:TEMP\hpa-user-rollback.json" -Encoding ascii
kubectl -n app patch hpa user --type=merge --patch-file "$env:TEMP\hpa-user-rollback.json"