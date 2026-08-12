kubectl create namespace monitoring

wget https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz && tar -zxvf helm-v3.16.2-linux-amd64.tar.gz && sudo mv linux-amd64/helm /usr/local/bin
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install unicorn-monitoring prometheus-community/kube-prometheus-stack -n monitoring \
    --set prometheus.prometheusSpec.nodeSelector.unicorn=addon \
    --set prometheus.prometheusSpec.retention=7d \
    --set grafana.nodeSelector.unicorn=addon \
    --set alertmanager.alertmanagerSpec.nodeSelector.unicorn=addon \
    --set-string grafana.adminUser='skills608' \
    --set-string grafana.adminPassword='HelloKrSkills!608@' \
    --set grafana.service.type=NodePort \
    --set grafana.service.nodePort=30300 \
    --set kubeControllerManager.enabled=false \
    --set kubeScheduler.enabled=false \
    --set kubeEtcd.enabled=false