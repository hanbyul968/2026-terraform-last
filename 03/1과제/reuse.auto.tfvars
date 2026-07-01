# ⚠ 이 계정(640107381732) 전용 — 이전 배포가 남긴 '잠긴' CMK 5개를 재사용한다.
#   잠긴 키는 root 조차 삭제/DescribeKey 불가라 새로 만들 수도, 지울 수도 없어서
#   ARN 을 직접 지정해 재사용하고, eks 키 정책이 기존 클러스터 역할만 허용하므로
#   그 역할도 재사용한다.
#
# ★ 대회(깨끗한 다른 계정)에서는 이 파일을 삭제(또는 미포함)하라.
#   그러면 기본값(reuse_kms=false, reuse_eks_cluster_role=false)으로
#   CMK 5개와 eks-cluster-role 을 '정상 신규 생성'한다.
reuse_kms              = true
reuse_eks_cluster_role = true
