# kube-gcp-deployment-docker

Docker based kubernetes launch scripts based on http://github.com/norbertvannobelen/kube-gcp-deployment

# Current version notes

This version contains a set of unused software due to the switch out of CRI-O with Docker. This switch out was done due to an incompatibility between CRI-O/runc and the GCE cloud provider settings: Network does not initialize:
- CNI step is skipped with CRI-O while the step is not skipped when using Docker
- And CNI step is required since GCE API server config seems to always want to control the network bridge, thus leading to duplicate/incorrect routes when controlling the network in a different fashion.

## Usage notes

Installation script has been split in subscripts
- setupMaster.sh: source setupMaster.sh && installMasters
- setupWorker.sh: source setupWorker.sh && source setupParameters.sh && installWorkers
- autoSetupMultiCluster.sh: Utilizes VPC networks to create multiple isolated clusters
    source autoSetupMultiCluster.sh && source setupMaster.sh && source SetupWorkers.sh && findNetwork && installMasters && installWorkers

Cleaning up is improved:
- source resetWorkers.sh && removeSingleNode {nodename} 
   removes a node with a drain of the node (drain might need adjustment based on the containers)
- source resetWorker.sh && resetWorkers : Removes all workers
- source resetMaster.sh && resetMasters : Removes all masters & cleans up network. Assumes that the workers are already removed.



# TODO

Current script paves nodes from scratch. This is a bit slow:
- Add image creation step for worker;
- Initialize workers from above image instead.
- Add intelligent node scaler
- Add other k8s components like prometheus and fluentd
- Add multi cluster in single Google Cloud project setup
