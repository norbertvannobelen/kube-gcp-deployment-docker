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
