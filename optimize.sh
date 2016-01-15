#!/bin/bash

set -e
set +a

TOOLS_DIR=/tmp/ec2tools
EC2_HOME=${TOOLS_DIR}

# Source the profile to ensure that JAVA_HOME is set
. $( cd $( dirname -- "$0" ) > /dev/null ; pwd )/common.sh

# Prepare the overall OS for imaging. Most of these steps are read-only or at
# least fully idempotent. They're all about preparing the host, checking and
# filling in environment variables, etc.
install_apt_deps curl unzip rsync grub kpartx gdisk
install_aws_deps
install_rsc
validate_environment
discover_instance_info
discover_rightscale_info
generate_grub_menu

# Hack: Fixes intermediate "SSL certificate problem" errors from curl
# See https://forums.aws.amazon.com/thread.jspa?messageID=341463&#341463
dry_exec "update-ca-certificates 2>&1 > /dev/null"

# Purge all RightScale RightLink state
clean_rightlink_state

# Here we actually create the image (or snapshot), upload it to Amazon and
# register it as an AMI image.
if test "$IMAGE_TYPE" = "EBS"; then
  # EBS-backed images are generated from EBS Snapshots, then registered as
  # AMIs. Support for that will come soon.
  error "No EBS support yet."
else
  # S3-backed images are snapshotted locally, uploaded to S3 and then
  # registered with Amazon as AMIs.
  generate_bundle
  upload_bundle
  register_bundle
fi

# Now go off an start doing rightscaley stuff
rightscale_update_next_instance_href

clean
