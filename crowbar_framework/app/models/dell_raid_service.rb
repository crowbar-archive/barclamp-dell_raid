# Copyright 2012, Dell 
# 
# XXX: Dell Copyright
#

class DellRaidService < ServiceObject
  
  def transition(inst, name, state)
    @logger.debug("Raid transition: make sure that network role is on all nodes: #{name} for #{state}")
    
    ret = true 
    case state
      when "discovering"
        ret = add_role_to_instance_and_node(name, inst, "discover-raid" )
      when  "discovered"
        # If we're done discovering the node, 
        # make sure that we add the bios raid role to the node
        ret = add_role_to_instance_and_node(name, inst, "raid-configure")
    end
    return [400, "Failed to add role to node"] unless ret

    @logger.debug("Raid transition: leaving for #{name} for #{state}")
    [200, ""]
  end
  
end
