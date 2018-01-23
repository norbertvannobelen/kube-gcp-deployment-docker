#!/bin/bash
# This script finds an empty ip range and sets up the configuration parameters for that.
#
# Usage:
# Load the normal setupMaster.sh/setupworker.sh:
# source setupMaster.sh
# source setupWorker.sh
#
# Then load this script
# source autoSetupMultiCluster.sh
#
# call the initMultiCluster function to get a valid config
#
# Networking background:
# For the cluster to work, two conditions are to be fulfilled:
# - Node networking needs to be correct;
# - Docker networking needs to be correct;
# Both have a /16 range in this cluster (and this script is setup to work with a /16 only!!!)
# The script scans for empty ranges in the GCP network ranges, and configures a VPC according to the current GCP standard (2018-01-03)

# base name is used to sort out all networks and nodes in all the scripts called from this script:

BASE_NAME=${BaseName:-kube}

# Master node parameters
MASTER_NODE_PREFIX=${BASE_NAME}master

# Worker node paramaters
WORKER_NODE_PREFIX=${BASE_NAME}worker
WORKER_TAGS=${BASE_NAME}worker

# Network parameters
CLUSTER_NAME=kubernetes-${BASE_NAME}
CLUSTER_CIDR=10.3.0.0/16
IP_NET=${IpNet:-10.2.0.0/16}
IP_START=10.2.0.0
IP_END=10.126.0.0
SUBNET_RANGE=16

# Generic kubernetes parameters
DNS_DOMAIN=cluster.local
SERVICE_CLUSTER_IP_RANGE=10.0.0.0/16
CLUSTER_DNS=10.0.0.10

# Due to the way the networks are allocated in an EMPTY VPC GCP this logic works.
# The logic looks for an empty network in the range from 
# start: 10.2.0.0 
# end: 10.126.0.0
# And uses /16 ranges only. This leads to a possible 62 k8s clusters in a single GCP with each a possible 256 nodes and 65k containers
function findNetwork() {
  subnetList=`gcloud compute networks subnets list|awk '{print $4}'`
  possibleSubnet=""
  # subnet counter, purely for /16, not dynamic:
  startNet=$(echo ${IP_START} | grep -o '[^-]*$')
  startNet=$(echo ${startNet} | cut -d. -f2)
  endNet=$(echo ${IP_END} | grep -o '[^-]*$')
  endNet=$(echo ${endNet} | cut -d. -f2)

  for ((i=${startNet};i<=${endNet};i+=2))
  do
    if [[ ${subnetList} == *"10.${i}.0.0"* ]]
    then
      echo "Net in use ${i}"
    else
      possibleSubnet=${i}
      break
    fi
  done
# To prevent issues on tear down of a cluster, prepend the found subnet with zeros until it is 3 digits long:
  possibleLength=${#possibleSubnet}
  additionalZeros=$((3-possibleLength))
  zeros=""
  for ((i=1;i<=${additionalZeros};i++)); do
    zeros=${zeros}"0"
  done
# Possible subnet contains the possible subnets, just pick the first and set the env variables:
  echo "using subnet start: "${possibleSubnet}
  BASE_NAME_EXTENDED=${BASE_NAME}${zeros}${possibleSubnet}
  IP_NET="10.${possibleSubnet}.0.0/${SUBNET_RANGE}"
  ((possibleSubnet++))
  CLUSTER_CIDR="10.${possibleSubnet}.0.0/${SUBNET_RANGE}"
  MASTER_NODE_PREFIX=${BASE_NAME_EXTENDED}master
  WORKER_NODE_PREFIX=${BASE_NAME_EXTENDED}worker
  WORKER_TAGS=${BASE_NAME_EXTENDED}worker
  CLUSTER_NAME=kubernetes-${BASE_NAME_EXTENDED}
}
