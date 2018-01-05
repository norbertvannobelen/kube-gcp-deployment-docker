#!/bin/bash

# source setupParameters.sh

function resetMasters() {
# TODO: Replace with a gcloud query for the nodes and just delete what is there
  for j in $(seq 1 ${NUMBER_OF_MASTERS}); do
    gcloud compute instances delete ${MASTER_NODE_PREFIX}${j} -q &
  done
  sleep 125
# Remove the routes:
  for i in `gcloud compute routes list | grep ${CLUSTER_NAME} | awk '{print $1}'`
  do
    gcloud compute routes delete $i -q &
  done
  sleep 30

# Get the firewall rules and delete all of them:
  for i in `gcloud compute firewall-rules list|grep ${CLUSTER_NAME} |awk '{print $1}'`
  do
    gcloud compute firewall-rules delete $i -q &
  done
  sleep 15

  gcloud compute forwarding-rules delete ${CLUSTER_NAME}-forwarding-rule --region ${REGION} -q
  gcloud compute target-pools delete ${CLUSTER_NAME}-target-pool -q
  gcloud compute http-health-checks delete ${CLUSTER_NAME}-apiserver-health-check -q
  gcloud compute firewall-rules delete ${CLUSTER_NAME}-allow-health-checks -q
  gcloud compute firewall-rules delete ${CLUSTER_NAME}-allow-external -q
  gcloud compute firewall-rules delete ${CLUSTER_NAME}-allow-internal -q
  gcloud compute networks subnets delete ${CLUSTER_NAME} -q
  gcloud compute networks delete ${CLUSTER_NAME} -q
  gcloud compute addresses delete ${CLUSTER_NAME} -q
  rm -f *${BASE_NAME_EXTENDED}*.json
  rm -f *${BASE_NAME_EXTENDED}*.service
  rm -f *${BASE_NAME_EXTENDED}*.csr
  rm -f *${BASE_NAME_EXTENDED}*.pem
  rm -f *${BASE_NAME_EXTENDED}*.yaml
}


