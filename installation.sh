#!/bin/bash
# This version of the script contains both runc and docker components. 
# TODO: To be cleaned up/refactor to docker/runc component switches
# see norbertvannobelen/kube-gcp-deployment repo for why runc is here in this script

REGION=${Region:-us-east1}
ZONE=${Zone:-us-east1-c}
MASTER_NODE_PREFIX=${MasterNodePrefix:-kubemaster}
WORKER_NODE_PREFIX=${WorkerNodePrefix:-kubeworker}
NUMBER_OF_MASTERS=${NumberOfMasters:-1}
NUMBER_OF_WORKERS=${NumberOfWorkers:-2}
MASTER_DISK_SIZE=${MasterDiskSize:-10GB}
WORKER_DISK_SIZE=${WorkerDiskSize:-20GB}
WORKER_TAGS=${WorkerTags:-kubeworker}
CLUSTER_NAME=${ClusterName:-kubernetes-17}
CLUSTER_CIDR=10.200.0.0/16
CLUSTER_DNS=10.32.0.10
IP_NET=10.240.0.0/16
NODE_INSTALLATION_USER=ubuntu
MASTER_NODE_SIZE=${MasterNodeSize:-n1-standard-1}
KUBERNETES_VERSION=v1.9.0
DNS_SERVER_IP=10.32.0.10
DNS_DOMAIN=cluster.local
SERVICE_CLUSTER_IP_RANGE=10.32.0.0/16
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}


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

# The kubernetes cluster needs several networking rules. Setup all here in one function
# It only has to be ran once, repeated runs do not damage anything, so no previous run check is present
function setupNetworkGeneral() {
  gcloud compute networks create $CLUSTER_NAME --mode custom

  gcloud compute networks subnets create ${CLUSTER_NAME} --network $CLUSTER_NAME --range $IP_NET

  gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-internal \
    --allow tcp,udp,icmp \
    --network ${CLUSTER_NAME} \
    --source-ranges ${IP_NET},${CLUSTER_CIDR},${SERVICE_CLUSTER_IP_RANGE}

# The API server will be accessible through a load balancer this way
  gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-external \
    --allow tcp:22,tcp:6443,icmp \
    --network ${CLUSTER_NAME} \
    --source-ranges 0.0.0.0/0

  gcloud compute firewall-rules create ${CLUSTER_NAME}-allow-health-checks \
    --allow tcp:8080 \
    --network ${CLUSTER_NAME} \
    --source-ranges 209.85.204.0/22,209.85.152.0/22,35.191.0.0/16

  gcloud compute addresses create $CLUSTER_NAME --region $(gcloud config get-value compute/region)
}

# Create the main certificates, can only be run once.
# Not yet protected against multiple runs!!
function createCA() {
# Cert is valid for 10 years: No use to have a cluster break on a certificate expiry!
  cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "87600h"
      }
    }
  }
}
EOF

  cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "British Columbia"
    }
  ]
}
EOF

  cfssl gencert -initca ca-csr.json | cfssljson -bare ca

# admin client cert:
  cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "system:masters",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    admin-csr.json | cfssljson -bare admin

# kube proxy certs:

  cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "system:node-proxier",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -profile=kubernetes \
    kube-proxy-csr.json | cfssljson -bare kube-proxy

# Api server certificates:
  cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "Kubernetes",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

# Proxy kub-config:
  kubectl config set-cluster ${CLUSTER_NAME} \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials kube-proxy \
    --client-certificate=kube-proxy.pem \
    --client-key=kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=${CLUSTER_NAME} \
    --user=kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

# Key to encrypt cluster data like secrets
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

  cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
}

function createWorkerNode() {
  instance=${1}
  nodeCount=${2}
  gcloud compute instances create ${instance} \
    --boot-disk-type pd-ssd \
    --boot-disk-size ${WORKER_DISK_SIZE} \
    --can-ip-forward \
    --image-family ubuntu-1604-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-8 \
    --metadata pod-cidr=10.200.${nodeCount}.0/24 \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet ${CLUSTER_NAME} \
    --tags ${CLUSTER_NAME},worker,${WORKER_TAGS} &
}

# The function createWorkerNode paves the worker:
# - Create the nodes
function createWorkerNodes() {
  for i in $(seq 1 ${NUMBER_OF_WORKERS}); do
    instance=${WORKER_NODE_PREFIX}0${i}
    createWorkerNode ${instance} ${i}
  done
}

# Can only be run once. 
# TODO: Build a check if the masters already exist: If exist, skip creation
function createMasterNodes() {
# Create the master nodes
  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    gcloud compute instances create ${MASTER_NODE_PREFIX}${i} \
      --boot-disk-type pd-ssd \
      --boot-disk-size ${MASTER_DISK_SIZE} \
      --can-ip-forward \
      --image-family ubuntu-1604-lts \
      --image-project ubuntu-os-cloud \
      --machine-type ${MASTER_NODE_SIZE} \
      --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
      --subnet ${CLUSTER_NAME} \
      --tags ${CLUSTER_NAME},controller &
  done

# Sleep for a few moments to let masters start (Due to the order in the script, this also gives the workers enough time to start) (TODO: Replace with a ssh check: Once successful on connect, continue)
  sleep 180
}

function installMasterCertificates() {
# 10.32.0.1 is the master on internal pod network
  cfssl gencert \
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname=10.32.0.1,${MASTER_IPS},${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,kubernetes.default \
    -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    ${GSCP} ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
# Distribute the encryption password to the masters
    ${GSCP} encryption-config.yaml ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  done
}

function addFrontEndLoadBalancer() {
# Add front end load balancer:
  gcloud compute http-health-checks create ${CLUSTER_NAME}-apiserver-health-check \
    --description "Kubernetes ${CLUSTER_NAME} API Server Health Check" \
    --port 8080 \
    --request-path /healthz

  gcloud compute target-pools create ${CLUSTER_NAME}-target-pool \
    --http-health-check=${CLUSTER_NAME}-apiserver-health-check

  gcloud compute target-pools add-instances ${CLUSTER_NAME}-target-pool \
    --instances ${MASTER_LIST}

  gcloud compute forwarding-rules create ${CLUSTER_NAME}-forwarding-rule \
    --address ${KUBERNETES_PUBLIC_ADDRESS} \
    --ports 6443 \
    --region ${REGION} \
    --target-pool ${CLUSTER_NAME}-target-pool
}

function installMasterSoftware() {
  instance=${1}
  ${GSSH}${instance} -- wget -q --show-progress --https-only --timestamping \
    "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-apiserver" \
    "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-controller-manager" \
    "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-scheduler" \
    "https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl"

  ${GSCP} glbc/glbc ${NODE_INSTALLATION_USER}@${instance}:~/
  ${GSSH}${instance} -- sudo mv glbc /bin
  ${GSSH}${instance} -- sudo chmod +x /bin/glbc
  ${GSSH}${instance} -- chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
  ${GSSH}${instance} -- sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
}

function configureMaster() {
  instance=${1}
# Create API server
  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kubernetes/
  ${GSSH}${instance} -- sudo mv ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem encryption-config.yaml /var/lib/kubernetes/

  INTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')
  PROJECT_ID=`gcloud config list|grep "project = "|awk '{print $3}'`

  cat > gce.conf <<EOF
[global]
project-id = ${PROJECT_ID}
network-project-id = ${PROJECT_ID}
network-name = ${CLUSTER_NAME}
subnetwork-name = ${CLUSTER_NAME}
node-tags = ${WORKER_NODE_PREFIX}
node-instance-prefix = ${WORKER_NODE_PREFIX}
EOF

  cat > kube-apiserver.service <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --v=2 \\
  --cloud-config=/etc/gce.conf \\
  --address=127.0.0.1 \\
  --allow-privileged=true \\
  --cloud-provider=gce \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=${ETCD_CLUSTER} \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-https=true \\
  --service-account-key-file=/var/lib/kubernetes/ca-key.pem \\
  --service-cluster-ip-range=${SERVICE_CLUSTER_IP_RANGE} \\
  --service-node-port-range=30000-32767 \\
  --storage-backend=etcd3 \\
  --target-ram-mb=180 \\
  --etcd-quorum-read=false \\
  --admission-control=Initializers,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,Priority,ResourceQuota \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --advertise-address=${INTERNAL_IP}\\
  --authorization-mode=Node,RBAC \\
  --apiserver-count=${NUMBER_OF_MASTERS} \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --allow-privileged=true \\
  --bind-address=0.0.0.0 \\
  --enable-swagger-ui=true \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --insecure-bind-address=0.0.0.0 \\
  --runtime-config=rbac.authorization.k8s.io/v1alpha1 \\
  --tls-ca-file=/var/lib/kubernetes/ca.pem \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Controller config:
  cat > kube-controller-manager.service <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --v=2 \\
  --cloud-config=/etc/gce.conf \\
  --use-service-account-credentials \\
  --cloud-provider=gce \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/ca-key.pem \\
  --service-cluster-ip-range=${SERVICE_CLUSTER_IP_RANGE} \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --allocate-node-cidrs=true \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --flex-volume-plugin-dir=/etc/srv/kubernetes/kubelet-plugins/volume/exec\\
  --address=0.0.0.0 \\
  --leader-elect=true \\
  --master=http://${INTERNAL_IP}:8080 
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Scheduler config
  cat > kube-scheduler.service <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --leader-elect=true \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --master=http://${INTERNAL_IP}:8080 \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  cat > glbc.service <<EOF
[Unit]
Description=GoogleLoadBalancer service
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=kube-apiserver.service
Requires=kube-apiserver.service

[Service]
ExecStart=/bin/glbc \\
  --verbose=true \\
  --apiserver-host=http://localhost:8080 \\
  --default-backend-service=kube-system/default-http-backend \\
  --sync-period=600s \\
  --running-in-cluster=false \\
  --use-real-cloud=true \\
  --config-file-path=/etc/gce.conf 
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ${GSCP} glbc.service gce.conf encryption-config.yaml kube-apiserver.service kube-scheduler.service kube-controller-manager.service ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  ${GSSH}${instance} -- sudo mv kube-apiserver.service kube-scheduler.service kube-controller-manager.service glbc.service /etc/systemd/system/
  ${GSSH}${instance} -- sudo mv gce.conf /etc/
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler glbc
  ${GSSH}${instance} -- sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler glbc
}
 
function installEtcd() {
  instance=${1}
  ETCD_VERSION="v3.2.7"
  ${GSSH}${instance} -- wget -q --https-only --timestamping \
    "https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
  ${GSSH}${instance} -- tar xf etcd-${ETCD_VERSION}-linux-amd64.tar.gz
  ${GSSH}${instance} -- sudo mv etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
# Configure
  ${GSSH}${instance} -- sudo mkdir -p /etc/etcd /var/lib/etcd
  ${GSSH}${instance} -- sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
  INTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')

cat > etcd.service <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${instance} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://${INTERNAL_IP}:2380 \\
  --listen-client-urls https://${INTERNAL_IP}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls https://${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster ${INITIAL_ETCD_CLUSTER} \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  ${GSCP} etcd.service ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  ${GSSH}${instance} -- sudo mv etcd.service /etc/systemd/system/
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable etcd
  ${GSSH}${instance} -- sudo systemctl start etcd
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

function installMaster() {
  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    instance=${MASTER_NODE_PREFIX}${i}
    installEtcd ${instance}
    installMasterSoftware ${instance}
  done
  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    instance=${MASTER_NODE_PREFIX}${i}
    configureMaster ${instance}
  done
  addFrontEndLoadBalancer
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
  i=${2}
# Setup CNI network:

#  POD_CIDR=$(${GSSH}$instance -- 'curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr')
#
#  cat > 10-bridge.conf <<EOF
#{
#    "cniVersion": "0.3.1",
#    "name": "bridge",
#    "type": "bridge",
#    "bridge": "cnio0",
#    "isGateway": true,
#    "ipMasq": true,
#    "ipam": {
#        "type": "host-local",
#        "ranges": [
#          [{"subnet": "${POD_CIDR}"}]
#        ],
#        "routes": [{"dst": "0.0.0.0/0"}]
#    }
#}
#EOF
#
#  cat > 99-loopback.conf <<EOF
#{
#    "cniVersion": "0.3.1",
#    "type": "loopback"
#}
#EOF



#  cat > crio.service <<EOF
#[Unit]
#Description=CRI-O daemon
#Documentation=https://github.com/kubernetes-incubator/cri-o
#
#[Service]
#ExecStart=/usr/local/bin/crio
#Restart=always
#RestartSec=10s
#
#[Install]
#WantedBy=multi-user.target
#EOF

#  ${GSCP} 10-bridge.conf 99-loopback.conf crio.service ${NODE_INSTALLATION_USER}@${instance}:~/
#  ${GSSH}${instance} -- sudo mv 10-bridge.conf 99-loopback.conf /etc/cni/net.d/

# Configure CRI-O container runtime
#  ${GSSH}${instance} -- sudo mv crio.conf seccomp.json /etc/crio/
#  ${GSSH}${instance} -- sudo mv policy.json /etc/containers/

# Configure kubelet
  ${GSSH}${instance} -- sudo mv ${instance}-key.pem ${instance}.pem /var/lib/kubelet/
  ${GSSH}${instance} -- sudo mv ${instance}.kubeconfig /var/lib/kubelet/kubeconfig
  ${GSSH}${instance} -- sudo mv ca.pem /var/lib/kubernetes/

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
  #--bootstrap-kubeconfig=/var/lib/kubelet/bootstrap-kubeconfig \\

# Configure kube-proxy
  ${GSCP} kube-proxy.kubeconfig kubelet.service ${NODE_INSTALLATION_USER}@${instance}:~/
  ${GSSH}${instance} -- sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
# Create a config file (Not used right now)
#  ${GSSH}${instance} -- sudo /usr/local/bin/kube-proxy --kubeconfig=/var/lib/kube-proxy/kubeconfig --write-config-to=/var/lib/kube-proxy/config.yaml

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
  #--masquerade-all \\

  ${GSCP} kube-proxy.service ${NODE_INSTALLATION_USER}@${instance}:~/

# Start the components:
  ${GSSH}${instance} -- sudo mv kubelet.service kube-proxy.service /etc/systemd/system/
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable kubelet kube-proxy
  ${GSSH}${instance} -- sudo systemctl start kubelet kube-proxy
  ${GSSH}${instance} -- sudo mkdir -p /etc/kubernetes/manifests

# Configure pod networking:

#  gcloud compute instances describe ${instance} --format 'value[separator=" "](networkInterfaces[0].networkIP,metadata.items[0].value)'
#  gcloud compute routes create kubernetes-route-${instance} --network ${CLUSTER_NAME} --next-hop-address ${INTERNAL_IP} --destination-range 10.200.${i}.0/24

# Configure docker
  ${GSSH}${instance} -- sudo groupadd docker
  ${GSSH}${instance} -- sudo usermod -aG docker ${NODE_INSTALLATION_USER}
  ${GSSH}${instance} -- sudo systemctl enable docker
}

function createClientCerts() {
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
    -ca=ca.pem \
    -ca-key=ca-key.pem \
    -config=ca-config.json \
    -hostname=${instance},${EXTERNAL_IP},${INTERNAL_IP} \
    -profile=kubernetes \
    ${instance}-csr.json | cfssljson -bare ${instance}

# Generate kubernetes configuration file
# File per worker node:
  kubectl config set-cluster ${CLUSTER_NAME} \
    --certificate-authority=ca.pem \
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

  ${GSCP} ca.pem ${instance}-key.pem ${instance}.pem ${instance}.kubeconfig kube-proxy.kubeconfig ${NODE_INSTALLATION_USER}@${instance}:~/

# Ubuntu & docker config combination eeds net.ipv4.ip_forward activated to access the service network
  cat > sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF

  ${GSSH}${instance} -- sudo rm -f /etc/sysctl.conf
  ${GSCP} sysctl.conf ${NODE_INSTALLATION_USER}@${instance}:~/
  ${GSSH}${instance} -- sudo mv sysctl.conf /etc/sysctl.conf
}

function addExtraDisk() {
# TODO:
# Add secondary disk for hyperconverged storage solutions
#  gcloud compute instances create ${instance} 
  echo "todo"
}

# The function createWorkerNode paves the worker:
# - Create certificates
# - Install software
# - Setup all the software
function setupWorkerNodes() {
# Sleep for a few moments to let masters start (TODO: Replace with a ssh check: Once successful on connect, continue)
  for i in $(seq 1 ${NUMBER_OF_WORKERS}); do
# This line still assumes we create workers only once. Needs to be replaced with a bit smarter algorithm
    instance=${WORKER_NODE_PREFIX}0${i}
    createClientCerts ${instance}
    installWorkerSoftware ${instance}
    setupWorkerSoftware ${instance} ${i}
    ${GSSH}${instance} -- sudo shutdown -r -t 0 now
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

function installCluster() {
  # Env settings:
  set -o xtrace
  # Run it all
  setupInstallEnv
  setupNetworkGeneral
  # Has to run: The Kubernetes public IP is used at several places
  fetchKubernetesPublicIp
  createCA
  createWorkerNodes
  createMasterNodes
  fetchMasterIps
  echo "MASTER_IPS set: ${MASTER_IPS}"
  installMasterCertificates
  installMaster
  setupWorkerNodes
  configureRemoteAccess
  setupRBAC
  addKubeComponents
  set -x
}
