# fix-03

- Many cluster cleanup had an issue with a non-unique name of the cluster (kube2 filter would also filter kube20): Added prepended zeros on creation of the name.

# fix-02

- Added automatic network setup for many clusters in single project

# fix-01

- Split the script in master and worker setup scripts
- Create image from worker
- Create nodes from image
