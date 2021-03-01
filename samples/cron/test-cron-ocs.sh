#!/bin/bash

# This script may be relocated to the parent directory of ocs-upi-kvm project and
# edited to invoke a different sequence.  Sometimes to comment a line of execution
# to avoid recreating the cluster and other times to invoke ocs-ci with different
# parameters.  This script is relocatable, so the project itself is not modified.


# These environment variables are required for all platforms

export PLATFORM=${PLATFORM:="kvm"}                              # Also supported: powervs.   Defaults to kvm

#export RHID_USERNAME=<your rh subscription id>
#export RHID_PASSWORD=<your rh subscription password>


# These environment variables are optional, but should be set for cron jobs,
# so that CLUSTER_ID_PREFIX below is properly initialized for powervs.

export OCP_VERSION=4.6						# 4.5 - 4.7 are supported
export OCS_VERSION=4.6


# These are optional for KVM.  Default values are shown

#export IMAGES_PATH=/var/lib/libvirt/images			# File system space is important.  Else try /home/libvirt/images
#export BASTION_IMAGE=rhel-8.2-update-2-ppc64le-kvm.qcow2
#if [ -z "$DATA_DISK_LIST" ]; then				# if not set, then file backed disks are used
#       export DATA_DISK_LIST="sdc1,sdd1,sde1"			# Each worker node requires a dedicated disk partition
#       export FORCE_DISK_PARTITION_WIPE=true			# Default is false
#fi


# These environments variables are required for PowerVS

#export PVS_API_KEY=<your key>
#export PVS_SERVICE_INSTANCE_ID=<your instance id>              # Click eye icon on the left of IBM CLoud resource list, copy GUID field


# These are optional for PowerVS.  Default values are shown

export CLUSTER_ID_PREFIX=${HOSTNAME:0:5}-${OCP_VERSION/./}
#export PVS_SUBNET_NAME=ocp-net
#export PVS_REGION=lon					        # Or tok and tok04 depending on service instance id
#export PVS_ZONE=lon06
#export SYSTEM_TYPE=s922
#export PROCESSOR_TYPE=shared
#export BASTION_IMAGE=rhel-83-02182021

##############  MAIN ################

get_latest_ocs=false
nargs=$#
i=1
while (( $i<=$nargs ))
do
	arg=$1
	case "$arg" in
	--latest-ocs)
		get_latest_ocs=true
		shift 1
		;;
	*)
		echo "Usage: $0 [ --latest-ocs ]"
		echo
		echo "Use --latest-ocs to pull the latest commit from the ocsi-ci GH repo"
		echo
		echo "See README for description of required environment variables"
		exit 1
	esac
	(( i++ ))
done

if [ -z "$PLATFORM" ] || [ -z "$RHID_USERNAME" ] || [ -z "$RHID_PASSWORD" ]; then
	echo "Environment variables PLATFORM, RHID_USERNAME, RHID_PASSWORD must be set"
	exit 1
fi
if [ "$PLATFORM" == powervs ]; then
	if [ -z "$PVS_API_KEY" ] || [ -z "$PVS_SERVICE_INSTANCE_ID" ]; then
		echo "Environment variables PVS_API_KEY and PVS_SERVICE_INSTANCE_ID must be set for PowerVS"
		exit 1
	fi
	OCP_PROJECT=ocp4-upi-powervs
else
	OCP_PROJECT=ocp4-upi-kvm
fi

# LOG variables are supposed to be preset by cronjob

if [ -z "$LOGDIR" ]; then
	LOGDIR=~/logs
	mkdir -p $LOGDIR
	LOGDATE=$(date "+%d%H%M")
fi

# Set WORKSPACE where go code, binaries, and log files are placed

if [ -z "$WORKSPACE" ]; then
	cwdir=$(pwd)
	cmdpath=$(dirname $0)
	if [ "$cmdpath" == "." ]; then
		if [ -d ocs-upi-kvm ]; then
			export WORKSPACE=$cwdir
		else
			export WORKSPACE=$cwdir/../..
		fi
	elif [[ "$cmdpath" =~ "ocs-upi-kvm/samples" ]]; then
		export WORKSPACE=$cwdir/$cmdpath/../..
	elif [[ "$cmdpath" =~ "samples" ]]; then
		export WORKSPACE=$cwdir/..
	elif [ -d ocs-upi-kvm ]; then
		export WORKSPACE=$cwdir
	else
		echo "Could not find ocs-upi-kvm directory"
		exit 1
	fi
fi

echo "Location of project: $WORKSPACE/ocs-upi-kvm" | tee $LOGDIR/create-ocp-$LOGDATE.log
echo "Location of log files: $WORKSPACE" | tee -a $LOGDIR/create-ocp-$LOGDATE.log

pushd $WORKSPACE/ocs-upi-kvm

if [ ! -e src/$OCP_PROJECT/var.tfvars ]; then
	echo "Refreshing submodule ${OCP_PROJECT}..." | tee -a $LOGDIR/create-ocp-$LOGDATE.log
	git submodule update --init src/$OCP_PROJECT | tee -a $LOGDIR/create-ocp-$LOGDATE.log
fi

if [ ! -e src/ocs-ci/README.md ]; then
	echo "Refreshing submodule ocs-ci..." | tee -a $LOGDIR/create-ocp-$LOGDATE.log
	git submodule update --init src/ocs-ci | tee -a $LOGDIR/create-ocp-$LOGDATE.log
fi

if [ "$get_latest_ocs" == true ]; then
	echo "Getting latest ocs-ci..." | tee -a $LOGDIR/create-ocp-$LOGDATE.log
	pushd $WORKSPACE/ocs-upi-kvm/src/ocs-ci
	git checkout master
	git pull
	echo "Most recent commits to master:" | tee -a $LOGDIR/create-ocp-$LOGDATE.log
	git log --pretty=oneline | head -n 5 | tee -a $LOGDIR/create-ocp-$LOGDATE.log
	popd
fi

pushd $WORKSPACE/ocs-upi-kvm/scripts

set -o pipefail

# Recreate the cluster for each test.  A failed test may compromise cluster health

for i in 1 2 4a 4b 4c 3
do
	echo "Invoking ./create-ocp.sh" | tee -a $LOGDIR/create-ocp-$i-$LOGDATE.log
	./create-ocp.sh 2>&1 | tee -a $LOGDIR/create-ocp-$i-$LOGDATE.log
	if [ "$?" != 0 ] && [ "$PLATFORM" == powervs ]; then

		echo "Retrying ./create-ocp.sh" | tee -a $LOGDIR/create-ocp-$i-$LOGDATE.log

                ./create-ocp.sh --retry 2>&1 | tee -a $LOGDIR/create-ocp-$i-$LOGDATE.log
		if [ "$?" != 0 ]; then

			./destroy-ocp.sh --tier $i | tee $LOGDIR/destroy-ocp-$i-$LOGDATE.log
			if [ "$?" != 0 ] && [ "$PLATFORM" == powervs ]; then
				echo "ERROR: cluster destroy failed.  Use cloud GUI to remove virtual instances" | tee -a $LOGDIR/destroy-ocp-$i-$LOGDATE.log
			fi
			continue
		fi
	fi

	source $WORKSPACE/env-ocp.sh
	oc get nodes -o wide 2>&1 | tee -a $LOGDIR/create-ocp-$i-$LOGDATE.log

	echo "Invoking ./setup-ocs-ci.sh"
	./setup-ocs-ci.sh 2>&1 | tee $LOGDIR/setup-ocs-ci-$i-$LOGDATE.log

	echo "Invoking ./deploy-ocs-ci.sh"
	./deploy-ocs-ci.sh 2>&1 | tee $LOGDIR/deploy-ocs-ci-$i-$LOGDATE.log

	echo "Post deploy check of OCS Ceph Health"
	CEPH_STATE=$(oc get cephcluster --namespace openshift-storage | tee -a $LOGDIR/deploy-ocs-ci-$i-$LOGDATE.log)
	if [[ ! "$CEPH_STATE" =~ HEALTH_OK ]]; then

		./destroy-ocp.sh --tier $i | tee $LOGDIR/destroy-ocp-$i-$LOGDATE.log
		if [ "$?" != 0 ] && [ "$PLATFORM" == powervs ]; then
			echo "ERROR: cluster destroy failed.  Use cloud GUI to remove virtual instances" | tee -a $LOGDIR/destroy-ocp-$i-$LOGDATE.log
		fi
		continue
	fi

	echo "Invoking ./test-ocs-ci.sh --tier $i"
	./test-ocs-ci.sh --tier $i | tee $LOGDIR/test-ocs-ci-tier-$i-$LOGDATE.log

	echo
	oc get cephcluster --namespace openshift-storage 2>&1 | tee -a $LOGDIR/test-ocs-ci-tier-$i-$LOGDATE.log
	echo
	oc get pods --namespace openshift-storage 2>&1 | tee -a $LOGDIR/test-ocs-ci-tier-$i-$LOGDATE.log

	echo "Invoking ./destroy-ocp.sh after tier test $i"
	./destroy-ocp.sh --tier $i | tee $LOGDIR/destroy-ocp-$i-$LOGDATE.log
	if [ "$?" != 0 ] && [ "$PLATFORM" == powervs ]; then
		echo "ERROR: cluster destroy failed.  Use cloud GUI to remove virtual instances" | tee -a $LOGDIR/destroy-ocp-$i-$LOGDATE.log
	fi

done
