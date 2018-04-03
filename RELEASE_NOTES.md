# fix-11

- kube-proxy.kubeconfig installation had legacy code which resulted in not moving the file to kubeconfig

# fix-10

- Replaced the use of localhost master on port 8080 with certificate based methods for the master servers;
- Added kubeconfig files to kube-proxy and kubelet for correct usernames;
- Primary implementation for use of metrics-server added (disabled due to system:anonymous message from HPA, under investigation. Using legacy method for HPA for now)
- Refactor certificate functions to be more concise

# fix-09

- Changed admin certs to be inline in the kube config

# fix-08

- speed up worker installation by re-organizing how software is installed
- dynamic wait for software installation to finish instead of waiting for it inline

# fix-07

- auto network configuration filter is not exact enough: Altered filter for better behavior

# fix-06

- Added runAll.sh wrapper script to launch a complete cluster from 1 line. The only config settings requested are number of masters & number of workers
- Renamed installWorker to installWorkers to be consistent with the installMasters function

# fix-05

- Read/write rights for storage engine access so that images can be pushed from a CI/CD to gcr.io

# fix-04

- Removed experimental mounter from kubelet;
- Changed base k8s cluster network from 10.32 to 10.0 (10.32 would conflict with the network autodetection)
- Added dns/svc.yaml: The dns deployment did not create the svc thus rendering the dns not usable

# fix-03

- Many cluster cleanup had an issue with a non-unique name of the cluster (kube2 filter would also filter kube20): Added prepended zeros on creation of the name.

# fix-02

- Added automatic network setup for many clusters in single project

# fix-01

- Split the script in master and worker setup scripts
- Create image from worker
- Create nodes from image
