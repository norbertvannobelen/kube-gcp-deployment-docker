#!/bin/bash
# 
# The worker needs a reboot to make certain everything starts OK. It is however possible that a previous step is not yet finished:
# Check for wget and apt-get to see if they are finished

while [ `ps -ef | grep "apt-get" | grep -v grep| wc -l` -ne 0 ]
do
  echo "waiting for apt-get to finish"
  sleep 1
done

systemctl daemon-reload
systemctl enable docker

shutdown -r -t 0 now
