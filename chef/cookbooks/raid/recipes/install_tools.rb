#
# Copyright (c) 2011 Dell Inc.
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

### at some point we'll support raid on other platforms... for now just RHEL derived.
include_recipe "utils"

return unless ["centos","redhat"].member?(node[:platform]) && !@@is_admin
provisioner_server = (node[:crowbar_wall][:provisioner_server] rescue nil)
return unless provisioner_server
sas2ircu="SAS2IRCU_P12.zip"
megacli="8.05.06_MegaCLI.zip"

[sas2ircu,megacli].each do |f|
  remote_file "/tmp/#{f}" do
    source "#{provisioner_server}/files/dell_raid/tools/#{f}"
    action :create_if_missing
  end
end

bash "install sas2ircu" do
  code <<EOC
cd /usr/sbin
[[ -x /usr/sbin/sas2ircu ]] || \
unzip -j "/tmp/#{sas2ircu}" "SAS2IRCU_P12/sas2ircu_linux_x86_rel/sas2ircu"
EOC
end

bash "install megacli" do
  code <<EOC
cd /tmp
[[ -x /opt/MegaRAID/MegaCli/MegaCli64 ]] && exit 0
for pkg in "MegaCliKL_Linux/Lib_Utils-1.00-09.noarch.rpm" "MegaCli_Linux/MegaCli-8.05.06-1.noarch.rpm"; do
    unzip -j "#{megacli}" "$pkg"
  rpm -Uvh "${pkg##*/}"
done
EOC
end
