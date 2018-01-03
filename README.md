# kube-gcp-deployment-docker

Docker based kubernetes launch scripts based on http://github.com/norbertvannobelen/kube-gcp-deployment

# Current version notes

This version contains a set of unused software due to the switch out of CRI-O with Docker. This switch out was done due to an incompatibility between CRI-O/runc and the GCE cloud provider settings: Network does not initialize:
- CNI step is skipped with CRI-O while the step is not skipped when using Docker
- And CNI step is required since GCE API server config seems to always want to control the network bridge, thus leading to duplicate/incorrect routes when controlling the network in a different fashion.

# TODO

Current script paves nodes from scratch. This is a bit slow:
- Add image creation step for worker;
- Initialize workers from above image instead.
- Add intelligent node scaler
- Add other k8s components like prometheus and fluentd
- Add multi cluster in single Google Cloud project setup
