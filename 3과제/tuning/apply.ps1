'{"spec":{"minReplicas":2,"maxReplicas":8,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":70}}}]}}' | Set-Content -Path "$env:TEMP\hpa-product-apply.json" -Encoding ascii
kubectl -n app patch hpa product --type=merge --patch-file "$env:TEMP\hpa-product-apply.json"
kubectl -n app set resources deploy/product --requests=cpu=250m
kubectl -n app rollout status deploy/product --timeout=120s
'{"spec":{"minReplicas":2,"maxReplicas":9,"metrics":[{"type":"Resource","resource":{"name":"cpu","target":{"type":"Utilization","averageUtilization":90}}}]}}' | Set-Content -Path "$env:TEMP\hpa-user-apply.json" -Encoding ascii
kubectl -n app patch hpa user --type=merge --patch-file "$env:TEMP\hpa-user-apply.json"
kubectl -n app set resources deploy/user --requests=cpu=775m
kubectl -n app rollout status deploy/user --timeout=120s