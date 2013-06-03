# Copyright (c) 2013 Dell Inc.
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

class DellRaidService < ServiceObject

  def initialize(thelogger)
    @bc_name = "dell_raid"
    @logger = thelogger
  end
  
  def create_proposal
    @logger.debug("Raid create_proposal: entering")
    base = super
    @logger.debug("Raid create_proposal: exiting")
    base
  end
  
  def transition(inst, name, state)
    @logger.debug("DellRaid transition: make sure that role is on all nodes: #{name} for #{state}")
    
    ret = nil 
    case state
      when "discovering"
        ret = add_role(inst, name, state, "discover-raid" )
      when  "discovered"
      # If we're done  discovering the node, make sure that we add the bios raid role to the node
        ret = add_role(inst,name,state,"raid-configure")
        ret = add_role(inst,name,state,"raid-setboot-nic-first")
        ret = add_role(inst,name,state,"raid-setboot-disk-first")
    end
    ret unless ret.nil?

    @logger.debug("DellRaid transition: leaving for #{name} for #{state}")
    [200, NodeObject.find_node_by_name(name).to_hash ]
  end


   def add_role(inst, name, state, new_role)

     @logger.debug("DellRaid transition: installed state for #{name} for #{state}")
     db = ProposalObject.find_proposal "dell_raid", inst
     role = RoleObject.find_role_by_name "dell_raid-config-#{inst}"
     result = add_role_to_instance_and_node("dell_raid", inst, name, db, role, new_role )
     @logger.debug("DellRaid transition: leaving from installed state for #{name} for #{state}")
     a = [200, NodeObject.find_node_by_name(name).to_hash ] if result
     a = [400, "Failed to add role to node"] unless result
     return a
   end

   
end
