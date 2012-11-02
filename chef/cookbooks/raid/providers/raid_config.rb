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

=begin

Sample config block:

{ 
  "vol-raid1" => {:raid_level => :RAID1}, ## must use exactly 2 disks
  "vol-raid0" => {:raid_level => :RAID0, :disks => 3 },
  "default" =>  {:raid_level => :JBOD , :disks => :remaining}
}

=end


def load_current_resource
  log "load_current_resource start..............................."
  find_controller
  if @raid.nil?
    @failed = true
    return 
  end
  @raid.debug = @new_resource.debug_flag  
  @raid.load_info    
  log "load_current_resource end............................"
end

action :report do  
  do_report()
end

def do_report
  begin
    @raid.load_info
    s = "\n"
    s << "Current RAID configuraiton report:\n"
    s << " disks #{@raid.disks.length}: #{@raid.describe_disks}\n"
    s << " volumes: #{@raid.describe_volumes}\n"
    log s
    
    # "publish" the disk/volume info into the node.
    node["crowbar"]["hardware"] = {} if node["crowbar"]["hardware"].nil?
    ## null out what's there now.
    node["crowbar"]["hardware"]["disks"] = []
    node["crowbar"]["hardware"]["volumes"] = []
    @raid.disks.each { |x| node["crowbar"]["hardware"]["disks"] << x.to_hash } unless @raid.disks.nil?
    @raid.volumes.each { |x| node["crowbar"]["hardware"]["volumes"] << x.to_hash } unless @raid.volumes.nil? 
    node.save    
  end unless @failed
  rescue 
    report_problem($!)  ## $! is the global exception variable
end


action :set_boot do
  do_set_boot()
end

def do_set_boot
  returnVal = @raid.set_boot unless @failed
  log("do_set_boot returnVal: #{returnVal}")
  if (@raid.respond_to?(:create_bios_config_job) && returnVal == '0') # wsman specific case
    returnVal = @raid.create_bios_config_job();
    if(returnVal == '4096')
      sleep() #go to sleep whilst we reboot
    end
  end
rescue 
  report_problem($!)  ## $! is the global exception variable
end

action :apply do
  apply_config unless @failed
end

 def find_controller
  drivers = [Crowbar::RAID::WsManCli,Crowbar::RAID::LSI_MegaCli,Crowbar::RAID::LSI_sasIrcu]
  log("will try: #{drivers.inspect}")
  drivers.each { |c|
     log("trying #{c}") {level :debug}
     ## try to instanciate and test the controller class, but catch errors.
     begin
       @raid = c.new(node)
       test = @raid.find_controller
       if !test.nil?
         log("using #{c}") {level :debug}
         break
       end
     rescue => detail
       log("failed to test #{c}, error: #{detail}")
     end
     @raid = nil # nil out if it didn't take
  }
  log("no suported RAID controller found on this system"){level :error} if @raid.nil?
  log(@raid.describe) unless @raid.nil? 
end




def apply_config  
  returnVal='0';
  config = @new_resource.config
  errors = validate_config(config)
  
  if errors.length > 0
    log("Config Errors:#{errors}")
    throw "Config error #{errors}"
  end
  
  ##
  # compute delta:  
  #  in:
  #   - @raid.volumes = currently present volumes
  #   - config - desired volumes
  # out:
  #    - missing = volumes we're missing
  #    - keep = volumes we have and we want to keep.
  #    - cur_dup - the volumes we have but don't want   
  keep_vols = []
  missing = []
  cur_dup = (@raid.volumes.nil? )? {}: @raid.volumes.dup  
  log_("CONFIG INSPECT #{config.inspect}\n\n\n")
  config.each {|name,cfg |  
    next if name.intern == :default  ## skip checking for default...    
    cfg[:vol_name] = name    
    have = cur_dup.select{ |have|
      (have.vol_name and (have.vol_name.kind_of? String) and (have.vol_name.casecmp(name) == 0))
    }
    if have.length == 0
      missing << cfg 
      log_("will create #{name}")             
    else       
      have_1 = have[0]
      log_("have #{name} #{have_1.raid_level} disks: #{have_1.members.length}") 
      # check config matches, before deciding to keep
      recreate = true
      begin
        if @raid.disks.length < 4 and have_1.raid_level == :RAID1 and cfg[:raid_level].intern == :RAID10
          log_("Downgraded Raid10, Keep it")
          recreate = false
          keep_vols << cur_dup.delete(have_1)
          break
        end
        log_("wrong raidlevel#{have_1.raid_level}: #{cfg[:raid_level]}") and break unless have_1.raid_level == cfg[:raid_level].intern
        disk_cnt = Float(cfg[:disks]) rescue 0
        log_("wrong disk count") and break if disk_cnt >0 and have_1.members.length != disk_cnt
        recreate = false
        keep_vols << cur_dup.delete(have_1)
      end while false
      if (recreate)
        log_("will recreate #{name}")
        missing << cfg
      else 
        log_("keeping it")
      end
    end
  }
  
  ## adjust for how jbod is implemented
  @raid.adjust_config(config,cur_dup, missing, keep_vols)
  
  log_("keeping: #{keep_vols.map{|km| km.vol_name}.join(' ')}")  
  log_("missing: #{missing.map{|mm| mm[:vol_name]}.join(' ')}")
  log_("extra: #{cur_dup.map{|dm| dm.vol_name}.join(' ')}")
  
  # see if we have something to do.
  #log_("nothing to be done") and return if missing.length ==0 and cur_dup.length==0
  
  # remove extra
  if !cur_dup.nil? && cur_dup.length !=0
    cur_dup.each {|e| 
      log_("deleting #{e.vol_id}")
      returnVal = @raid.delete_volume(e.vol_id) 
    }
    if (@raid.respond_to?(:create_raid_config_job) && returnVal=='0') # wsman specific case
      returnVal = @raid.create_raid_config_job();
      if(returnVal == '4096')
        sleep() #go to sleep whilst we reboot
      end
    end
  end
  
  # figure out what disks we have avail - those not used in volumes we're keeping
  disks_used = keep_vols.map { |v| 
    v.members.map{ |d| "#{d.enclosure}:#{d.slot}"}    
  }
  disks_used.flatten!
  disk_avail = @raid.disks.dup
  disk_avail.delete_if { |d| disks_used.include?("#{d.enclosure}:#{d.slot}") }
  log_("available disks (#{disk_avail.length}): #{disk_avail.join(',')}")
  
  # allocate disks, and make a list of volumes to create
  missing.sort! { | a,b | a[:order] <=> b[:order] } # sort by order  
  log_(" ordered missing vols: #{missing.map{|m| m[:vol_name]}.join(' ')}")
  missing.each { |m| 
    disk_2_use = []
    disk_cnt = 0
    if m[:disks].nil? or m[:disks] == :remaining
      # use all the disks
      log_("using remaining disks: #{disk_avail.length}")
      disk_cnt = disk_avail.length
    else
      disk_cnt = Integer(m[:disks])
      log_("using specified disk count: #{disk_cnt}")
    end    
    adj_disk_cnt = adjust_max_disk_cnt(m,disk_cnt)
    log_("orig/adj disk count #{disk_cnt}/#{adj_disk_cnt}")
    
    disk_cnt = adj_disk_cnt
     (1..disk_cnt).each {
      next_disk = disk_avail.shift
      throw "out of disks" if next_disk.nil?
      disk_2_use << next_disk 
    }
    
    # if total volume size is too big, force it down (Current BIOS cannot handle >2 TB disks)    
    disk_size = @raid.disks[0].size
    total_size = disk_size * disk_2_use.length
    case m[:raid_level].intern
      when :RAID0
         total_size = total_size   # striped - no change 
      when :RAID1
         total_size = total_size / 2 # mirror - 1/2
      when :RAID5
         total_size = disk_size * (disk_2_use.length -1 ) # dedicate 1 drive
      when :RAID10
         total_size = total_size / 2 # striped mirrors - 1/2
      
    else
      raise "unknown raid level #{m[:raid_level]}"
    end
    
    
    max_size = (Crowbar::RAID::TERA * 2 - Crowbar::RAID::MEGA) 
    max_size = nil if total_size < max_size    
    # remove extra
    if !disk_2_use.nil? && disk_2_use.length !=0
      log_("Creating vol #{m[:vol_name]} with #{disk_2_use.length} total/max size: #{total_size}/#{max_size} disks: #{disk_2_use.join(' ')}*********************************************************** ")
      returnVal = @raid.create_volume(m[:raid_level], m[:vol_name], disk_2_use, max_size)
      if (@raid.respond_to?(:create_raid_config_job) && returnVal=='0') # wsman specific case 
        returnVal = @raid.create_raid_config_job();
        if(returnVal =='4096')
          sleep() #go to sleep whilst we reboot
        end
      end
    end
  }
  returnVal = @raid.apply_default(config, disk_avail)
  if (@raid.respond_to?(:create_raid_config_job) && returnVal=='0') # wsman specific case 
    returnVal = @raid.create_raid_config_job();
    if(returnVal =='4096')
      sleep() #go to sleep whilst we reboot
    end
  end
  log_("unused disks #{disk_avail.join(' ')}")
rescue 
  report_problem($!)  ## $! is the global exception variable
end



=begin
 The following rules need to be checked:  
   - For a type 'RAID1' volume min 2 disks must be specified. will truncate down to two
   - For a type 'RAID1E' volume min of 3 disks must be specified.
   - For a type 'RAID0' volume min of 2 disks must be specified.
   - For a type 'RAID10' volume min of 4 disks must be specified.
Additionally:
- No set has more than 10 disk
- Raid1E only works with an odd number of disks (so up to 9 total disks, since 10 is not odd)
- No more than 2 raid volumes are specified.
- Total count of disks in config is less than available
- no duplicate named volumes

=end

def validate_config(config)
  
  total_used = 0
  errors = ""
  config.each { |k,v| 
    log("checking volume config: #{k}") {level :warn}    
    err_temp = "#{v[:raid_level]} volume #{k} should "
    v[:disks] = Float(v[:disks]).to_i rescue v[:disks].intern
    case v[:raid_level].intern
      when :RAID1
      errors << err_temp << "have more than 2 disks\n" unless v[:disks].nil? or v[:disks] > 2
      
      when :RAID1E
      errors << err_temp << "have more than 2 disks\n" unless v[:disks].isblank? or  v[:disks] >2
      errors << err_temp << "have no more than 9 disks\n" unless v[:disks] <=9
      errors << err_temp << "have an odd number of disks\n" unless (v[:disks] % 2) ==1
      v[:disks] = 2
      
      when :RAID0
      errors << err_temp << "have at least 2 disks (#{v[:disks]})\n" unless v[:disks]==:remaining or v[:disks] >= 2
      errors << err_temp << "have no more than 10 disks\n" unless v[:disks] <=10
      
      when :RAID10
      if v[:disks] < 2
        errors << err_temp << "have at least 2 disks\n"
      elsif v[:disks] < 4
        v[:raid_level] = "RAID1"
        config[k][:raid_level] = "RAID1"
        log("setting raid 10 downward to raid1 - not enough disks")
      end
      errors << err_temp << "have no more than 10 disks\n" unless v[:disks] <=10
      
      when :JBOD
      
    else
      errors << "#{k} uses an unknwon raid level #{v[:raid_level]}"
    end unless v[:disks] == :remaining
    
    disk_use = Float(v[:disks]) rescue 0
    total_used = total_used + disk_use
    
  }
  
  total_avail = @raid.disks.length
  errors << "too many disks specified. required: #{total_used} avail: #{total_avail}" if total_used > total_avail
  errors  
  
end

=begin
  Check the number of disks to be used, and REDUCE it if it doesn't meet requirements
(can't increase it !)
=end
def adjust_max_disk_cnt(config, s_cnt)
  v = config
  log_pref = "for #{config[:vol_name]} type:#{v[:raid_level]} "
  log ("checking #{log_pref} with #{s_cnt} disks")
  case v[:raid_level].intern
    when :RAID1
    raise "RAID1 - must have 2 disks" if s_cnt < 2
    return 2
    
    when :RAID1E
    raise "RAID1E must have at least 3 disks" if s_cnt < 3
    if s_cnt % 2 ==0
      log("#{log_pref} RAID1E must be odd - reduce by 1") 
      s_cnt = s_cnt -1
    end    
    s_cnt = 9 if s_cnt > 9     
    
    when :RAID0
    raise "RAID0 must have at least 2 disks" if s_cnt < 2
    if s_cnt >=10
      log("#{log_pref} max disk use is 10") 
      s_cnt = 10
    end
    
    when :RAID10
    raise "RAID10 must have at least 4 disks" if s_cnt < 2
    if s_cnt < 4
      s_cnt = 2
      v[:raid_level] = "RAID1"
      log("setting raid 10 downward to raid1 - not enough disks")
    end
    if s_cnt >=10
      log("#{log_pref} max disk use is 10") 
      s_cnt = 10
    end
    
    when :JBOD
    # no restrictions
  end
  
  return s_cnt
end


###
# log to the problem file.
# 
#
def report_problem(msg)
  problem_file = @new_resource.problem_file
  log_("reporting problem to: #{problem_file}- #{msg}" )
  unless problem_file.nil?
    open(problem_file,"a") { |f| f.puts(msg) }
  end
  log_(msg)
end


def log_(msg)
  Chef::Log.info(msg) 
  true
end
