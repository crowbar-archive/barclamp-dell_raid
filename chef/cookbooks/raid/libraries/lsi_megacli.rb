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
# Author: andi abes
#


require File.join(File.dirname(__FILE__), 'raid_data')

class Crowbar
  class RAID
    class LSI_MegaCli < Crowbar::RAID


      ## require modprobe mptsas
      CMD = '/opt/MegaRAID/MegaCli/MegaCli64'
      @@vol_re = /Virtual Drive:\s*(\d+)\s*\(Target Id:\s*(\d+)\)/
      @@disk_re = /PD:\s*(\d+)\s*Information/

      def find_controller
	## adpCount sets the return code to 0 if no controller is found
	begin
	  run_tool(["-adpCount"])
	  return nil
	rescue
	  ## we have a controller... return it's ID
	end
	@cntrl_id = 0
      end

      def describe
	"MegaCLi controllers"
      end

      ## load curent RAID info - volumes and disk info
      def load_info
	phys_disks = run_tool(["-PDlist"])
	@disks,dummy = parse_dev_info(phys_disks)
	vols = run_tool(["-ldpdinfo"])
	@volumes = parse_volumes(vols)
      end

      def create_volume(type, name, disk_ids, max_size )
	## build up the command...
	text = ""
	cmd = []
	case type.intern
	  when :RAID0,:RAID1
	  cmd = ["-CfgLdAdd"]
	  array_type =  type.intern == :RAID0 ? "-r0" : "-r1"
	  cmd << "#{array_type}[ #{disk_ids.join(',')} ]"
	  # size is specified in megabytes
	  cmd << "-sz#{max_size/MEGA}MB"  unless max_size.nil?

	  when :RAID10
	  cmd = ["-CfgSpanAdd", "-r10" ]
	  disk_cnt = disk_ids.length
	  disk_cnt = disk_cnt -1 if disk_cnt % 2 >0  # can't use odd #.
	  span_cnt = disk_cnt/2
	   (1.. span_cnt).each { |x|
	    cmd <<  "-array#{x}[#{disk_ids[0]}, #{disk_ids[1]} ]"
	    disk_ids.shift
	    disk_ids.shift
	  }

	  # size is specified in megabytes
	  cmd << "-sz#{max_size/MEGA}" unless max_size.nil?

	  when :JBOD
	  # will create a separate volume for each drive
	  cmd = ["-CfgEachDskRaid0"]
	else
	  raise "unknown raid level requested: #{type}"
	end

	run_tool(cmd)
      rescue
	log("create returned: #{text}", :ERROR)
	raise
      end

      def delete_volume(id)
	text = ""
	run_tool(["-CfgLdDel", "-L#{id}"])
      rescue
	log("delete returned: #{text}", :ERROR)
	raise
      end

      ###
      # check if the config has a default of jbod (which is represented as
      # lots of raid0 single drive volumes)
      def adjust_config(config, del, miss, keep)
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
	if !config["default"].nil? and
	  config["default"]["raid_level"].intern == :JBOD and
	  disks_avail.length > 0
	  run_tool(["-CfgEachDskRaid0"])
	end
      end

      def set_boot
	self.load_info
	#### set a bood drive.
	## - If there is any kind of volume info, pick first volume
	if !@volumes.nil? and !@volumes[0].nil?
	  bootVol = @volumes[0].vol_id
	  log("Will use boot volume:#{bootVol}")
	  run_tool(["-adpBootDrive", "-set" , "-l#{bootVol}"])
	elsif !@disks.nil? and !@disks[0].nil?
	  boot =@disks[0].to_s
	  log("Will use boot disk: #{boot}")
	  run_tool(["-adpBootDrive", "-set" , "-physdrv[#{boot}]"])
	else
	  log("not changing boot drive.. not enough info")
	end

      end



=begin
  Parse information about available pyhsical devices.
  The method expects to parse the output of:
  MegaCli64 -PDlist -aAll
=end
      def parse_dev_info(lines)
	devs = []
	span_count = 0
	begin
	  rd = Crowbar::RAID::RaidDisk.new
	  skipped = skip_to_find lines,/Enclosure Device ID:/  # find a disk
	  break if lines.length ==0
	  span_count = span_count+1 if skipped.join("").match(/Span: \d* - Number of PDs: \d*/).nil?
	  enclosure = extract_value lines[0]
	  rd.enclosure = Integer(enclosure) rescue nil
	  skip_to_find lines,/Slot Number/
	  rd.slot = extract_value lines[0]
	  skip_to_find lines, /Raw Size:/  ## Raw Size: 419.186 GB [0x3465f870 Sectors]
	  size = extract_value(lines[0])
	  rd.size = Integer(/.*\[(.*) .*\]/.match(size)[1]) * 512 ## sector count * 512 byte sector
	  log(" disk: #{rd.enclosure} / #{rd.slot} :size #{rd.size} bytes")
	  devs << rd
	end while lines.length > 0
	return [devs,span_count]
      end



=begin
  Break the output into "stanzas"- one for each volume, and
  pass the buck down to the volume parsing method.

  The method expects the output of:
  MegaCli64 -ldpdinfo -aAll
=end
      def parse_volumes(lines)
	vols = []
	txt = save = ""
	# find first volume
	skip_to_find lines, @@vol_re
	begin
	  # find the next one, to "bracket"the volume
	  save = lines.shift if lines.length > 0
	  txt = skip_to_find lines, @@vol_re
	  next if txt.length ==0  # no more info
	  vols << parse_vol_info([ save ] + txt)
	end while txt.length > 0
	vols
      end

=begin
  Parse info about one volume
=end

      def parse_vol_info(lines)
	rv = Crowbar::RAID::Volume.new
	skip_to_find lines, @@vol_re
	return if lines.length ==0 and log("no more info")
	## MegaCli doesn't give volumes names.. use the target ID as the na
	rv.vol_id, rv.vol_name = @@vol_re.match(lines[0])[1,2]
	log ("volume id: #{rv.vol_id} #{rv.vol_name}")
	skip_to_find lines, /RAID Level/
	raid_level = extract_value lines[0]
	rv.members,span_cnt = parse_dev_info(lines)
	log("found volume with #{rv.members.length} drives and #{span_cnt} spans ")
	case raid_level
	  when /Primary-0, Secondary-0/
	  rv.raid_level = :RAID0

	  when /Primary-1, Secondary-0/
	  if span_cnt ==1
	    rv.raid_level= :RAID1
	  else
	   rv.raid_level= :RAID10
	  end
	end
	rv
      end

      def run_tool(args, &block)
	cmd = [CMD, *args]
	cmd << "-a#{@cntrl_id}" unless @cntrl_id.nil?
	cmdline = cmd.join(" ")
	run_command(cmdline, &block)
      end
    end
  end
end


if __FILE__ == $0
  require 'lsi_ircu'
  require 'lsi_megacli'
  $in_chef = false

  puts "will try #{Crowbar::RAID.controller_styles.join(" ")}"
  Crowbar::RAID.controller_styles.each { |c|
    puts("trying #{c}")
    @raid = c.new
    test = @raid.find_controller
    if !test.nil?
      puts("using #{c} ")
      break
    end
    @raid = nil # nil out if it didn't take
  }
  puts "no controller " if @raid.nil?

  t = @raid #Crowbar::RAID::LSI_MegaCli.new
  t.load_info
  puts(t.describe_volumes)
  puts(t.describe_disks)
  t.volumes.each { |x| t.delete_volume(x.vol_id)}

  disk_ids = t.disks.map{ |d| "#{d.enclosure}:#{d.slot}"}
  puts "sleeping for a bit"
  sleep 10
  t.create_volume(:RAID10, "dummy", [disk_ids[0]])

end
