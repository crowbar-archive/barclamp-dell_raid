#!/c/Ruby187/bin/ruby
#
# Copyright 2011, Dell
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
# Author: David Paterson
#

require 'rubygems'
require 'pp'
 
require File.join(File.dirname(__FILE__), 'raid_data')

ENUMERATE_CMD = 'enumerate'
INVOKE_CMD = 'invoke' 
GET_CMD = 'get'
CHANGE_BOOT_ORDER_CMD = 'ChangeBootOrderByInstanceID'
CONVERT_TO_RAID_CMD = "ConvertToRAID" 

WSMAN_BASE_URI = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim" 
LC_SERVICE_URI = "#{WSMAN_BASE_URI}/DCIM_LCService?SystemCreationClassName=DCIM_ComputerSystem,CreationClassName=DCIM_LCService,SystemName=DCIM:ComputerSystem,Name=DCIM:LCService"
INVOKE_RAID_SERVICE_URI = "#{WSMAN_BASE_URI}/DCIM_RAIDService?SystemCreationClassName=DCIM_ComputerSystem,CreationClassName=DCIM_RAIDService,SystemName=DCIM:ComputerSystem,Name=DCIM:RAIDService"
INVOKE_BIOS_SERVICE_URI = "#{WSMAN_BASE_URI}/DCIM_BIOSService?SystemCreationClassName=DCIM_ComputerSystem,CreationClassName=DCIM_BIOSService,SystemName=DCIM:ComputerSystem,Name=DCIM:BIOSService"
INVOKE_LC_SERVICE_URI =   "#{WSMAN_BASE_URI}/DCIM_LCService?SystemCreationClassName=DCIM_ComputerSystem,CreationClassName=DCIM_LCService,SystemName=DCIM:ComputerSystem,Name=DCIM:LCService"
INVOKE_BOOT_CONFIG_URI =  "#{WSMAN_BASE_URI}/DCIM_BootConfigSetting?InstanceID="

LIFECYCLE_JOB_URI = "http://schemas.dell.com/wbem/wscim/1/cim-schema/2/DCIM_LifecycleJob"

LC_STATUS_READY="Ready"
RETURN_VAL_OK = '0'
RETURN_CONFIG_VAL_OK = '4096'
RETURN_VAL_FAIL = '2'
RETURN_VAL_NO_ACTION = '-1'


CSIOR_ATTR="Collect System Inventory on Restart"
CSIOR_ATTR_URI = "#{WSMAN_BASE_URI}/DCIM_LCEnumeration?InstanceID=DCIM_LCEnumeration:CCR5"

SPAN_LENGTH = 2

RAID0_VAL = '2'
RAID1_VAL = '4'
RAID10_VAL = '2048'


class Crowbar
  class RAID
    class WsManCli < Crowbar::RAID
      
     
      def initialize(node)
        require 'wsman'
        $in_chef = true
        user = node[:ipmi][:bmc_user]
        password = node[:ipmi][:bmc_password]
        #host = node["crowbar"]["network"]["bmc"]["address"]
        host = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "bmc").address
        opts = { :user => user, :password => password, :host => host, :port => 443, :debug_time => true }
        wsman = Crowbar::WSMAN.new(opts) 
        @wsman = wsman
        @xml = XML_UTIL.new
        @node = node
      end
      
      def wait_until_lc_ready()
        lc_ready = is_lc_ready()
        until (lc_ready)
          sleep 10;
          lc_ready = is_lc_ready()
        end   
      end
      
      def is_lc_ready()
        return rss_status() == LC_STATUS_READY 
      end
      
      def rss_status() 
        sub_cmd = "GetRSStatus"
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        output = @wsman.command(cmd, LC_SERVICE_URI)
        status = @xml.processResponse(output,'["Body"]["GetRSStatus_OUTPUT"]["Status"]')
        log "rss_status returning: #{status}."
        status
      end
      
      
      def job_status(job_id)
        log("job_status, job_id: #{job_id}.")
        url = "#{LIFECYCLE_JOB_URI}?InstanceID=#{job_id}"
        xml = @wsman.command(GET_CMD, url)
        percent_complete = @xml.processResponse(xml,'["Body"]["DCIM_LifecycleJob"]["PercentComplete"]')
        percent_complete
      end
      
      def find_controller
        log("find_controller.")
        url = "#{WSMAN_BASE_URI}/DCIM_ControllerView"
        begin
          xml = @wsman.command(ENUMERATE_CMD, url)
          fqdd = @xml.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_ControllerView"]["FQDD"]')
          @fqdd = fqdd;
          fqdd;
        rescue Exception => e
          log("Unable to retrieve controller id via wsman, exception: #{e.message}", :ERROR)
          nil
        end
      end
      
      def physical_disks
        log("physical_disks.")
        url = "#{WSMAN_BASE_URI}/DCIM_PhysicalDiskView"
        xml = @wsman.command(ENUMERATE_CMD, url, " -m 512")
        phys_disks = @xml.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_PhysicalDiskView"]')
        return (phys_disks.nil?)?nil:parse_dev_info(phys_disks)
      end
      
      def parse_dev_info(phys_disks)
        phys_disks = (phys_disks.instance_of?(Array))?phys_disks:[phys_disks]
        devs = []
        
        unless phys_disks.nil? 
          phys_disks.each do |disk| 
            rd = Crowbar::RAID::RaidDisk.new
            rd.disk_id = disk['FQDD']
            rd.enclosure = 0 # need to look into this,  WSMAN doesn't treat enclosures as integer values but FQDDs
            rd.slot =  disk['Slot'].to_i      
            rd.size =  disk['SizeInBytes'].to_i  
            devs << rd
          end
        end  
        devs
      end
      
      def boot_source_settings()
        log("boot_source_settings.")
        url = "#{WSMAN_BASE_URI}/DCIM_BootSourceSetting"
        xml = @wsman.command(ENUMERATE_CMD, url, "-m 512")
        bss = @xml.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_BootSourceSetting"]')   
        bss
      end
      
      def raid_pd_states()
        log("raid_pd_states.")
        url = "#{WSMAN_BASE_URI}/DCIM_RAIDEnumeration"
        xml = @wsman.command(ENUMERATE_CMD, url, "-m 512")
        re = @xml.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_RAIDEnumeration"]')  
        raidPds = Array.new 
        re.each do |re| 
         raidPds << re if re['AttributeName']=='RAIDPDState'
        end
        raidPds
      end
      
        
      def virtual_disks
        log("virtual_disks.")
        url = "#{WSMAN_BASE_URI}/DCIM_VirtualDiskView"
        xml = @wsman.command(ENUMERATE_CMD, url, "-m 512")
        virt_disks = @xml.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_VirtualDiskView"]')   
        return (virt_disks.nil?)?nil:parse_volumes(virt_disks)
      end
      
    def parse_volumes(virt_disks)
      log("parse_volumes.")
      virt_disks = (virt_disks.instance_of?(Array))?virt_disks:[virt_disks]
      vols = []    
      
      unless virt_disks.nil? 
        virt_disks.each do |vdisk| 
          rv = Crowbar::RAID::Volume. new()
          rv.vol_id = vdisk["FQDD"]
          rv.vol_name = vdisk["Name"]
          rv.members = disks_by_id(vdisk["PhysicalDiskIDs"])
          raid_level = Integer(vdisk["RAIDTypes"])
          
          case raid_level
            when 2
            rv.raid_level = :RAID0
            when 4
            rv.raid_level = :RAID1
            when 64
            rv.raid_level = :RAID5
            when 2048
            rv.raid_level = :RAID10
            when 8192
            rv.raid_level = :RAID50
          else
            rv.raid_level = :RAIDNONE
          end
          vols << rv
        end
      end  
      vols
    end
    
    def disks_by_id(disk_ids)
      disks = []
      unless disk_ids.nil? || @disks.nil?
        disk_ids.each do |disk_id|
          disks << disk_by_id(disk_id)
        end
      end
      disks
    end
    
    def disk_by_id(disk_id)
      disk = nil
      unless @disks.nil?
        @disks.each do |pd|
          disk = pd if disk_id == pd.disk_id
        end
      end
      disk
    end
      

      def available_disks()
        log("available_disks.") 
        sub_cmd = "GetAvailableDisks"
        inputFile = "/tmp/#{sub_cmd}.xml"
        File.open("#{inputFile}", "w+") do |f|
          f.write %Q[
          <p:GetAvailableDisks_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
              <p:Target>#{@fqdd}</p:Target>
              <p:DiskType>0</p:DiskType>
              <p:Diskprotocol>0</p:Diskprotocol>
              <p:DiskEncrypt>0</p:DiskEncrypt>
           </p:GetAvailableDisks_INPUT>
          ]
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        output = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
        pd_array = @xml.processResponse(output,'["Body"]["GetAvailableDisks_OUTPUT"]["PDArray"]')
        return (pd_array.nil?)?nil:disks_by_id(pd_array)
      end
      
      def load_raid_levels(fqdd, availableDisks)
        log "load_raid_levels for: #{fqdd}."
        
        # generate the PDArray
        pdArray=""
        availableDisks.each do |diskFqdd|
          pdArray += "<p:PDArray>#{diskFqdd}</p:PDArray>"
        end
        
        sub_cmd = "GetRAIDLevels"
        inputFile = "/tmp/#{sub_cmd}.xml"
        File.open("#{inputFile}", "w+") do |f|
          f.write %Q[
          <p:GetRAIDLevels_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
            <p:Target>#{fqdd}</p:Target>
            <p:DiskType>0</p:DiskType>
            <p:Diskprotocol>0</p:Diskprotocol>
            <p:DiskEncrypt>0</p:DiskEncrypt>
            #{pdArray}
          </p:GetRAIDLevels_INPUT>
          ]
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        output = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
        raid_enum = @xml.processResponse(output,'["Body"]["GetRAIDLevels_OUTPUT"]["VDRAIDEnumArray"]')
        raid_enum
      end
      
      def check_vd_values(fqdd, availableDisks, raidLevel="2048")
        log "check_vd_values for: #{fqdd}."
        
        # generate the PDArray
        pdArray=""
        availableDisks.each do |diskFqdd|
          pdArray += "<p:PDArray>#{diskFqdd}</p:PDArray>"
        end
        
        sub_cmd = "CheckVDValues"
        inputFile = "/tmp/#{sub_cmd}.xml"
        File.open("#{inputFile}", "w+") do |f|
          f.write %Q[
          <p:CheckVDValues_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
            <p:Target>#{fqdd}</p:Target>
            #{pdArray}
            <p:VDPropNameArrayIn>RAIDLevel</p:VDPropNameArrayIn>
            <p:VDPropValueArrayIn>#{raidLevel}</p:VDPropValueArrayIn>
          </p:CheckVDValues_INPUT>
          ]
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        output = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
        keys = @xml.processResponse(output,'["Body"]["CheckVDValues_OUTPUT"]["VDPropNameArray"]')
        vals = @xml.processResponse(output,'["Body"]["CheckVDValues_OUTPUT"]["VDPropValueArray"]')
        return Hash[keys.zip(vals)]
      end
      
      
      
      def describe
        "WSMAN RAID driver"
      end
      
      ## load curent RAID info - volumes and disk info
      
      
      def load_info
        log "load_info."
        wait_until_lc_ready()
        @disks = physical_disks()
        @volumes = virtual_disks()
        @bootSourceSettings = boot_source_settings()
        @raidPdStates = raid_pd_states()
        
        #  @available = available_disks()
      end   
      
     
      
      def create_raid_config_job(count=0)
        log("create_raid_config_job.")
        wait_until_lc_ready()
        sub_cmd = "CreateTargetedConfigJob"
        inputFile = "/tmp/#{sub_cmd}_RAID.xml"
        File.open("#{inputFile}", "w+") do |ff|
          ff.write %Q[
            <p:CreateTargetedConfigJob_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
             <p:Target>#{@fqdd}</p:Target>
             <p:RebootJobType>1</p:RebootJobType>
             <p:ScheduledStartTime>TIME_NOW</p:ScheduledStartTime>
            </p:CreateTargetedConfigJob_INPUT>
          ] 
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
        #check returnValue
        returnVal = @xml.returnValue(xml,sub_cmd)
        
        if returnVal == RETURN_CONFIG_VAL_OK
          RETURN_CONFIG_VAL_OK
        else
          response = @xml.processResponse(xml,'["Body"]["CreateTargetedConfigJob_OUTPUT"]')
          raise "Could not create raid config job, response: #{response}"
          RETURN_VAL_FAIL
        end
      end
      
      def create_bios_config_job(count=0)
        log("create_bios_config_job.")
        wait_until_lc_ready()
        sub_cmd = "CreateTargetedConfigJob"
        inputFile = "/tmp/#{sub_cmd}_BIOS.xml"
        File.open("#{inputFile}", "w+") do |ff|
          ff.write %Q[
               <p:CreateTargetedConfigJob_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BIOSService">
                 <p:Target>BIOS.Setup.1-1</p:Target>
                 <p:RebootJobType>1</p:RebootJobType>
                 <p:ScheduledStartTime>TIME_NOW</p:ScheduledStartTime>
                 <p:UntilTime>20121111111111</p:UntilTime>
               </p:CreateTargetedConfigJob_INPUT>
          ] 
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        xml = @wsman.command(cmd, INVOKE_BIOS_SERVICE_URI, "-J #{inputFile}")
        returnVal = @xml.returnValue(xml,sub_cmd)
        
        if returnVal == RETURN_CONFIG_VAL_OK
          return RETURN_CONFIG_VAL_OK
        else
          response = @xml.processResponse(xml,'["Body"]["CreateTargetedConfigJob_OUTPUT"]')
          raise "Could not create bios config job, response: #{response.inspect}"
          return RETURN_VAL_FAIL
          
        end
      end
      
      def delete_pending_config() # call this prior to create config job if you want to backout changes.
        log "delete_pending_config."
        wait_until_lc_ready()
        sub_cmd = "DeletePendingConfiguration"
        inputFile = "/tmp/#{sub_cmd}_RAID.xml"
        File.open("#{inputFile}", "w+") do |ff|
          ff.write %Q[
            <p:DeletePendingConfiguration_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
                <p:Target>#{@fqdd}</p:Target>
             </p:DeletePendingConfiguration_INPUT>
          ] 
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
        #check returnValue
        returnVal = @xml.returnValue(xml,sub_cmd)
        return returnVal
    end
    
=begin
       Ideally I would have liked to call check_vd_values and have it return the params I should use but 
        it didn't work out, many attribute errors with no trace from WSMAN.
        #generate properties array code
         propArray = ""
        vd_values.each do |key, value|
          propArray +="<p:VDPropNameArrayIn>#{key}</p:VDPropNameArrayIn>\n<p:VDPropValueArrayIn>#{value}</p:VDPropValueArrayIn>"
        end 
=end      
      def create_volume(raid_level, name, disks, max_size)
        
        log("create_volume, raid_level: #{raid_level}.")  
        convert_to_raid(disks) unless @raidPdStates.nil? || @raidPdStates.size == 0
        sub_cmd = "CreateVirtualDisk" 
        inputFile = "/tmp/#{sub_cmd}.xml"
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        
        spanDepth = disks.length
        returnVal = nil;
        begin
          case raid_level.intern
            when :RAID0
            create_volume_input_file(inputFile, name, disks, RAID0_VAL, disks.length, 1, max_size)
            xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
            returnVal = @xml.returnValue(xml,sub_cmd)

            when :RAID1
            spanDepth = disks.length/SPAN_LENGTH
            create_volume_input_file(inputFile, name, disks, RAID1_VAL, spanDepth, SPAN_LENGTH, max_size)
            xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
            returnVal = @xml.returnValue(xml,sub_cmd)

            when :RAID10
            spanDepth = disks.length/SPAN_LENGTH
            create_volume_input_file(inputFile, name, disks, RAID10_VAL, spanDepth, SPAN_LENGTH, max_size)
            xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
            returnVal = @xml.returnValue(xml,sub_cmd)

            when :JBOD 
            disks.each do |disk|
              create_volume_input_file(inputFile, name, [disk], RAID0_VAL, 1, 1, max_size)
              xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
              returnVal = @xml.returnValue(xml,sub_cmd)
              break unless returnVal == RETURN_VAL_OK
            end
            
          else
            raise "unknown raid level requested: #{raid_level}" 
          end
          
          if returnVal==RETURN_VAL_OK
            RETURN_VAL_OK
          else #return the error
            raise "failed create volume, response: #{@xml.processResponse(xml,'["Body"]["CreateVirtualDisk_OUTPUT"]')}" 
          end
        rescue Exception => e
          log("Create volume failed, reason: #{e.message}", :ERROR)
          delete_pending_config()
          RETURN_VAL_FAIL
        end 
      end

      def convert_to_raid(disks)
        log("convert_to_raid.")  
        toRaid = Array.new

        disks.each do |disk|
          @raidPdStates.each do |pd|
            if pd['FQDD'] == disk.disk_id && pd['CurrentValue']=='Non-RAID'
             toRaid << disk
            end
          end
        end
        return RETURN_VAL_NO_ACTION unless toRaid.size != 0
        
        begin
          cmd  = "#{INVOKE_CMD} -a #{CONVERT_TO_RAID_CMD}"
          create_ctr_input_file(toRaid)
          xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J /tmp/#{CONVERT_TO_RAID_CMD}.xml")
          log(xml.inspect)
          returnVal = @xml.returnValue(xml,CONVERT_TO_RAID_CMD)
          return create_raid_config_job() unless returnVal != RETURN_VAL_OK
        rescue Exception => e
          log("convert to raid failed, reason: #{e.message}", :ERROR)
          delete_pending_config()
          RETURN_VAL_FAIL
        end
      end
      
      def create_ctr_input_file(disks)
        pdArray=""
        disks.each do |disk|
          pdArray += "<p:PDArray>#{disk.disk_id}</p:PDArray>"
        end

        File.open("/tmp/#{CONVERT_TO_RAID_CMD}.xml", "w+") do |f|
          f.write %Q[
          <p:ConvertToRAID_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
            #{pdArray}
          </p:ConvertToRAID_INPUT>
          ]
        end
      end
      
      
      def create_volume_input_file(path, name, disks, raid_level, span_depth, span_length, max_size)
        pdArray="" 
        disks.each do |disk|
          pdArray += "<p:PDArray>#{disk.disk_id}</p:PDArray>" 
        end
        
        sizeProp = ""
        sizeVal = ""
        isJBOD = (raid_level==RAID0_VAL && span_depth==1 && span_length==1)
        if (not isJBOD and max_size)
          sizeProp = "<p:VDPropNameArray>Size</p:VDPropNameArray>"
          sizeVal = "<p:VDPropValueArray>#{max_size/MEGA}</p:VDPropValueArray>"
        end
        
        File.open("#{path}", "w+") do |f|
          f.write %Q[
          <p:CreateVirtualDisk_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
            <p:Target>#{@fqdd}</p:Target>
            #{pdArray}
            <p:VDPropNameArray>VirtualDiskName</p:VDPropNameArray>
            <p:VDPropNameArray>RAIDLevel</p:VDPropNameArray>
            <p:VDPropNameArray>SpanDepth</p:VDPropNameArray> 
            <p:VDPropNameArray>SpanLength</p:VDPropNameArray>
            #{sizeProp}
            <p:VDPropValueArray>#{name}</p:VDPropValueArray>
            <p:VDPropValueArray>#{raid_level}</p:VDPropValueArray>
            <p:VDPropValueArray>#{span_depth}</p:VDPropValueArray>
            <p:VDPropValueArray>#{span_length}</p:VDPropValueArray>
            #{sizeVal}
          </p:CreateVirtualDisk_INPUT>
          ]
          end
      end
      
      def delete_volume(volume_id)
        log("delete_volume.")
        begin
          sub_cmd = "DeleteVirtualDisk"
          inputFile = "/tmp/#{sub_cmd}.xml"
          File.open("#{inputFile}", "w+") do |f|
            f.write %Q[
          <p:#{sub_cmd}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
            <p:Target>#{volume_id}</p:Target>
          </p:#{sub_cmd}_INPUT>
          ]
          end
          
          cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
          xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
          returnVal = @xml.returnValue(xml,sub_cmd)
          raise "DeleteVirtualDisk call failed with return code: #{returnVal}" if returnVal.nil? || returnVal != RETURN_VAL_OK
          RETURN_VAL_OK
        rescue Exception => e 
          log("Failed deleting volume, exception: #{e.message}", :ERROR)
          delete_pending_config()
          RETURN_VAL_FAIL # failure code.
        end
      end
      
      def delete_all_volumes()
        log "delete_all_volumes."
        sub_cmd = "DeleteVirtualDisk"
        inputFile = "/tmp/#{sub_cmd}.xml"
        unless (@volumes.nil?)
          @volumes.each do |vd| 
            begin
              
              File.open("#{inputFile}", "w+") do |f|
                f.write %Q[
                 <p:#{sub_cmd}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_RAIDService">
                   <p:Target>#{vd.vol_id}</p:Target>
                 </p:#{sub_cmd}_INPUT>
                 ]
              end
              
              cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
              xml = @wsman.command(cmd, INVOKE_RAID_SERVICE_URI, "-J #{inputFile}")
              returnVal = @xml.returnValue(xml,sub_cmd)
              raise "DeleteVirtualDisk call failed with return code: #{returnVal}" if returnVal.nil? || returnVal != RETURN_VAL_OK
            rescue
              return delete_pending_config()
            end
          end  
          return create_raid_config_job()
        end
        return RETURN_VAL_OK
      end
      
      ###
      # check if the config has a default of jbod (which is represented as 
      # lots of raid0 single drive volumes)
      def adjust_config(config, del, miss, keep)
        del={} unless !del.nil?
        log("no default") and return if config["default"].nil?         
        log("not JBOD") and return unless config["default"]["raid_level"].intern == :JBOD
        
        # we're doing jbod. check if we have lots of single drive volumes
        # that we are planning on deleteing, and keep them
        should_keep= {}
        should_add= {}
        del.each { |x| 
          if x.raid_level == :RAID0 and x.members.length==1
            should_keep[x.vol_id] =x             
          end
        } 
        log("adjusted for these vols:#{should_keep.keys.join(' ')}")
        should_keep.values.each { |x| keep << x }        
        del.delete_if { |x| !should_keep[x.vol_id].nil? }
        miss.delete_if { |x| !should_keep[x.vol_id].nil? }
        
      end
      
      def apply_default(config, disks_avail)
        if (!config["default"].nil? and config["default"]["raid_level"].intern == :JBOD and disks_avail.length > 0)
          returnVal = create_volume(config["default"]["raid_level"], nil, disks_avail, disks_avail.length)
          if returnVal==RETURN_VAL_OK
            RETURN_VAL_OK
          else #return the error
            raise "apply_default failed response code: #{returnVal}" 
            RETURN_VAL_FAIL
          end
        end
      end
      
      def set_boot()
        log("set_boot.")
        if (@bootSourceSettings.nil? || @bootSourceSettings.length == 0)
          log("set_boot, no boot source settings found, cannot set boot order")
          return RETURN_VAL_FAIL
        end

        cmd  = "#{INVOKE_CMD} -a #{CHANGE_BOOT_ORDER_CMD}"
        iid=nil;
        url=nil;
        returnVal= RETURN_VAL_NO_ACTION;
        # check all types, IPL, BCV UEFI
        begin
        # IPL: Network first
          @bootSourceSettings.each do |bss|
            if((bss['InstanceID'].start_with?('IPL:NIC.Embedded.1-1') || (bss['InstanceID'].start_with?('IPL:') && bss['InstanceID'].include?('NIC.Integrated.1-1'))) && !(bss['CurrentAssignedSequence'] =='0' && bss['CurrentEnabledStatus'] =='1'))
              log("set_boot, IPL Network boot was not set to index 0, setting now..")
              iid = bss['InstanceID']
              url = "#{INVOKE_BOOT_CONFIG_URI}IPL"
              inputFile = "/tmp/#{CHANGE_BOOT_ORDER_CMD}_IPL.xml"
              writeBootSourceFile(inputFile, iid)
              xml = @wsman.command(cmd,url , "-J #{inputFile}")
              returnVal = @xml.returnValue(xml,CHANGE_BOOT_ORDER_CMD)
            break
            end
          end
=begin  for now we are not dealing with UEFI and sticking with legacy boot sources.
          @bootSourceSettings.each do |bss|
            if(bss['InstanceID'].start_with?('UEFI:NIC.Embedded.1-1') && !(bss['CurrentAssignedSequence'] =='0' && bss['CurrentEnabledStatus'] =='1'))
              log("set_boot, UEFI Network boot was not set to index 0, setting now..")
              iid = bss['InstanceID']
              url = "#{INVOKE_BOOT_CONFIG_URI}UEFI"
              inputFile = "/tmp/#{CHANGE_BOOT_ORDER_CMD}_UEFI.xml"
              writeBootSourceFile(inputFile, iid)
              xml = @wsman.command(cmd,url , "-J #{inputFile}")
              returnVal = @xml.returnValue(xml,CHANGE_BOOT_ORDER_CMD)
            break
            end
          end
=end
          # BCV.  Set raid controller if there are any volumes.
          if (!@volumes.nil? && @volumes.length !=0)
            @bootSourceSettings.each do |bss|
              if(bss['InstanceID'].start_with?('BCV:') && bss['InstanceID'].include?(@fqdd) && !(bss['CurrentAssignedSequence'] =='0' && bss['CurrentEnabledStatus'] =='1'))
                log("set_boot, BCV RAID controller was not set to boot index 0, setting now..")
                iid = bss['InstanceID']
                url = "#{INVOKE_BOOT_CONFIG_URI}BCV"
                writeBootSourceFile(inputFile, iid)
                xml = @wsman.command(cmd,url , "-J #{inputFile}")
                returnVal = @xml.returnValue(xml,CHANGE_BOOT_ORDER_CMD)
              break
              end
            end
          end
          raise "ChangeBootOrderByInstanceID call failed with return code: #{returnVal}" unless returnVal == RETURN_VAL_NO_ACTION || returnVal == RETURN_VAL_OK
        rescue Exception => e
          log("Failed setting boot, exception: #{e.message}", :ERROR)
          delete_pending_config()
          return RETURN_VAL_FAIL # failure code.
        end
        returnVal
      end
       
      
      def writeBootSourceFile(inputFile, instanceId)
        File.open("#{inputFile}", "w+") do |f|
              f.write %Q[
                 <p:#{CHANGE_BOOT_ORDER_CMD}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BootConfigSetting"> 
                   <p:source>#{instanceId}</p:source> 
                 </p:#{CHANGE_BOOT_ORDER_CMD}_INPUT>
                 ]
            end
        true
      end    
      
      def config_csior()
        if !is_csior_enabled()
          returnVal = enable_csior()
          if returnVal == RETURN_VAL_OK
             create_bios_config_job()
             sleep()
          end
        end 
      end
      
      
      def is_csior_enabled()
        log "check_csior_enabled."
        xml = @wsman.command(GET_CMD, CSIOR_ATTR_URI)
        returnVal = @xml.processResponse(xml,'["Body"]["DCIM_LCEnumeration"]["CurrentValue"]')
        return !returnVal.nil? && returnVal=="Enabled"
      end
      
      def enable_csior()
        log "enable_csior."
        wait_until_lc_ready()
        sub_cmd = "SetAttribute"
        inputFile = "/tmp/#{sub_cmd}_LC.xml"
        File.open("#{inputFile}", "w+") do |ff|
          ff.write %Q[
            <p:SetAttribute_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_LCService">
              <p:AttributeName>#{CSIOR_ATTR}</p:AttributeName>
              <p:AttributeValue>Disabled</p:AttributeValue>
            </p:SetAttribute_INPUT>
          ] 
        end
        
        cmd  = "#{INVOKE_CMD} -a #{sub_cmd}"
        xml = @wsman.command(cmd, INVOKE_LC_SERVICE_URI, "-J #{inputFile}")
        #check returnValue
        returnVal = @xml.returnValue(xml,sub_cmd)
        log "enable_csior return val is: #{returnVal}"
        return returnVal
        
      end

      def cleanup_test()
        log "cleanup."
        load_info()
        if (!@volumes.nil? && @volumes.length !=0)
          returnVal = delete_all_volumes()
          if(RETURN_VAL_OK==returnVal)
            job_id = create_raid_config_job()
            if job_id[0,4]!="JID_"
              log "Error creating config job: #{job_id}"
              exit
            else
              percent_complete = ""
              until percent_complete == "100"
                percent_complete = job_status(job_id)
                log "delete volumes job status percent complete: #{percent_complete}" 
                sleep 5;
              end
              log "Delete all volumes done!!!!"
            end 
          end
        end
      end
      
      def create_vd_test(raid_level,name)
        log "create_vd_test."
        log "Available Disks: #{@available.inspect}"
        if (@available.nil? || @available.length == 0)
          log "Unabled to find available disks for creating volume" 
          exit
        end
        
        returnVal = create_volume(raid_level, name, @available, 100)
        log "after create volume returnVal is: #{returnVal}" 
        if returnVal !=RETURN_VAL_OK #create VD call not successful
          log "Failed creating volume, wsman returned: #{returnVal.inspect}, deleting pending config"
          delete_pending_config()
        else
          job_id = create_raid_config_job()
          if job_id[0,4]!="JID_"
            log "Error creating config job: #{job_id}"
            exit
          else
            percent_complete = ""
            until percent_complete == "100"
              percent_complete = job_status(job_id)
              log "job status percent complete: #{percent_complete}" 
              sleep 1;
            end
            log "Create Volume Done!!!!"
          end
        end
      end
    end 
    
  end 
end

if __FILE__ == $0
  require 'wsman' 
  require 'xml_util'
  host = '192.168.124.164'
  user = 'root'
  password = 'root'
  port = 443
  debug_time = true
  
  $in_chef = false
  puts '....................... wsman_cli tester.......................'
  wsman = WSMAN.new(host, user, password, port, debug_time)
  raid = Crowbar::RAID::WsManCli.new(wsman, XML_UTIL.new)
  
  fqdd = raid.find_controller()
  raid.log "Found raid controller #{fqdd}"
  
  # raid.delete_pending_config()
  # exit
  
  # raid.load_info()
  
  # raid.available_disks(raid.fqdd)
  # raidLevels = raid.load_raid_levels(fqdd,availableDisks)
  # raid.log "RAID Levels: #{raidLevels.inspect}"
  # vd_values = raid.check_vd_values(fqdd,availableDisks,"2048")
  # raid.log "check_vd_values ret: #{vd_values.inspect}"
  raid.config_csior()
 #  raid.create_vd_test(:RAID10,"test_volumexxx")

  ## clean up
  # sleep(300)
  # raid.cleanup_test()
end
