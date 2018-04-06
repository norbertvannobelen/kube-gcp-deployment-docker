#!/bin/bash
# This version of the script contains both runc and docker components. 
# TODO: To be cleaned up/refactor to docker/runc component switches
# see norbertvannobelen/kube-gcp-deployment repo for why runc is here in this script
# 
# USAGE:
# Load the script using:
# source setupMaster.sh
# installMasters
#
# If a specific network is required, the auto detection script can set these network requirements up.
# The steps are:
# source setupParameters.sh (optional, run once only)
# source setupMaster.sh
# source autoSetupMultiCluster.sh
# findNetwork
# installMasters

source ./genericFunctions.sh

ETCD_VERSION="v3.2.7"

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
  cat > ca-config-${BASE_NAME_EXTENDED}.json <<EOF
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

  cat > ca-csr-${BASE_NAME_EXTENDED}.json <<EOF
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
      "O": "kubernetes",
      "OU": "CA",
      "ST": "British Columbia"
    }
  ]
}
EOF

  cfssl gencert -initca ca-csr-${BASE_NAME_EXTENDED}.json | cfssljson -bare ca-${BASE_NAME_EXTENDED}

# admin client cert:
  cat > admin-csr-${BASE_NAME_EXTENDED}.json <<EOF
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
      "O": "cluster-admin",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

  cfssl gencert \
    -ca=ca-${BASE_NAME_EXTENDED}.pem \
    -ca-key=ca-${BASE_NAME_EXTENDED}-key.pem \
    -config=ca-config-${BASE_NAME_EXTENDED}.json \
    -profile=kubernetes \
    admin-csr-${BASE_NAME_EXTENDED}.json | cfssljson -bare admin-${BASE_NAME_EXTENDED}

# Api server certificates:
  cat > kubernetes-csr-${BASE_NAME_EXTENDED}.json <<EOF
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
      "O": "kubernetes",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    }
  ]
}
EOF

# Key to encrypt cluster data like secrets
  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

  cat > encryption-config-${BASE_NAME_EXTENDED}.yaml <<EOF
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

# Kubec controller manager kubeconfig file:
  for user in kube-proxy kube-controller-manager kube-scheduler aggregator
  do
# Generate certificate signing
    cat > ${user}-csr-${BASE_NAME_EXTENDED}.json <<EOF
{
  "CN": "system:${user}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CA",
      "L": "Vancouver",
      "O": "system:${user}",
      "OU": "${CLUSTER_NAME}",
      "ST": "British Columbia"
    } 
  ]
}
EOF

# Generate cert
    cfssl gencert \
      -ca=ca-${BASE_NAME_EXTENDED}.pem \
      -ca-key=ca-${BASE_NAME_EXTENDED}-key.pem \
      -config=ca-config-${BASE_NAME_EXTENDED}.json \
      -profile=kubernetes \
      ${user}-csr-${BASE_NAME_EXTENDED}.json | cfssljson -bare ${user}-${BASE_NAME_EXTENDED}

# Signing token (where applicable)
    TOKEN=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)

# Generate kubeconfig file per component for secure communication
    kubectl config set-cluster ${CLUSTER_NAME} \
      --certificate-authority=ca-${BASE_NAME_EXTENDED}.pem \
      --embed-certs=true \
      --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
      --kubeconfig=${user}.kubeconfig
    kubectl config set-credentials ${user} \
      --client-certificate=${user}-${BASE_NAME_EXTENDED}.pem \
      --client-key=${user}-${BASE_NAME_EXTENDED}-key.pem \
      --embed-certs=true \
      --token=${TOKEN} \
      --kubeconfig=${user}.kubeconfig
    kubectl config set-context ${user} \
      --cluster=${CLUSTER_NAME} \
      --user=${user} \
      --kubeconfig=${user}.kubeconfig

    kubectl config use-context ${user} --kubeconfig=${user}.kubeconfig
  done  

  cfssl gencert \
    -ca=ca-${BASE_NAME_EXTENDED}.pem \
    -ca-key=ca-${BASE_NAME_EXTENDED}-key.pem \
    -config=ca-config-${BASE_NAME_EXTENDED}.json \
    -hostname=10.0.0.1,${MASTER_IPS},${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,kubernetes.default \
    -profile=kubernetes \
  kubernetes-csr-${BASE_NAME_EXTENDED}.json | cfssljson -bare kubernetes-${BASE_NAME_EXTENDED}
}

# Can only be run once. 
# TODO: Build a check if the masters already exist: If exist, skip creation
function createMasterNodes() {
# Create the master nodes
  for i in $(seq 1 ${NUMBER_OF_MASTERS}); do
    gcloud compute instances create ${MASTER_NODE_PREFIX}${i} \
      --boot-disk-type ${MASTER_DISK_TYPE} \
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
  sleep 200
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
  ${GSSH}${instance} -- wget -q --https-only \
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
  INTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')
  PROJECT_ID=`gcloud config list|grep "project = "|awk '{print $3}'`

  cat > gce-${BASE_NAME_EXTENDED}.conf <<EOF
[global]
project-id = ${PROJECT_ID}
network-project-id = ${PROJECT_ID}
network-name = ${CLUSTER_NAME}
subnetwork-name = ${CLUSTER_NAME}
node-tags = ${WORKER_NODE_PREFIX}
node-instance-prefix = ${WORKER_NODE_PREFIX}
EOF

  cat > kube-apiserver-${BASE_NAME_EXTENDED}.service <<EOF
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
  --advertise-address=${INTERNAL_IP} \\
  --authorization-mode=Node,RBAC \\
  --apiserver-count=${NUMBER_OF_MASTERS} \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --bind-address=0.0.0.0 \\
  --enable-swagger-ui=true \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --insecure-bind-address=0.0.0.0 \\
  --runtime-config=api/all=true,rbac.authorization.k8s.io/v1alpha1=true \\
  --tls-ca-file=/var/lib/kubernetes/ca.pem \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --enable-aggregator-routing=true \\
  --anonymous-auth=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Controller config:
  cat > kube-controller-manager-${BASE_NAME_EXTENDED}.service <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --v=2 \\
  --cloud-config=/etc/gce.conf \\
  --use-service-account-credentials \\
  --cloud-provider=gce \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --service-cluster-ip-range=${SERVICE_CLUSTER_IP_RANGE} \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --cluster-name=kubernetes \\
  --allocate-node-cidrs=true \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --flex-volume-plugin-dir=/etc/srv/kubernetes/kubelet-plugins/volume/exec\\
  --address=0.0.0.0 \\
  --leader-elect=true \\
  --horizontal-pod-autoscaler-use-rest-clients=false
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Scheduler config
  cat > kube-scheduler-${BASE_NAME_EXTENDED}.service <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/GoogleCloudPlatform/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --leader-elect=true \\
  --feature-gates=ExperimentalCriticalPodAnnotation=true \\
  --kubeconfig=/var/lib/kubernetes/kube-scheduler.kubeconfig \\
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

  ${GSCP} ca-${BASE_NAME_EXTENDED}.pem ca-${BASE_NAME_EXTENDED}-key.pem kubernetes-${BASE_NAME_EXTENDED}-key.pem kubernetes-${BASE_NAME_EXTENDED}.pem ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
# Distribute the encryption password to the masters
  ${GSCP} encryption-config-${BASE_NAME_EXTENDED}.yaml ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  for user in node-proxier kube-controller-manager kube-scheduler aggregator
  do
    ${GSCP} ${user}-${BASE_NAME_EXTENDED}.kubeconfig ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  done

  ${GSSH}${instance} -- sudo mkdir -p /var/lib/kubernetes/
  ${GSSH}${instance} -- sudo mv ca-${BASE_NAME_EXTENDED}.pem /var/lib/kubernetes/ca.pem
  ${GSSH}${instance} -- sudo mv ca-${BASE_NAME_EXTENDED}-key.pem /var/lib/kubernetes/ca-key.pem
  ${GSSH}${instance} -- sudo mv kubernetes-${BASE_NAME_EXTENDED}-key.pem /var/lib/kubernetes/kubernetes-key.pem
  ${GSSH}${instance} -- sudo mv kubernetes-${BASE_NAME_EXTENDED}.pem /var/lib/kubernetes/kubernetes.pem
  ${GSSH}${instance} -- sudo mv encryption-config-${BASE_NAME_EXTENDED}.yaml /var/lib/kubernetes/encryption-config.yaml

  ${GSCP} glbc.service gce-${BASE_NAME_EXTENDED}.conf kube-apiserver-${BASE_NAME_EXTENDED}.service kube-scheduler-${BASE_NAME_EXTENDED}.service kube-controller-manager-${BASE_NAME_EXTENDED}.service ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/
  ${GSSH}${instance} -- sudo mv kube-apiserver-${BASE_NAME_EXTENDED}.service /etc/systemd/system/kube-apiserver.service
  ${GSSH}${instance} -- sudo mv kube-scheduler-${BASE_NAME_EXTENDED}.service /etc/systemd/system/kube-scheduler.service
  ${GSSH}${instance} -- sudo mv kube-controller-manager-${BASE_NAME_EXTENDED}.service /etc/systemd/system/kube-controller-manager.service
  ${GSSH}${instance} -- sudo mv *.kubeconfig /var/lib/kubernetes/
  ${GSSH}${instance} -- sudo mv glbc.service /etc/systemd/system/glbc.service
  ${GSSH}${instance} -- sudo mv gce-${BASE_NAME_EXTENDED}.conf /etc/gce.conf
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler glbc
  ${GSSH}${instance} -- sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler glbc
}
 
function installEtcd() {
  instance=${1}
  ${GSSH}${instance} -- wget -q --https-only --timestamping \
    "https://github.com/coreos/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
  ${GSSH}${instance} -- tar xf etcd-${ETCD_VERSION}-linux-amd64.tar.gz
  ${GSSH}${instance} -- sudo mv etcd-${ETCD_VERSION}-linux-amd64/etcd* /usr/local/bin/
# Configure
  ${GSSH}${instance} -- sudo mkdir -p /etc/etcd /var/lib/etcd
  ${GSSH}${instance} -- sudo cp ca-${BASE_NAME_EXTENDED}.pem /etc/etcd/ca.pem
  ${GSSH}${instance} -- sudo cp kubernetes-${BASE_NAME_EXTENDED}-key.pem /etc/etcd/kubernetes-key.pem
  ${GSSH}${instance} -- sudo cp kubernetes-${BASE_NAME_EXTENDED}.pem /etc/etcd/kubernetes.pem
  INTERNAL_IP=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')

cat > etcd-${BASE_NAME_EXTENDED}.service <<EOF
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

  ${GSCP} etcd-${BASE_NAME_EXTENDED}.service ${NODE_INSTALLATION_USER}@${MASTER_NODE_PREFIX}${i}:~/etcd.service
  ${GSSH}${instance} -- sudo mv etcd.service /etc/systemd/system/
  ${GSSH}${instance} -- sudo systemctl daemon-reload
  ${GSSH}${instance} -- sudo systemctl enable etcd
  ${GSSH}${instance} -- sudo systemctl start etcd
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

function installMasters() {
  # Env settings:
  set -o xtrace
  # Run it all
  setupInstallEnv
  setupNetworkGeneral
  # Has to run: The Kubernetes public IP is used at several places
  fetchKubernetesPublicIp
  createCA
  createMasterNodes
  fetchMasterIps
  echo "MASTER_IPS set: ${MASTER_IPS}"
  installMaster
  configureRemoteAccess
  setupRBAC
  addKubeComponents
  set -x
}
