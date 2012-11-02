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

require 'pty'
require File.join(File.dirname(__FILE__), 'raid_data')

class Crowbar
  class RAID
    class LSI_sasIrcu < Crowbar::RAID
      
      attr_accessor :disks, :volumes, :debug
      CMD = '/updates/sas2ircu'
      RAID_MAP = {
    "RAID0" => :RAID0,
    "RAID1" => :RAID1,
    "RAID1E" => :RAID1E,
    "RAID10" => :RAID10
      }  
     
      
      @@re_lines = /^-+$/
      
      
      def find_controller
        run_tool(["list"]) rescue return nil
        @cntrl_id =0  # seems that if there's just 1, it's always 0..    
      end
      
      def describe
        "sas2ircu  controllers"
      end
      
      def load_info    
        lines = run_tool(["display"])
        phyz = find_stanza lines,"Physical device information"
        logical = find_stanza lines, "IR Volume information"
        
        log("phyx ingo: \n#{phyz}",:DEBUG)
        
        @disks = parse_dev_info phyz
        @volumes = parse_vol_info logical
      end
      
      
      
=begin
Issue the command to create a RAID volue:
 The format of the CREATE command is
   sas2ircu <controller #> create <volume type> <size>
   <Encl:Bay> [Volume Name] [noprompt]
    where <controller #> is:
        A controller number between 0 and 255.
    where <volume type> is:
        The type of the volume to create and is either RAID1 (or)
        RAID1E (or) RAID0 (or) RAID10.
    where <size> is:
        The size of the volume to create. It should be given in Mbytes
        e.g. 2048 or 'MAX' to use the maximum size possible.
    where <Encl:Bay> is:
        A list of Encl:Bay pairs identifying the disk drives you
        wish to include in the volume being created. If the volume type is
        'RAID1', the first drive will be selected as the primary and the
        second as the secondary drive.
        For a type 'RAID1' volume exactly 2 disks must be specified.
        For a type 'RAID1E' volume min of 3 disks must be specified.
        For a type 'RAID0' volume min of 2 disks must be specified.
        For a type 'RAID10' volume min of 4 disks must be specified.
    where [Volume Name] is an optional argument that can be used
        to identify a Volume with a user specified Alpha-numeric string
    where noprompt is an optional argument that eliminates
        warnings and prompts

=end  
      def create_volume(type, name, disk_ids, max_size )
        ## build up the command...     
        text = ""
        size = "MAX" 
        size = max_size / MEGA unless max_size.nil?
        run_tool(["create", type.to_s, size , disk_ids, "'#{name}'","noprompt"]){ |f| 
          text = f.readlines
        }
        text.to_s.strip
      rescue
        log("create returned: #{text}", :ERROR)
        raise 
      end
      
      def delete_volume(id)
        text = ""
        run_tool(["delete", id, "noprompt"]) { |f|
          text = f.readlines
        }
      rescue
        log("delete returned: #{text}", :ERROR)
        raise 
      end
    
      def adjust_config(config,del,miss,keep)
        ### nothing to do 
      end
      def apply_default(config, disks_avail)
          ### nothing to do
      end
    
    
      def set_boot
        self.load_info
        ## set the boot volume or drive.
        ## if we have any volume, pick the first one, otherwise, first drive.
        puts(" have #{@volumes.length} vols and #{@disks.length} disks") 
         if !@volumes.nil? and !@volumes[0].nil?
          bootVol = @volumes[0].vol_id          
          log("Will use boot volume:#{bootVol}")                    
          run_tool(["bootir", "#{bootVol}"])
        elsif !@disks.nil? and !@disks[0].nil?
          boot=@disks[0].to_s 
          log("Will use boot disk: #{boot}")                    
          run_tool(["bootencl", boot])
        else
      end
 
      end
      
=begin  

IR volume 1
  Volume ID                               : 172
  Volume Name                             : crowbar-RAID1
  Status of volume                        : Okay (OKY)
  RAID level                              : RAID1
  Size (in MB)                            : 952720
  Physical hard disks                     :
  PHY[0] Enclosure#/Slot#                 : 2:10
  PHY[1] Enclosure#/Slot#                 : 2:11
=end
      
      def parse_vol_info(lines)
        vols= []
        begin
          skip_to_find lines,/^IR volume (\d+)\s*/
          break if lines.length ==0
          lines.shift
          
          rv = Crowbar::RAID::Volume.new
          rv.vol_id=extract_value(lines.shift)
          rv.vol_name =extract_value(lines.shift)
          lines.shift
          #      skip_to_find lines, /\s+RAID level\s*:\s*$/
          raid_level =extract_value(lines.shift)
          rv.raid_level=RAID_MAP[raid_level]
          
          skip_to_find lines,/\s+Physical hard disks\s*:\s*$/
          lines.shift
          disk_re = /\s+PHY.* : (\d+):(\d+)\s*$/
          begin
            rd = Crowbar::RAID::RaidDisk.new
            rd.enclosure, rd.slot = rv.name =disk_re.match(lines.shift)[1,2]
            rv.members << rd
          end while lines.length > 0 and disk_re.match(lines[0])
          vols << rv
        end while lines.length > 0      
        vols
      end
      
=begin
Parse out disk info. Needed to create raid sets (enclosure and slot)

Device is a Hard disk
  Enclosure #                             : 2
  Slot #                                  : 11
  SAS Address                             : 500065b-0-0003-0000
  State                                   : Optimal (OPT)
  Size (in MB)/(in sectors)               : 953869/1953525167
  Manufacturer                            : ATA
  Model Number                            : ST31000524NS
  Firmware Revision                       : KA05
  Serial No                               : 9WK3CWZJ
  Protocol                                : SATA
  Drive Type                              : SATA_HDD

=end
      
      def parse_dev_info(lines)
        disks = []
        begin
          skip_to_find lines,/^Device is a Hard disk\s*/
          break if lines.length ==0
          lines.shift      
          rd = Crowbar::RAID::RaidDisk.new
          rd.enclosure = extract_value(lines.shift)
          rd.slot =extract_value(lines.shift)
          skip_to_find lines, /^\s*Size /
          size = extract_value(lines.shift)
          rd.size = Integer(size.split("/")[1])*512 # use sectors
          disks<<rd      
    end while lines.length > 0
    disks    
  end
   
  
  
=begin
  Output from the LSI util is broken into stanzas delineated with something like:
------------------------------------------------------------------------
Controller information
------------------------------------------------------------------------

This method finds a stanza by name and returns an array with its content 
=end  
  
  def find_stanza(lines,name)
    lines = lines.dup
    begin
      # find a stanza mark.
      skip_to_find lines,@@re_lines
      lines.shift
      #make sure it's the right one.
    end while lines.length > 0 and  lines[0].strip.casecmp(name) != 0 
    lines.shift # skip stanza name and marker
    lines.shift
    log("start of #{name} is #{lines[0]}")
    
    #lines now starts with the right stanzs.... filter out the rest.    
    ours = skip_to_find lines,@@re_lines    
    ours    
  end
  
  
    def run_tool (args, &block)    
    cmd = [CMD]
    cmd << @cntrl_id unless @cntrl_id.nil?
    cmd = cmd + [*args]
    run_command(cmd.join(" "), &block)
  end

  
    end
  end
end




if __FILE__ == $0
  $in_chef=false
  l = Crowbar::RAID::LSI_sasIrcu.new
  l.find_controller
  l.debug = true
  l.load_info
  
  ids = l.disks[0..11].map {|x | "%s:%s" % [x.enclosure,x.slot] }.join(" ")
  l.create_volume Crowbar::RAID::RAID10, "crw-raid1e", ids, nil
  #l.create_volume Crowbar::RAID::RAID1E, "crw-raid1e", l.disks[5..9]
end
