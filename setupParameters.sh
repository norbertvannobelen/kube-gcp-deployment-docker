#!/bin/bash
# Config/setup parameters used during installation
# This version of the script contains both runc and docker components. 
# TODO: To be cleaned up/refactor to docker/runc component switches
# see norbertvannobelen/kube-gcp-deployment repo for why runc is here in this script

REGION=${Region:-us-east1}
ZONE=${Zone:-us-east1-c}
MASTER_NODE_PREFIX=${MasterNodePrefix:-kubemaster}
WORKER_NODE_PREFIX=${WorkerNodePrefix:-kubeworker}
NUMBER_OF_MASTERS=${NumberOfMasters:-1}
NUMBER_OF_WORKERS=${NumberOfWorkers:-3}
MASTER_DISK_SIZE=${MasterDiskSize:-10GB}
WORKER_DISK_SIZE=${WorkerDiskSize:-10GB}
MASTER_DISK_TYPE=${MasterDiskType:-pd-ssd}
WORKER_DISK_TYPE=${WorkerDiskType:-pd-standard}
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


