#/bin/sh
#
# This is just a utility package -- meant to store a few useful functions that
# may be used by multiple scripts in this repo.
#
# Usage:
#   #!/bin/sh
#   . $( cd $( dirname -- "$0" ) > /dev/null ; pwd )/common.sh
#   <call_some_func>
#

VERSION=0.1.0
set -e

# Common variables that apply to every function in this file -- these will be
# explained to the user when this common.sh script is imported. No need to add
# them to your own help/documentation.
DRY=${DRY:-1}
VERBOSE=${VERBOSE:-0}
RSC_BIN=${RSC_BIN:-/usr/local/bin/rsc}
TEMP_DIR=$(mktemp -d)
CERT_PATH=${TEMP_DIR}/x509.pem
KEY_PATH=${TEMP_DIR}/x509.key
ARCH=$(uname --hardware-platform)

# install_aws_deps()
export EC2_HOME=${EC2_HOME:-/tmp/ec2}
export PATH=${EC2_HOME}/bin:${PATH}

# Image settings
IMAGE_BUNDLE_DIR=${IMAGE_BUNDLE_DIR:-/mnt/tmp/bundle}
IMAGE_EXCLUDES="${TEMP_DIR},/mnt"
IMAGE_PREFIX=${IMAGE_PREFIX:-cached}
IMAGE_NAME=${IMAGE_NAME:-$(hostname)}
IMAGE_STAMP=$(date +%Y-%m-%d-%H-%M-%S)
FULL_IMAGE_NAME=$(echo ${IMAGE_PREFIX}-${IMAGE_NAME}-${IMAGE_STAMP} | sed 's/[^A-Za-z0-9\-]//g')
IMAGE_DESCRIPTION=${IMAGE_DESCRIPTION:-$FULL_IMAGE_NAME}

# Stupid simple logger methods that wrap our log messages with some
# useful information.
error() { echo "ERROR: $@" 1>&2; exit 1; }
warn() { echo "WARN:  $@" 1>&2; }
info()  { echo "INFO:  $@"; }
debug() { if test 1 -eq $VERBOSE; then echo "DEBUG: $@"; fi }
dry_exec() {
  if test $DRY -eq 1; then
    info "Would have run: $@"
  else
    info "Running: $@"
    eval $@
  fi
}
pushd() { command pushd "$@" > /dev/null; }
popd() { command popd "$@" > /dev/null; }


# Clean out the RightLink agent state so on a fresh boot it works properly as a
# new host.
#
clean_rightlink_state() {
  info "Cleaning out the RightLink agent state and config"
  dry_exec "rm -rf /var/spool/cloud /var/lib/rightscale/right_link/*.js"
  dry_exec "rm -rf /opt/rightscale/var/lib/monit/monit.state"
  dry_exec "rm -rf /opt/rightscale/var/run/monit.pid"
  dry_exec "rm -rf /root/.ssh /root/.gem"
  dry_exec "find /var/log -type f -exec /bin/bash -c \"cat /dev/null > {}\" \;"

  dry_exec "apt-cache gencaches"
  dry_exec "mandb --create"
  dry_exec "service postfix stop && rm -rf /var/mail/*"
  dry_exec "service ntp stop && rm -rf /var/lib/ntp/ntp.drift"
  sync
}

# Clean up any temporary files/etc
#
# Expects:
#   TEMP_DIR
#   IMAGE_BUNDLE_DIR
#
clean() {
  test -d "$TEMP_DIR" && rm -rf "$TEMP_DIR"
  test -d "$IMAGE_BUNDLE_DIR" && rm -rf "$IMAGE_BUNDLE_DIR"
}

# Installs any missing apt-dependencies
#
# Args:
#  List of packages to install
#
install_apt_deps() {
  for dep in $@; do
    debug "Checking if $dep is installed..."
    if ! dpkg -s $dep > /dev/null 2>&1; then
      info "Package $dep is missing... will install it."
      missing="${dep} ${missing}"
    fi
  done

  # If no packages are missing, then exit this function
  if ! test "$missing"; then return; fi

  # Install the Apt dependencies now
  apt-get -qq update || warn "apt-get update failed ... attempting package install anyways"
  dry_exec apt-get -qq install $missing
}

# Installs the Amazon tools
#
# Expects:
#   EC2_HOME: The final destination for the tools
#   TEMP_DIR: Temporary workspace for downlaoding and unzipping the tools
install_aws_deps() {
  if ! test -d $EC2_HOME/bin; then
    debug "Creating $EC2_HOME and installing the AMI/API tools..."
    dry_exec mkdir -p $EC2_HOME
    pushd $TEMP_DIR
    dry_exec curl --location --silent -O http://s3.amazonaws.com/ec2-downloads/ec2-api-tools.zip
    dry_exec curl --location --silent -O http://s3.amazonaws.com/ec2-downloads/ec2-ami-tools.zip
    dry_exec unzip -qq ec2-api-tools.zip
    dry_exec unzip -qq ec2-ami-tools.zip
    dry_exec rsync -a --no-o --no-g ec2-*/ ${EC2_HOME}/
    popd
  fi

  # patch the ami tools to NOT purge .pem or .gpg files
  #
  # https://forums.aws.amazon.com/message.jspa?messageID=291999
  info "Patching AWS AMI tools to not purge .gpg/.pem files"
  dry_exec "sed -i.bak -E '/^.*(\*\.gpg|\*\.pem).*$/d' $EC2_HOME/lib/ec2/platform/base/constants.rb"
}

# Installs the RightScale toolkit
#
# Expects:
#   TEMP_DIR
#   RSC_BIN
#   RS_ACCOUNT
#   RIGHTSCALE_API_EMAIL
#   RIGHTSCALE_API_PASS
#   RS_SERVER
#
# Sets:
#   RSC_API_CMD
#   RSC_INST_CMD
#
install_rsc() {
  if ! test -e "$RSC_BIN"; then
    debug "Downloading the RightScale RSC toolkit to $RSC_BIN"
    pushd $TEMP_DIR
    dry_exec "rm -rf rsc"
    dry_exec "curl --silent --location https://binaries.rightscale.com/rsbin/rsc/v5/rsc-linux-amd64.tgz | tar -zx --strip-components 1"
    dry_exec "chmod +x rsc && cp -f rsc ${RSC_BIN}"
    popd
  fi

  if test -f "/var/spool/cloud/user-data.sh"; then
    . /var/spool/cloud/user-data.sh
    RS_API_TOKEN=$(echo $RS_API_TOKEN | awk -F: '{print $2}')
    info "RS_ACCOUNT: ${RS_ACCOUNT}"

    RSC_API_CMD="${RSC_BIN} --config ${TEMP_DIR}/.rsc"
    RSC_INST_CMD="${RSC_BIN} --account $RS_ACCOUNT --apiToken $RS_API_TOKEN --host $RS_SERVER"

  elif pgrep rightlink > /dev/null 2>&1; then
    RSC_API_CMD="${RSC_BIN} --config ${TEMP_DIR}/.rsc"
    RSC_INST_CMD="${RSC_BIN} --rl10"

    # Supplied by RL10 during runtime
    RS_ACCOUNT=$account
    RS_SERVER=$api_hostname
  else
    error "No RightScale user-data.sh script found."
  fi

  info "RSC_API_CMD: ${RSC_API_CMD}"
  info "RSC_INST_CMD: ${RSC_INST_CMD}"

  rm -f ${TEMP_DIR}/.rsc
  echo "${RS_ACCOUNT}
${RIGHTSCALE_API_EMAIL}
${RIGHTSCALE_API_PASS}
${RS_SERVER}" | $RSC_API_CMD setup

}

# Discovers a bunch of information about the instance itself that will be
# necessary later.
#
# Sets:
#   INSTANCE_ID
#   EC2_PLACEMENT_AVAILABILITY_ZONE
#   EC2_REGION
#   EC2_KERNEL_ID
#   VIRTUALIZATION
#   IMAGE_TYPE
#
discover_instance_info() {
  debug "Auto-detecting Amazon Instance information"
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  EC2_PLACEMENT_AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
  EC2_REGION=$(echo ${EC2_PLACEMENT_AVAILABILITY_ZONE} | sed 's/[a-z]$//')

  if test "$EC2_REGION" = "us-east-1"; then
    S3_URL=https://s3.amazonaws.com
  else
    S3_URL=https://s3-${EC2_REGION}.amazonaws.com
  fi

  info "--- Auto-detected Amazon Instance Info ---"
  info "INSTANCE_ID: ${INSTANCE_ID}"
  info "ROOT_DEVICE: ${ROOT_DEVICE}"
  info "EC2_PLACEMENT_AVAILABILITY_ZONE: ${EC2_PLACEMENT_AVAILABILITY_ZONE}"
  info "EC2_REGION: ${EC2_REGION}"
  info "S3_URL: ${S3_URL}"

  # If KERNEL comes back with a value, then this is a PV
  # instance ... if it comes back empty, its an HVM instance.
  export KERNEL=$(curl --fail -s http://169.254.169.254/latest/meta-data/kernel-id/)
  if test -z "$KERNEL"; then
    VIRTUALIZATION=hvm
    unset EC2_KERNEL_ID
    info "EC2_KERNEL_ID: None"
  else
    VIRTUALIZATION=paravirtual
    EC2_KERNEL_ID=$KERNEL
    info "EC2_KERNEL_ID: ${EC2_KERNEL_ID}"
  fi
  info "VIRTUALIZATION: ${VIRTUALIZATION}"

  # Auto-discover whether we're an EBS image or not
  if test "$(curl -s http://169.254.169.254/latest/meta-data/ami-manifest-path/)" = "(unknown)"; then
    export IMAGE_TYPE=EBS
  else
    export IMAGE_TYPE=S3
  fi
  info "IMAGE_TYPE: ${IMAGE_TYPE}"
}

# Discover the rightscale system information used to configure the RSC client
#
# Sets:
#   RS_SERVER
#   RS_API_TOKEN
#   RS_ACCOUNT
#   RS_ARRAY_HREF
#   RS_CLOUD_HREF
#
discover_rightscale_info() {
  # Use the instance-level credentials to discover information about our parent server array.
  RS_ARRAY_HREF=$(${RSC_INST_CMD} --x1 'object:has(.rel:val("parent")).href' cm15 index_instance_session sessions/instance)
  RS_CLOUD_HREF=$(${RSC_INST_CMD} --x1 'object:has(.rel:val("cloud")).href' cm15 index_instance_session sessions/instance)

  # TODO: Support operating on severs not just arrays.
  if test -z "$RS_ARRAY_HREF"; then
    error "Operating on non-array instances not supported at this time."
  fi

  # Now really we care about the next_instance -- thats what we want to update.
  RS_NEXT_INSTANCE_HREF=$(${RSC_API_CMD} --x1 'object:has(.rel:val("next_instance")).href' cm15 show ${RS_ARRAY_HREF})

  info "RS_ARRAY_HREF: ${RS_ARRAY_HREF}"
  info "RS_NEXT_INSTANCE_HREF: ${RS_NEXT_INSTANCE_HREF}"
  info "RS_CLOUD_HREF: ${RS_CLOUD_HREF}"
}

# Discover a list of our ephemeral -- instance store -- drives.
#
# Sets:
#   EPHEMERAL_PARTITIONS: A space-separated list of local ephemeral drives.
#
discover_ephemeral_partitions() {
  METAURL="http://169.254.169.254/2012-01-12/meta-data/block-device-mapping/"
  if test "$EPHEMERAL_PARTITIONS"; then
    info "Using user-supplied local cache volumes: ${EPHEMERAL_PARTITIONS}"
    return
  fi

  for BD in $(curl -s $METAURL | grep ephemeral); do
    SD=$(curl -s ${METAURL}${BD})
    XD=$(echo $SD | sed 's/sd/xvd/')
    DEV=/dev/${XD}
    EPHEMERAL_PARTITIONS="${DEV} ${EPHEMERAL_PARTITIONS}"
  done
}

# Generate the ec2-bundle-vol arguments based on the parameters discovered on
# the system.
#
# Expects:
#   EC2_KERNEL_ID
#   KEY_PATH
#   CERT_PATH
#   ARCH
#   IMAGE_BUNDLE_DIR
#   IMAGE_EXCLUDES
#   ROOT_DEVICE
#
generate_bundle() {
  debug "Generating ec2-bundle-vol command arguments..."
  EC2_BUNDLE_ARGS="--privatekey ${KEY_PATH} --cert ${CERT_PATH}"
  EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --user ${AWS_ACCOUNT_NUMBER}"
  EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --arch ${ARCH}"
  EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --destination ${IMAGE_BUNDLE_DIR}"
  EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --no-inherit"
  EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --exclude \"${IMAGE_EXCLUDES}\""

  if test "$VIRTUALIZATION" = "hvm"; then
    EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --partition mbr"
    EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} -B 'ami=sda,root=/dev/sda,ephemeral0=sdb,ephemeral1=sdc,ephemeral2=sdd,ephemeral3=sde'"
  else
    EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} --kernel ${EC2_KERNEL_ID}"
    EC2_BUNDLE_ARGS="${EC2_BUNDLE_ARGS} -B 'ami=sda,root=/dev/sda,ephemeral0=sdb,swap=sda3'"
  fi

  # TODO: Do we ened this for HVM? or not?
  # --partition mbr \

  dry_exec "rm -rf ${IMAGE_BUNDLE_DIR}; mkdir -p ${IMAGE_BUNDLE_DIR}"
  dry_exec "ec2-bundle-vol ${EC2_BUNDLE_ARGS}"
}

# Uploads the bundle created in the generate_bundle() step above
#
# Expects:
#   IMAGE_BUCKET
#   IMAGE_NAME
#   AWS_ACCESS_KEY
#   AWS_SECRET_KEY
#   EC2_REGION
#   S3_URL
#
# Sets:
#   AMI_ID
#
upload_bundle() {
  debug "Generating ec2-upload-bundle command arguments..."
  EC2_UPLOAD_ARGS="--bucket \"${IMAGE_BUCKET}/image_bundles/${FULL_IMAGE_NAME}\""
  EC2_UPLOAD_ARGS="${EC2_UPLOAD_ARGS} --manifest ${IMAGE_BUNDLE_DIR}/image.manifest.xml"
  EC2_UPLOAD_ARGS="${EC2_UPLOAD_ARGS} --access-key ${AWS_ACCESS_KEY}"
  EC2_UPLOAD_ARGS="${EC2_UPLOAD_ARGS} --secret-key ${AWS_SECRET_KEY}"
  EC2_UPLOAD_ARGS="${EC2_UPLOAD_ARGS} --url ${S3_URL}"
  EC2_UPLOAD_ARGS="${EC2_UPLOAD_ARGS} --retry --batch --region ${EC2_REGION}"

  dry_exec "ec2-upload-bundle ${EC2_UPLOAD_ARGS}"
}

# Registers the uploaded (to S3) bundle and stores the AMI ID
#
register_bundle() {
  debug "Generating ec2-register-bundle command arguments..."
  EC2_REGISTER_ARGS="--region ${EC2_REGION}"
  EC2_REGISTER_ARGS="${EC2_REGISTER_ARGS} --name \"${FULL_IMAGE_NAME}\""
  EC2_REGISTER_ARGS="${EC2_REGISTER_ARGS} --virtualization-type ${VIRTUALIZATION}"
  EC2_REGISTER_ARGS="${EC2_REGISTER_ARGS} --description \"${IMAGE_DESCRIPTION}\""
  EC2_REGISTER_ARGS="${EC2_REGISTER_ARGS} --architecture ${ARCH}"

  if test "$IMAGE_TYPE" = "EBS"; then
    error "Not supported."
  else
    EC2_REGISTER_ARGS="${IMAGE_BUCKET}/image_bundles/${FULL_IMAGE_NAME}/image.manifest.xml ${EC2_REGISTER_ARGS}"
  fi

  if test $DRY -eq 1; then
    dry_exec "ec2-register ${EC2_REGISTER_ARGS}"
    warn "Setting FAKE AMI_ID variable for the rest of the DRY run."
    AMI_ID=FAKE-AMI-IMAGE
  else
    AMI_ID=$(ec2-register ${EC2_REGISTER_ARGS} | grep ami | awk '{print $2}')
    if test -z "$AMI_ID"; then error "Something went wrong in the AMI registration."; fi
  fi

  info "AMI Successfully Registered: ${AMI_ID}"
}

# Generate a missing /boot/grub/menu.lst file
#
# This can be missing, if the grub-legacy-ec2 package is missing.
#
generate_grub_menu() {
  if ! test -f "/boot/grub/menu.lst"; then
    dry_exec "update-grub -y"
  fi

  # If we're an HVM instance, we need to patch the Grub boot loader
  #
  # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/
  # creating-an-ami-instance-store.html#creating-ami-linux-instance
  if test "$VIRTUALIZATION" = "hvm"; then
    info "Image is HVM-based, adding in some grub console tweaks"
    dry_exec "sed -i 's/console=hvc0/console=ttyS0/' /boot/grub/menu.lst"
    dry_exec "sed -i 's/xen_emul_unplug=unnecessary//' /boot/grub/menu.lst"
    dry_exec "sed -i 's/consoleblank=0//' /boot/grub/menu.lst"
    dry_exec "sed -i '/^kernel/ s/$/ consoleblank=0 xen_emul_unplug=unnecessary/' /boot/grub/menu.lst"
    dry_exec "sed -i 's/LABEL=UEFI.*//' /etc/fstab"
  fi
}

# Searches RightScale for the AMI_ID that we hae built (and waits until
# RightScale has discovered it), then updates the "next_instance" of the
# ServerArray that we are working with to use this AMI directly on boot.
#
# Expects:
#   AMI_ID
#   RSC_API_CMD
#   RS_NEXT_INSTANCE_HREF
#
# Sets:
#   RS_IMAGE_HREF
#
rightscale_update_next_instance_href() {

  while true; do
    info "Searching RightScale for ${AMI_ID}..."
    RS_IMAGE_HREF_OUTPUT=$(${RSC_API_CMD} cm15 index ${RS_CLOUD_HREF}/images "filter[]=resource_uid==${AMI_ID}")
    if test "$RS_IMAGE_HREF_OUTPUT"; then
      #RS_IMAGE_HREF=$(echo ${RS_IMAGE_OUTPUT} | ${RSC_BIN} json --x1 'object:has(.rel:val("self")).href')
      RS_IMAGE_HREF=$(${RSC_API_CMD} --x1 'object:has(.rel:val("self")).href' cm15 index ${RS_CLOUD_HREF}/images "filter[]=resource_uid==${AMI_ID}")
      info "RightScale ${RS_IMAGE_HREF} points to ${AMI_ID}"
      break
    fi
    sleep 10
  done 

  dry_exec "${RSC_API_CMD} cm15 update ${RS_NEXT_INSTANCE_HREF} instance[image_href]=${RS_IMAGE_HREF}"
}


# Validate whether all of the credentials that are necessary are installed in
# the right places.
#
# Expects:
#   AWS_ACCESS_KEY
#   AWS_SECRET_KEY
#   AWS_X509_KEY
#   AWS_X509_CERT
#
validate_environment() {
  debug "Validating the environment variables are all supplied" 
  test "$AWS_ACCESS_KEY" || error "AWS_ACCESS_KEY is missing!"
  test "$AWS_SECRET_KEY" || error "AWS_SECRET_KEY is missing!"
  test "$AWS_ACCOUNT_NUMBER" || error "AWS_ACCOUNT_NUMBER is missing!"

  test "$AWS_X509_KEY" || error "AWS_X509_KEY is missing!"
  test "$AWS_X509_CERT" || error "AWS_X509_CERT is missing!"

  test "$IMAGE_BUCKET" || error "IMAGE_BUCKET is missing!"

  test "$RIGHTSCALE_API_EMAIL" || error "RIGHTSCALE_API_EMAIL is missing!"
  test "$RIGHTSCALE_API_PASS" || error "RIGHTSCALE_API_PASS is missing!"

  info "Creating X509 Key: $KEY_PATH"
  cat <<EOF >$KEY_PATH
$AWS_X509_KEY
EOF
  info "Creating X509 Cert: $CERT_PATH"
  cat <<EOF >$CERT_PATH
$AWS_X509_CERT
EOF
}

# Just mention that we were loaded up!
info "Image Optimization Script Functions (v${VERSION}) loaded!"
info ""
info "The following settings can be overridden by setting environment variables."
info ""
info "The parameters below may or may not be used, depending on your environment:"
info "-----------"
info "ARCH                    = ${ARCH}"
info "CERT_PATH               = ${CERT_PATH}"
info "DRY                     = ${DRY}"
info "EC2_HOME                = ${EC2_HOME}"
info "IMAGE_BUCKET            = ${IMAGE_BUCKET}"
info "IMAGE_DESCRIPTION       = ${IMAGE_DESCRIPTION}"
info "IMAGE_EXCLUDES          = ${IMAGE_EXCLUDES}"
info "IMAGE_PREFIX            = ${IMAGE_PREFIX}"
info "KEY_PATH                = ${KEY_PATH}"
info "RSC_BIN                 = ${RSC_BIN}"
info "TEMP_DIR                = ${TEMP_DIR}"
info "IMAGE_BUNDLE_DIR        = ${IMAGE_BUNDLE_DIR}"
info "FULL_IMAGE_NAME         = ${FULL_IMAGE_NAME}"
info "VERBOSE                 = ${VERBOSE}"
info "-----------"
info ""
