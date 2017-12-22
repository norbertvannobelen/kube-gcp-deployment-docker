#!/bin/bash

function resetWorkers() {
  for i in $(seq 1 ${NUMBER_OF_WORKERS}); do
    gcloud compute instances delete ${WORKER_NODE_PREFIX}0${i} -q &
  done
}

