# Author: cary@rightscale.com
# Copyright 2014 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'image_bundle/image_bundle_ec2'

module RightScale

  # Handles the snapshoting and registration of EBS based images
  #
  class ImageBundleEc2EBS < ImageBundleEc2

    def snapshot_instance(name=nil, description=nil)

      # find root volume
      #
      root_volume = nil
      begin
        device_name = "/dev/sda"
        @log.info "Locating root volume attached to #{device_name}..."
        attachment = instance.volume_attachments.index.select { |va| va.device =~ /#{device_name}/ }.first
        root_volume = attachment.volume
        @attachment_device = attachment.device
        @log.info "Found volume #{root_volume.show.name} attached at #{@attachment_device}"
      rescue Exception => e
        fail("FATAL: cannot find root volume. Check device_name which can vary depending on hypervisor and/or kernel. Also instance-store images not currently supported.", e)
      end

      # create snapshot
      @log.info "Creating snapshot of server."
      options = { :parent_volume_href => root_volume.href }
      options.merge!(:name => name) if name
      options.merge!(:description => description) if description
      snapshot = @instance_client.volume_snapshots.create(:volume_snapshot => options)
      @log.info "Snapshot name '#{name}'" if name

      # wait for snapshot to complete
      @log.info "Waiting for snapshot to become available"
      current_state = snapshot.show.state
      delay_sec = 10
      Timeout::timeout(RETRY_TIMEOUT_SEC) do
        while current_state != "available" do
          @log.info "  snapshot state: #{current_state}. try again in #{delay_sec} seconds..."
          sleep delay_sec
          current_state = snapshot.show.state
        end
      end
      @log.info "Snapshot is now available"
      @snapshot_id = snapshot.show.resource_uid
    end

    def register_command(name=nil, description=nil)
      unless @snapshot_id
        fail("@snapshot_id cannot be nil. Be sure to run snapshot_instance first.")
      end

      # use ec2 tools to register snapshot as an image
      # TODO: this command only maps in 4 ephemeral devices to the new image. Use metadata to get actual count.
      cmd = "ec2-register --region #{region} --virtualization-type #{virtualization_type} --snapshot #{@snapshot_id} --description '#{@image_description}' --block-device-mapping '/dev/sdb=ephemeral0' --block-device-mapping '/dev/sdc=ephemeral1' --block-device-mapping '/dev/sdd=ephemeral2' --block-device-mapping '/dev/sde=ephemeral3' #{kernel_aki} --root-device-name #{@attachment_device} --architecture x86_64 --name '#{name}' "
      cmd
    end

  end

end
