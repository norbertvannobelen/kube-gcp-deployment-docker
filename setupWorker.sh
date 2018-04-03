#!/bin/bash
# This version of the script contains both runc and docker components. 
# TODO: To be cleaned up/refactor to docker/runc component switches
# see norbertvannobelen/kube-gcp-deployment repo for why runc is here in this script

source ./genericFunctions.sh

nodeList=""

function createWorkerNode() {
  instance=${1}
  gcloud compute instances create ${instance} \
    --boot-disk-type ${WORKER_DISK_TYPE} \
    --boot-disk-size ${WORKER_DISK_SIZE} \
    --can-ip-forward \
    --image-family ubuntu-1604-lts \
    --image-project ubuntu-os-cloud \
    --machine-type ${WORKER_NODE_SIZE} \
    --scopes compute-rw,storage-rw,service-management,service-control,logging-write,monitoring \
    --subnet ${CLUSTER_NAME} \
    --tags ${CLUSTER_NAME},worker,${WORKER_TAGS} &
}

# The function createWorkerNode paves the worker:
# - Create the nodes
function createWorkerNodes() {
  for i in ${nodeList}; do
    createWorkerNode ${i}
  done
  sleep 180
}

# Create unique node identifiers (better than a sequence so that new nodes can be added later in a simple fashion)
function generateNodeIds() {
  unset nodeList
  for i in $(seq 1 ${NUMBER_OF_WORKERS}); do
    uniqueIdentifier=`date +%s`
    instance=${WORKER_NODE_PREFIX}-${uniqueIdentifier}
    if [ -z "${nodeList}" ] 
    then
      nodeList=${instance}
    else
      nodeList=${nodeList}" "${instance}
    fi
    sleep 1
  done
}

function installWorkerSoftware() {
  instance=${1}
  ${GSCP} setupWorkerSoftware.sh ${NODE_INSTALLATION_USER}@${instance}:~/

  ${GSSH}${instance} -- sudo ./setupWorkerSoftware.sh ${NODE_INSTALLATION_USER} ${KUBERNETES_VERSION}
}

function setupWorkerSoftware() {
  instance=${1}

  cat > kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=docker.service
Requires=docker.service


[Service]
ExecStart=/usr/local/bin/kubelet \\
  --v=2 \\
  --allow-privileged=true \\
  --cgroup-root=/ \\
  --cloud-provider=gce \\
  --cluster-dns=${CLUSTER_DNS} \\
  --cluster-domain=cluster.local \\
  --pod-manifest-path=/etc/kubernetes/manifests \\
  --enable-debugging-handlers=true \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --hairpin-mode=promiscuous-bridge \\
  --network-plugin=kubenet \\
  --volume-plugin-dir=/etc/srv/kubernetes/kubelet-plugins/volume/exec \\
  --node-labels=beta.kubernetes.io/fluentd-ds-ready=true \\
  --eviction-hard=memory.available<250Mi,nodefs.available<10%,nodefs.inodesFree<5% \\
  --tls-cert-file=/var/lib/kubelet/${instance}-kubelet.pem \\
  --tls-private-key-file=/var/lib/kubelet/${instance}-kubelet-key.pem \\
  --register-node=true \\
  --require-kubeconfig=true \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Configure kube-proxy
  ${GSCP} kubelet.service ${NODE_INSTALLATION_USER}@${instance}:~/

  cat > kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --resource-container= \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --iptables-sync-period=1m \\
  --iptables-min-sync-period=10s \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --master=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \\
  --kubeconfig=/var/lib/kube-proxy/kubeconfig \\
  --proxy-mode=iptables \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ${GSCP} kube-proxy.service ${NODE_INSTALLATION_USER}@${instance}:~/
  ${GSCP} gce-${BASE_NAME_EXTENDED}.conf ${NODE_INSTALLATION_USER}@${instance}:~/gce.conf
  ${GSSH}${instance} -- sudo mv gce.conf /etc/gce.conf

# Start the components:
  ${GSSH}${instance} -- sudo mv kubelet.service kube-proxy.service /etc/systemd/system/
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable kubelet kube-proxy

# Configure docker
  ${GSSH}${instance} -- sudo groupadd docker
  ${GSSH}${instance} -- sudo usermod -aG docker ${NODE_INSTALLATION_USER}
}

function genericNodeCertificate() {
  instance=${1}
# Client certificates:
  cat > kubelet-csr.json <<EOF
{
  "CN": "kubelet",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "system:nodes",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

  EXTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')
  INTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')

# Kubelet signing
  cfssl gencert \
    -ca=ca-${BASE_NAME_EXTENDED}.pem \
    -ca-key=ca-${BASE_NAME_EXTENDED}-key.pem \
    -config=ca-config-${BASE_NAME_EXTENDED}.json \
    -hostname=${instance},${EXTERNAL_IP},${INTERNAL_IP} \
    -profile=kubernetes \
    kubelet-csr.json | cfssljson -bare ${instance}-kubelet

# Generate kubernetes configuration file
# File per worker node:
  kubectl config set-cluster ${CLUSTER_NAME} \
    --certificate-authority=ca-${BASE_NAME_EXTENDED}.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials default-auth \
    --client-certificate=${instance}-kubelet.pem \
    --client-key=${instance}-kubelet-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=${CLUSTER_NAME} \
    --user=default-auth \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
}

function placeWorkerCert() {
  instance=$1

  ${GSCP} ca-${BASE_NAME_EXTENDED}.pem ${instance}-kubelet-key.pem ${instance}-kubelet.pem ${instance}.kubeconfig kube-proxy.kubeconfig ${NODE_INSTALLATION_USER}@${instance}:~/

# Configure kubelet
  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kubelet/
  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kube-proxy/
  ${GSSH}${instance} -- sudo mv ${instance}-kubelet-key.pem ${instance}-kubelet.pem /var/lib/kubelet/
  ${GSSH}${instance} -- sudo mv ${instance}.kubeconfig /var/lib/kubelet/kubeconfig
  ${GSSH}${instance} -- sudo mv ca-${BASE_NAME_EXTENDED}.pem /var/lib/kubernetes/ca.pem
  ${GSSH}${instance} -- sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
}

function configureWorkerNetwork() {
  instance=$1
# Ubuntu & docker config combination eeds net.ipv4.ip_forward activated to access the service network
  cat > sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF

  ${GSSH}${instance} -- sudo rm -f /etc/sysctl.conf
  ${GSCP} sysctl.conf ${NODE_INSTALLATION_USER}@${instance}:~/
  ${GSSH}${instance} -- sudo mv sysctl.conf /etc/sysctl.conf
}

# The function createWorkerNode paves the worker:
# - Create certificates
# - Install software
# - Setup all the software
function setupWorkerNodes() {
  for i in ${nodeList}; do
# This line still assumes we create workers only once. Needs to be replaced with a bit smarter algorithm (possible md5 of time and then substring of last 4 characters)
# Once adjusted also reset script needs to be aware of this
    instance=${i}
    genericNodeCertificate ${instance}
    placeWorkerCert ${instance}
    installWorkerSoftware ${instance}
    setupWorkerSoftware ${instance}
    configureWorkerNetwork ${instance}
    ${GSCP} restartWorker.sh ${NODE_INSTALLATION_USER}@${instance}:~/
    ${GSSH}${instance} -- sudo ./restartWorker.sh
  done
}

function installWorker() {
  echo "Starting worker installation"
  date
  # Env settings:
  set -o xtrace
  # Has to run: The Kubernetes public IP is used at several places
  generateNodeIds
  fetchKubernetesPublicIp
  fetchMasterIps
  createWorkerNodes
  setupWorkerNodes
  set -x xtrace
  date
  echo "Finished worker installation"
}

function installSingleWorker() {
  export NUMBER_OF_WORKERS=1
  installWorker
}
