#!/bin/bash
# Generic functions used in cluster setup

# Gcloud compute ssh is used to execute remote commands. To make the code a bit more readable an alias is added for this:
GSSH="gcloud compute ssh --force-key-file-overwrite ${NODE_INSTALLATION_USER}@"
GSCP="gcloud compute scp --force-key-file-overwrite"

function fetchKubernetesPublicIp() {
  KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe ${CLUSTER_NAME} \
    --region $(gcloud config get-value compute/region) \
    --format 'value(address)')
}

# For installation purposes, the local linux environment needs tools to create the certificates, and it needs kubectl
# It only has to be ran once, repeated runs do not damage anything, so no previous run check is present
function setupInstallEnv() {
  wget \
    https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 \
    https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64

  chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
  sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
  sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

  wget https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
}

# The master IP addresses (internal ips) are required for certificate creation. This function retrieves the IPs
function fetchMasterIps() {
  unset MASTER_LIST
  unset MASTER_IPS
  unset INITIAL_ETCD_CLUSTER
  unset ETCD_CLUSTER
  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    MASTER_IP=$(gcloud compute instances describe ${MASTER_NODE_PREFIX}${i} --format 'value(networkInterfaces[0].networkIP)')
    if [ -n "${MASTER_IPS}" ]
    then
      MASTER_LIST=${MASTER_NODE_PREFIX}${i},${MASTER_LIST}
      MASTER_IPS=${MASTER_IP},${MASTER_IPS}
      INITIAL_ETCD_CLUSTER=${MASTER_NODE_PREFIX}${i}=https://${MASTER_IP}:2380,${INITIAL_ETCD_CLUSTER}
      ETCD_CLUSTER=https://${MASTER_IP}:2379,${ETCD_CLUSTER}
    else
      MASTER_LIST=${MASTER_NODE_PREFIX}${i}
      MASTER_IPS=${MASTER_IP}
      INITIAL_ETCD_CLUSTER=${MASTER_NODE_PREFIX}${i}=https://${MASTER_IP}:2380
      ETCD_CLUSTER=https://${MASTER_IP}:2379
    fi
  done
}

function configureRemoteAccess() {
  kubectl config set-cluster ${CLUSTER_NAME} \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem

  kubectl config set-context ${CLUSTER_NAME} \
    --cluster=${CLUSTER_NAME} \
    --user=admin

  kubectl config use-context ${CLUSTER_NAME}
}

function addKubeComponents() {
  kubectl create -f https://storage.googleapis.com/kubernetes-the-hard-way/kube-dns.yaml
  kubectl create -f https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/saltbase/salt/kube-addons/kube-addon-manager.yaml
  kubectl create -f glbc/default-backend.yaml
  kubectl create -f glbc/default-backend-svc.yaml
#  kubectl create -f https://raw.githubusercontent.com/prometheus/prometheus/master/documentation/examples/prometheus-kubernetes.yml
  kubectl create namespace monitoring
  kubectl create -f https://raw.githubusercontent.com/giantswarm/kubernetes-prometheus/master/manifests/prometheus/deployment.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/src/deploy/recommended/kubernetes-dashboard.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/heapster.yaml

}

function setupRBAC() {
 # kubectl create clusterrolebinding add-on-cluster-admin --clusterrole=cluster-admin --serviceaccount=kube-system:default
  kubectl create clusterrolebinding permissive-binding \
    --clusterrole=cluster-admin \
    --user=admin \
    --user=kubelet \
    --group=system:serviceaccounts
}
