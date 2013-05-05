#!/usr/bin/ruby

require 'rubygems'
require 'yaml'
require 'json'

class XML_UTIL
   # chef breaks if 'require' is outsite executable code for any GEMs 
   # installed during compile phase in other recipies in run list
   # Dependency checking is happening in libraries prior to compile phase. 
   # Hack is to move 'require' in initialize() which is called during exectution phase.
   def initialize()
     require 'xmlsimple' 
   end
  
  def  processResponse(xml, path, options={"ForceArray" => false})
    begin
      hash = XmlSimple.xml_in(xml, options)
      output = eval("hash#{path}")
      return output
    rescue Exception => e
      puts "Unable to find node #{path} in returned xml...Returning nil"
      return nil
    end
  end
  
  def returnValue(xml,cmd)
    path = '["Body"]["' + cmd + '_OUTPUT"]["ReturnValue"]' 
    processResponse(xml , path)
  end
  
end
