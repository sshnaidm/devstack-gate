#!/bin/bash

# Script that is run on the devstack vm; configures and
# invokes devstack.

# Copyright (C) 2011-2012 OpenStack LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit

cd $DEST/devstack

rm -f localrc

ENABLED_SERVICES=g-api,g-reg,key,n-api,n-crt,n-obj,n-cpu,n-sch,horizon,mysql,rabbit

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    ENABLED_SERVICES=$ENABLED_SERVICES,tempest
fi

if [ "$ZUUL_BRANCH" == "stable/diablo" ]; then
    export DEVSTACK_GATE_TEMPEST=0
fi

SKIP_EXERCISES=boot_from_volume,client-env

if [ "$ZUUL_BRANCH" == "stable/diablo" ] ||
   [ "$ZUUL_BRANCH" == "stable/essex" ]; then
    ENABLED_SERVICES=$ENABLED_SERVICES,n-vol,n-net
    SKIP_EXERCISES=$SKIP_EXERCISES,swift
elif [ "$ZUUL_BRANCH" == "stable/folsom" ]; then
    ENABLED_SERVICES=$ENABLED_SERVICES,n-net,swift
    if [ "$DEVSTACK_GATE_CINDER" -eq "1" ]; then
	ENABLED_SERVICES=$ENABLED_SERVICES,cinder,c-api,c-vol,c-sch
    else
	ENABLED_SERVICES=$ENABLED_SERVICES,n-vol
    fi
else # master
    ENABLED_SERVICES=$ENABLED_SERVICES,swift,cinder,c-api,c-vol,c-sch
    if [ "$DEVSTACK_GATE_QUANTUM" -eq "1" ]; then
	ENABLED_SERVICES=$ENABLED_SERVICES,quantum,q-svc,q-agt,q-dhcp,q-l3
    else
	ENABLED_SERVICES=$ENABLED_SERVICES,n-net
    fi
fi

cat <<EOF >>localrc
ACTIVE_TIMEOUT=60
BOOT_TIMEOUT=90
ASSOCIATE_TIMEOUT=60
TERMINATE_TIMEOUT=60
MYSQL_PASSWORD=secret
RABBIT_PASSWORD=secret
ADMIN_PASSWORD=secret
SERVICE_PASSWORD=secret
SERVICE_TOKEN=111222333444
SWIFT_HASH=1234123412341234
ROOTSLEEP=0
ERROR_ON_CLONE=True
ENABLED_SERVICES=$ENABLED_SERVICES
SKIP_EXERCISES=$SKIP_EXERCISES
SERVICE_HOST=127.0.0.1
SYSLOG=True
SCREEN_LOGDIR=$DEST/screen-logs
LOGFILE=$DEST/devstacklog.txt
VERBOSE=True
FIXED_RANGE=10.1.0.0/24
FIXED_NETWORK_SIZE=256
VIRT_DRIVER=$DEVSTACK_GATE_VIRT_DRIVER
SWIFT_REPLICAS=1
export OS_NO_CACHE=True
EOF

if [ "$DEVSTACK_GATE_VIRT_DRIVER" == "openvz" ]; then
   cat <<\EOF >>localrc
SKIP_EXERCISES=${SKIP_EXERCISES},volumes
DEFAULT_INSTANCE_TYPE=m1.small
DEFAULT_INSTANCE_USER=root
EOF

if [ "$DEVSTACK_CINDER_SECURE_DELETE" -eq "0" ]; then
   cat <<\EOF >>localrc
CINDER_SECURE_DELETE=False
EOF
fi

   cat <<EOF >>exerciserc
DEFAULT_INSTANCE_TYPE=m1.small
DEFAULT_INSTANCE_USER=root
EOF
fi

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    # We need to disable ratelimiting when running
    # Tempest tests since so many requests are executed
    echo "API_RATE_LIMIT=False" >> localrc
    # Volume tests in Tempest require a number of volumes
    # to be created, each of 1G size. Devstack's default
    # volume backing file size is 2G, so we increase to 4G
    echo "VOLUME_BACKING_FILE_SIZE=4G" >> localrc
fi

# Make the workspace owned by the stack user
sudo chown -R stack:stack $DEST

echo "Running devstack"
sudo -H -u stack ./stack.sh

echo "Removing sudo privileges for devstack user"
sudo rm /etc/sudoers.d/50_stack_sh

echo "Running devstack exercises"
sudo -H -u stack ./exercise.sh

if [ "$DEVSTACK_GATE_TEMPEST" -eq "1" ]; then
    echo "Configuring tempest"
    sudo -H -u stack ./tools/configure_tempest.sh
    cd $DEST/tempest
    echo "Running tempest smoke tests"
    sudo -H -u stack NOSE_XUNIT_FILE=nosetests-smoke.xml nosetests --with-xunit -sv --nologcapture --attr=type=smoke tempest
    RETVAL=$?
    if [[ $RETVAL = 0 && "$DEVSTACK_GATE_TEMPEST_FULL" -eq "1" ]]; then
      echo "Running tempest full test suite"
      sudo -H -u stack NOSE_XUNIT_FILE=nosetests-full.xml nosetests --with-xunit -sv --nologcapture -a '!smoke' tempest
    fi
else
    # Jenkins expects at least one nosetests file.  If we're not running
    # tempest, then write a fake one that indicates the tests pass (since
    # we made it past exercise.sh.
    cat > $WORKSPACE/nosetests-fake.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?><testsuite name="nosetests" tests="0" errors="0" failures="0" skip="0"></testsuite>
EOF
fi
