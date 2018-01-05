#!/bin/bash
# Config/setup parameters used during installation

KUBERNETES_VERSION=v1.9.0

# GCP parameters
REGION=${Region:-us-east1}
ZONE=${Zone:-us-east1-c}
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}

# Generic node installation username
NODE_INSTALLATION_USER=ubuntu

# Master node parameters
MASTER_NODE_PREFIX=${MasterNodePrefix:-kubemaster}
NUMBER_OF_MASTERS=${NumberOfMasters:-1}
MASTER_DISK_SIZE=${MasterDiskSize:-10GB}
MASTER_DISK_TYPE=${MasterDiskType:-pd-ssd}
MASTER_NODE_SIZE=${MasterNodeSize:-n1-standard-1}

# Worker node paramaters
WORKER_NODE_PREFIX=${WorkerNodePrefix:-kubeworker}
NUMBER_OF_WORKERS=${NumberOfWorkers:-3}
WORKER_DISK_SIZE=${WorkerDiskSize:-10GB}
WORKER_DISK_TYPE=${WorkerDiskType:-pd-standard}
WORKER_TAGS=${WorkerTags:-kubeworker}
WORKER_NODE_SIZE=${MasterNodeSize:-n1-standard-2}

# Network parameters
CLUSTER_NAME=${ClusterName:-kubernetes-17}
CLUSTER_CIDR=10.200.0.0/16
CLUSTER_DNS=10.0.0.10
IP_NET=${IpNet:-10.240.0.0/16}

# Generic kubernetes parameters
DNS_DOMAIN=cluster.local
SERVICE_CLUSTER_IP_RANGE=10.0.0.0/16


