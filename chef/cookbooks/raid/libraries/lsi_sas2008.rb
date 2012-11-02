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


#require 'chef/mixin/shell_out'
#include Chef::Mixin::ShellOut

require 'expect'
require 'pty'

require File.join(File.dirname(__FILE__), 'raid_data')

class LSI_Util
  
  def initialize(node)
    $expect_verbose = true
    @prompt = /.*quit\]\s*$/
    @_out, @_in, @pid = PTY.spawn('/updates/lsiutil.x86_64 -e')
    log("started process. pid #{@pid} ")
    @_out.sync = true     
  end
  
  def select_adapter    
    wait_prompt("select adapter"){ |resp_arr|
      resp = resp_arr[0]
      @_in.puts "1\n"
      wait_prompt("main menu")
    }      
  end
  
  def collect_raid_volumes
=begin
  Sample volume info

Volume 0 is DevHandle 00ab, Bus 1 Target 3, Type RAID1E (Mirroring Extended)
  Volume Name:  raid1e
  Volume WWID:  0b656ed590e4e3ad
  Volume State:  optimal, enabled
      [Pending:  background init]
  Volume Settings:  write caching disabled, auto configure hot swap enabled
  Volume draws from Hot Spare Pools:  0
  Volume Size 2381800 MB, Stripe Size 64 KB, 5 Members
  Member 0 is PhysDisk 2 (DevHandle 000c, Bus 0 Target 2)
  Member 1 is PhysDisk 3 (DevHandle 000d, Bus 0 Target 3)
  Member 2 is PhysDisk 4 (DevHandle 000e, Bus 0 Target 4)
  Member 3 is PhysDisk 5 (DevHandle 000f, Bus 0 Target 5)
  Member 4 is PhysDisk 6 (DevHandle 0010, Bus 0 Target 6)

Volume 1 is DevHandle 00ac, Bus 1 Target 2, Type RAID1 (Mirroring)
  Volume Name:  raid1
  Volume WWID:  0918c2ff5e294f1b
  Volume State:  optimal, enabled
      [In Progress:  background init]
  Volume Settings:  write caching disabled, auto configure hot swap enabled, data scrub allowed
  Volume draws from Hot Spare Pools:  0
  Volume Size 952720 MB, 2 Members
  Primary is PhysDisk 0 (DevHandle 000a, Bus 0 Target 0)
  Secondary is PhysDisk 1 (DevHandle 000b, Bus 0 Target 1)
=end    

    
    @_in.puts "21\n" ## switch to raid mode (21)
    wait_prompt("collect raid vols - raid menu")
    
    @_in.puts "1\n" ## issue the "show raid volumes" command        
    text = ""
    wait_prompt("collect raid vols-show result") { |resp_arr|
      text = resp_arr[0]
    }        
    
    ## parse the volume info
    ## chunk the outcome of the "show volumes" command into blocks for each volume.
    vol_idx = 0
    @raid_vols = []
    begin  
      md = text.match(/(?m)(^Volume.*?)(\z|^Volume)/) # yank 1 volume info, stop at the next one or the end of input (\z).
      next if md.nil?
      log("vol #{vol_idx} info: #{md[1]}")
      @raid_vols[vol_idx] = parse_volume text[md.begin(1),md.end(1)-1]
      text = text[md.end(1),  text.length-md.end(1)]
      vol_idx = vol_idx +1
    end while !md.nil?
    
    @raid_vols.each { |r| 
      puts "Volume: #{r.vol_name}, pci: #{r.pci_id} id: #{r.vol_id} type: #{r.type} members: #{r.members.map { |d| d.disk_id}.join(',')}"     
    }
    
    @_in.puts "0\n"
    wait_prompt("collect raid vols-return main menu") { |resp_arr|
      text = resp_arr[0]
    }        
    
  end
  
  
=begin
Parse a chunk of lines representing a RAID volume, and retrun a populated RaidVolume
=end  
  def parse_volume t
    r = Crowbar::RAID::Volume.new()    
    l = t.split($/)
    log ("looking at #{l[0]}")
    
    #Volume 0 is DevHandle 00ab, Bus 1 Target 3, Type RAID1E (Mirroring Extended)    
    /^Volume (\d+) .*, Bus (\d+) Target (\d+), Type ([^ ]*) .*$/.match(l.shift)
    r.vol_id, bus, tgt, r.type = *$~[1..4]
    r.pci_id = "#{bus}:#{tgt}"
    log ("looking at #{l[0]}")
    /Volume Name:\s+ (.*)$/.match(l.shift)
    r.vol_name = $1.chomp
    
    log("Parsing members for Volume of type: #{r.type}")
    case r.type      
      when "RAID1":
=begin
  Primary is PhysDisk 0 (DevHandle 000a, Bus 0 Target 0)
  Secondary is PhysDisk 1 (DevHandle 000b, Bus 0 Target 1)        
=end
      l.shift while !l.nil? and l.length >0 and /Primary /.match(l[0]).nil?
      l.each { | member_line |
        /.* is PhysDisk (\d+) .*/.match(member_line)
        break if $~.nil?
        d = Crowbar::RAID::RaidDisk.new
        d.disk_id = $1
        r.members << d    
      }
      
      when "RAID1E","RAID0"
=begin
  Member 3 is PhysDisk 5 (DevHandle 000f, Bus 0 Target 5)
=end        
      l.shift while !l.nil? and l.length >0 and /Member /.match(l[0]).nil?    
      l.each {| member_line |
      /Member (\d+) is PhysDisk (\d+) .*/.match(member_line)
        break if $~.nil?
        d = Crowbar::RAID::RaidDisk.new
        d.disk_id = $2
        r.members << d
      }
    end
    
    r    
  end
  
  def load_os_names
=begin

ioc0 is SCSI host 4

 B___T___L  Type       Operating System Device Name
 0   0   0  Disk       /dev/sdc    [4:0:0:0]
 0   1   0  Disk       /dev/sdd    [4:0:1:0]
 0   7   0  Disk       /dev/sdh    [4:0:7:0]
 0   8   0  Disk       /dev/sdi    [4:0:8:0]
 0  12   0  EnclServ
 1   3   0  Disk       /dev/sdb    [4:1:3:0]
 1   4   0  Disk       /dev/sde    [4:1:4:0]
  
=end    
    @_in.puts "42\n"
    text =''
    wait_prompt("load os names") { |resp| text = resp[0]} 
    l = text.split($/)
    l.shift while /B___T___L/.match(l[0]).nil?
    l.shift    
    @os_disks = []
    r = /\s+(\d+)\s+(\d+)\s+(\d+)\s+Disk\s+([^ ]+) .*$/
    r_enc = /\s+(\d+)\s+(\d+)\s+(\d+)\s+EnclServ.*$/
    l.each { |line| 
      log("Loooking at #{line}")
      log("skipping enclosure") and next if !r_enc.match(line).nil?
      r.match(line)
      log("skipping bad line #{line}") and next if $~.nil?
      o = Crowbar::RAID::OSDisk.new
      bus, tgt,o.dev_name = $~.values_at(*[1,2,4])
      o.pci_id = "#{bus}:#{tgt}"
      @os_disks << o
    }
    
    @os_disks.each { |disk| puts " dev: #{disk.dev_name}  at #{disk.pci_id}"}
  end
  
  
  def delete_all_volumes
    collect_raid_volumes if @raid_vols.nil?
    puts "no volumes to remove" or return if @raid_vols.length ==0 
    
    ## switch to raid
    @_in.puts "21\n"
    wait_prompt("del volumes - raid")
    
    ack_prompt =/.*No\]\s*/
     (1.. @raid_vols.length).each {|x| 
      ## start delete
      log("working on volume #{x}/#{@raid_vols.length}")
      @_in.puts "31\n"    
      begin
        wait_prompt("del volumes - issue del")
        @_in.puts "0\n"         
      end if x < @raid_vols.length
      wait_prompt("del volumes - ack delete", ack_prompt)
      @_in.puts "yes\n"
      wait_prompt("del volumes - zero stuff", ack_prompt)
      @_in.puts "yes\n"
      wait_prompt("del volumes - next drive")      
    }
    
    @_in.puts "0\n"
    wait_prompt("del volumes - back to main")
  end
  
  def create_raid_with_all_disks(raid_type = "RAID1E")
    collect_raid_volumes if @raid_vols.nil?
    #... check that we have a raid..? 
    
    ## switch to raid
    @_in.puts "21\n"
    wait_prompt("create volumes - raid")
    ## start create
    @_in.puts "30\n"
    
=begin
output is a list of avail drives:

     B___T___L  Type       Vendor   Product          Rev   Disk Blocks  Disk MB
 1.  0   0   0  Disk       ATA      ST31000524NS     KA05   1953525168   953869
 2.  0   1   0  Disk       ATA      ST31000524NS     KA05   1953525168   953869
 3.  0   2   0  Disk       ATA      ST31000524NS     KA05   1953525168   953869
 4.  0   3   0  Disk       ATA      ST31000524NS     KA05   1953525168   953869   
=end
    text = ''
    wait_prompt("create volumes - disk list") { |resp| text = resp[0]}
    l = text.split($/)
    l.shift while /B___T___L/.match(l[0]).nil?
    avail_disks = []
    r = /\s*(\d+)\.\s+(\d+)\s+(\d+)\s+(\d+)\s+Disk.*$/
    l.each { |x| 
      r.match(x)
      next if $~.nil?
      id = $1
      avail_disks << id
    }
    
    type_code = ''
    max_disks = 10
    case raid_type
      when "RAID1E"
      type_code = "2"
      when "RAID1"
      type_code = "1"
      max_disks = 2
      when "RAID0"
      type_code = "0"
    end
    
    log("available disks: #{avail_disks.join(',')}") 
    ## can at most have 10 disks.. pick the last 10 (or 2 for raid1)
    avail_disks = avail_disks.slice!(-max_disks,max_disks) if avail_disks.length > max_disks
    log("will use these disks (at most #{max_disks}): #{avail_disks.join(',')}")
    
    disk_cnt =0
    avail_disks.each { |x| 
      @_in.puts "#{x} \n"
      disk_cnt = disk_cnt + 1
      puts "max disk count hit" or break if disk_cnt ==10 ## hardcoded... util breaks after 10 disks
      wait_prompt("added disk #{x}",/\]/) 
    }
    begin
      @_in.puts "\n" 
      wait_prompt("select raid type")
    end unless disk_cnt ==10
    @_in.puts "#{type_code}\n"
    wait_prompt("volume size:", /\] /)
    @_in.puts "\n" ## accept default
    wait_prompt("volume name:", /characters\]/)
    @_in.puts "crowbar-#{raid_type}\n"
    wait_prompt("use settings:", /\]/)
    @_in.puts "\n"  ## yes - use defaults
    wait_prompt("Zero things", /\]/)
    @_in.puts "yes\n"  ## force new filesystems.
    
    begin
      wait_prompt("copy data to sec",/\]/)
      @_in.puts "no\n"
    end if raid_type == "RAID1"
    
    wait_prompt("done volume create")
    @_in.puts "0\n" ## return to main menu
    wait_prompt("main menu")
    sleep 4 ## wait a bit, so the new volume shows up on the OS.
  end
  
  def wait_prompt(msg, search_re = @prompt)
    log("waiting for prompt: #{msg}")
    result = @_out.expect(search_re,10) 
    if block_given? then
      yield result
    else
      return result
    end           
  end
  
  def log (msg)
    puts msg
    true
  end
  
end


if __FILE__ == $0
  # dev testing below...
  l = LSI_Util.new
  l.select_adapter
  l.collect_raid_volumes
  l.load_os_names
  l.delete_all_volumes
  l.create_raid_with_all_disks("RAID1")
  l.collect_raid_volumes
  l.load_os_names
end
