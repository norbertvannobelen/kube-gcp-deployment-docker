#!/bin/bash
# Wrapper script to just launch a full cluster.
#
# USAGE:
# ./runAll.sh NUMBER_OF_MASTERS NUMBER_OF_WORKERS REGION ZONE
#
# EXAMPLE:
# ./runAll.sh 1 5 us-central1 us-central1-f

source setupParameters.sh  
source setupMaster.sh  
source setupWorker.sh
source autoSetupMultiCluster.sh  

NUMBER_OF_MASTERS=${1}
NUMBER_OF_WORKERS=${2}


REGION=${3}
ZONE=${4}
gcloud config set compute/region ${REGION}
gcloud config set compute/zone ${ZONE}

findNetwork
installMasters
installWorkers

