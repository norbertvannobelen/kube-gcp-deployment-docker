#!/bin/bash
# Delete worker nodes to reset (ie: remove) a complete cluster or to remove a single node

function resetWorkers() {
  for instance in `gcloud compute instances list|grep ${BASE_NAME_EXTENDED}|awk '{print $1}'`; do
    removeSingleNode ${instance}
  done
}

function removeSingleNode() {
  instance=${1}
  kubectl cordon ${instance}
  drain ${instance}
  gcloud compute instances delete ${instance} -q &
# TODO: Remove firewall rules & routes
}

# A user should override this function with a different drain function if this behavior is not the behavior required
# User should add any functions to terminate application pods on this node in a graceful fashion which need other behavior than just termination
# For example databases might not be served best by just terminating the node
#
# TODO: Drain result should be checked. Only after drain function is finished, the process should be allowed to continue
function drain() {
  instance=${1}
  kubectl drain ${instance} --delete-local-data --force
}
