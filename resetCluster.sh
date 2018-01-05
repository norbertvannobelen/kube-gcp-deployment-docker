#!/bin/bash

source resetWorker.sh
source resetMaster.sh

function resetCluster() {
  resetWorkers
  resetMasters
}


