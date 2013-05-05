# Copyright 2012, Dell 
# 
# XXX: Dell Copyright
#

class DellRaidService < ServiceObject

  def initialize(thelogger)
    @bc_name = "raid"
    @logger = thelogger
  end
  
  def create_proposal
    @logger.debug("Raid create_proposal: entering")
    base = super
    @logger.debug("Raid create_proposal: exiting")
    base
  end
  
  def transition(inst, name, state)
    @logger.debug("Raid transition: make sure that network role is on all nodes: #{name} for #{state}")
    
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

    @logger.debug("Raid transition: leaving for #{name} for #{state}")
    [200, NodeObject.find_node_by_name(name).to_hash ]
  end


   def add_role(inst, name, state, new_role)

     @logger.debug("Raid transition: installed state for #{name} for #{state}")
     db = ProposalObject.find_proposal "raid", inst
     role = RoleObject.find_role_by_name "raid-config-#{inst}"
     result = add_role_to_instance_and_node("raid", inst, name, db, role, new_role )
     @logger.debug("Raid transition: leaving from installed state for #{name} for #{state}")
     a = [200, NodeObject.find_node_by_name(name).to_hash ] if result
     a = [400, "Failed to add role to node"] unless result
     return a
   end

end
