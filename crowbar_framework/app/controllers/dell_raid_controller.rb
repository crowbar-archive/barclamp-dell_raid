# Copyright 2011, Dell
#
# XXX: Dell Copyright
#

class DellRaidController < BarclampController
 def initialize
    @service_object = DellRaidService.new logger
  end
end
