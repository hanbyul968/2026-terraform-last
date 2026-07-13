############################
# finalize (EKS public->private 전환) 는 ./k8s 스테이지로 이동했다.
#   - null_resource.private_only 는 모든 kubernetes_*/helm_release 적용이 끝난 뒤
#     실행되어야 하므로, 해당 리소스들과 같은 ./k8s 스테이지(main.tf 마지막)에 둔다.
#   - 이렇게 하면 root 에는 kubernetes/helm provider 의존이 전혀 없어
#     import/plan/destroy 가 깨끗하게 동작한다.
############################
