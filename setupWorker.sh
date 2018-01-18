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

  ${GSSH}${instance} -- sudo add-apt-repository -y ppa:alexlarsson/flatpak
#https://launchpad.net/~projectatomic/+archive/ubuntu/ppa : Update cri-o
  ${GSSH}${instance} -- sudo apt-add-repository -y ppa:projectatomic/ppa
  ${GSSH}${instance} -- sudo apt-get update
  ${GSSH}${instance} -- sudo apt-get remove -y docker docker-engine docker.io
  ${GSSH}${instance} -- sudo apt-get install -y \
    btrfs-tools git golang-go libassuan-dev libdevmapper-dev libglib2.0-dev \
    libc6-dev libgpgme11-dev libgpg-error-dev libseccomp-dev libselinux1-dev \
    pkg-config runc skopeo-containers bridge-utils ntp \
    socat libgpgme11 libostree-1-1 conntrack \
    nfs-common \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
  ${GSSH}${instance} -- wget -q --show-progress --https-only --timestamping \
    https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-amd64-v0.6.0.tgz \
    https://github.com/opencontainers/runc/releases/download/v1.0.0-rc4/runc.amd64 \
    https://storage.googleapis.com/kubernetes-the-hard-way/crio-amd64-v1.0.0-beta.0.tar.gz \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-proxy \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubelet

# Install docker:
  ${GSSH}${instance} -- sudo wget https://download.docker.com/linux/ubuntu/gpg
  ${GSSH}${instance} -- sudo apt-key add gpg
  ${GSSH}${instance} -- sudo add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable\"
  ${GSSH}${instance} -- sudo apt-get update
  ${GSSH}${instance} -- sudo apt-get install -y docker-ce
  
  ${GSSH}${instance} -- sudo mkdir -p \
    /etc/containers \
    /etc/cni/net.d \
    /etc/crio \
    /opt/cni/bin
  ${GSSH}${instance} -- sudo mkdir -p  /usr/local/libexec/crio \
    /var/lib/kubelet \
    /var/lib/kube-proxy \
    /var/lib/kubernetes \
    /var/run/kubernetes
  ${GSSH}${instance} -- sudo tar -xvf cni-plugins-amd64-v0.6.0.tgz -C /opt/cni/bin/
  ${GSSH}${instance} -- sudo tar -xvf crio-amd64-v1.0.0-beta.0.tar.gz
  ${GSSH}${instance} -- sudo chmod +x kubectl kube-proxy kubelet runc.amd64
  ${GSSH}${instance} -- sudo mv runc.amd64 /usr/local/bin/runc
  ${GSSH}${instance} -- sudo mv crio crioctl kpod kubectl kube-proxy kubelet /usr/local/bin/
  ${GSSH}${instance} -- sudo mv conmon pause /usr/local/libexec/crio/
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
  --experimental-mounter-path=/home/kubernetes/containerized_mounter/mounter \\
  --experimental-check-node-capabilities-before-mount=true \\
  --cert-dir=/var/lib/kubelet/pki/ \\
  --enable-debugging-handlers=true \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --hairpin-mode=promiscuous-bridge \\
  --network-plugin=kubenet \\
  --volume-plugin-dir=/etc/srv/kubernetes/kubelet-plugins/volume/exec \\
  --node-labels=beta.kubernetes.io/fluentd-ds-ready=true \\
  --eviction-hard=memory.available<250Mi,nodefs.available<10%,nodefs.inodesFree<5% \\
  --tls-cert-file=/var/lib/kubelet/${instance}.pem \\
  --tls-private-key-file=/var/lib/kubelet/${instance}-key.pem \\
  --register-node=true \\
  --require-kubeconfig \\
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
  ${GSSH}${instance} -- sudo systemctl start kubelet kube-proxy

# Configure docker
  ${GSSH}${instance} -- sudo groupadd docker
  ${GSSH}${instance} -- sudo usermod -aG docker ${NODE_INSTALLATION_USER}
  ${GSSH}${instance} -- sudo systemctl enable docker
}

function genericNodeCertificate() {
  instance=${1}
# Client certificates:
  cat > ${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance}",
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

  cfssl gencert \
    -ca=ca-${BASE_NAME_EXTENDED}.pem \
    -ca-key=ca-${BASE_NAME_EXTENDED}-key.pem \
    -config=ca-config-${BASE_NAME_EXTENDED}.json \
    -hostname=${instance},${EXTERNAL_IP},${INTERNAL_IP} \
    -profile=kubernetes \
    ${instance}-csr.json | cfssljson -bare ${instance}

# Generate kubernetes configuration file
# File per worker node:
  kubectl config set-cluster ${CLUSTER_NAME} \
    --certificate-authority=ca-${BASE_NAME_EXTENDED}.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=${CLUSTER_NAME} \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
}

function placeWorkerCert() {
  instance=$1

  ${GSCP} ca-${BASE_NAME_EXTENDED}.pem ${instance}-key.pem ${instance}.pem ${instance}.kubeconfig kube-proxy-${BASE_NAME_EXTENDED}.kubeconfig ${NODE_INSTALLATION_USER}@${instance}:~/

# Configure kubelet
  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kubelet/
  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kube-proxy/
  ${GSSH}${instance} -- sudo mv ${instance}-key.pem ${instance}.pem /var/lib/kubelet/
  ${GSSH}${instance} -- sudo mv ${instance}.kubeconfig /var/lib/kubelet/kubeconfig
  ${GSSH}${instance} -- sudo mv ca-${BASE_NAME_EXTENDED}.pem /var/lib/kubernetes/ca.pem
  ${GSSH}${instance} -- sudo mv kube-proxy-${BASE_NAME_EXTENDED}.kubeconfig /var/lib/kube-proxy/kubeconfig
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
    ${GSSH}${instance} -- sudo shutdown -r -t 0 now
  done
}

function installWorkers() {
  # Env settings:
  set -o xtrace
  # Has to run: The Kubernetes public IP is used at several places
  generateNodeIds
  fetchKubernetesPublicIp
  fetchMasterIps
  createWorkerNodes
  setupWorkerNodes
  set -x xtrace
}

function installSingleWorker() {
  export NUMBER_OF_WORKERS=1
  installWorker
}
