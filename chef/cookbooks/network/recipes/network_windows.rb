return if not node[:platform] == 'windows'

unless registry_value_exists?("HKEY_LOCAL_MACHINE\\SOFTWARE\\Crowbar", {:name => "NetAdapterReorder", :type => :string, :data => 'done'}, :machine)
    powershell "reorder_nics" do
        environment ({'json' => JSON.dump(node["crowbar"]["interface_map"])})
        code <<-EOH
        $model = (Get-WmiObject win32_computersystem).Model
        $interface_map = $env:json | ConvertFrom-Json
        $ifaces = $null
        foreach ($i in $interface_map){
            if ($i.pattern -eq $model){
                $ifaces = $i.pnpid_order
            }
        }

        if ($ifaces -eq $null){
            Exit
        }

        $orderDevices = @()
        $adapterPNPIds = @{}

        foreach ($i in Get-NetAdapter){
            $adapterPNPIds.Add($i.PnPDeviceID, $i.InterfaceGuid)
        }
        foreach ($i in $ifaces){
            if ($adapterPNPIds[$i]){
                $orderDevices += '\\Device\\' + $adapterPNPIds[$i]
                $adapterPNPIds.Remove($i)
            }else{
                # Should be there. We exit if its not
                Exit
            }
        }
        foreach ($i in $adapterPNPIds){
            # add any cards that are not specified in pnpid_order
            if ($adapterPNPIds[$i].length -gt 0 ){
              $orderDevices += "\\Device\\" + $adapterPNPIds[$i]
            }
        }
        echo $adapterPNPIds
        $current = (Get-Item HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Linkage).GetValue('Bind')
        if (Compare-Object -ReferenceObject $current -DifferenceObject $orderDevices){
            Set-ItemProperty -Name Bind -Value ([string[]]$orderDevices) -Path "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Linkage"
        }
        EOH
    end

    registry_key "HKEY_LOCAL_MACHINE\\SOFTWARE\\Crowbar" do
        values [{
        :name => "NetAdapterReorder",
        :type => :string,
        :data => 'done'
        }]
        action :create_if_missing
    end
end


powershell "configure_networking" do
  environment ({'VLANID' => node["crowbar"]["network"]["admin"]["vlan"], 'USE_VLAN' => node["crowbar"]["network"]["admin"]["use_vlan"]})
  code <<-EOH
  $nic_name = "Management"
  if($env:USE_VLAN -eq "true"){
    $nic_name = "ManagementNic"
  }
  Rename-NetAdapter -Name (Get-NetIPAddress -IPAddress "#{node[:crowbar][:network][:admin][:address]}").InterfaceAlias -NewName $nic_name
  if ($env:USE_VLAN -eq "true"){
    New-NetLbfoTeam -Name ManagementTeam -TeamMembers $nic_name -Confirm:$false
    New-NetLbfoTeamNic -Team ManagementTeam -VlanID $env:VLANID -Name Management -Confirm:$false
  }
  $VSwitchList = Get-VMSwitch
  $SwitchConfigured = $false

  if ($VSwitchList -ne $null)
  {
    foreach ($VSwitch in $VSwitchList)
    {
      if ($VSwitch.Name -eq "vswitch") {$SwitchConfigured = $true} 
    }
  }
  if ($SwitchConfigured -ne $true)
  {
    $NetAdapterList = Get-NetAdapter | Where-Object {$_.Status -eq "Up" -and $_.Name -ne "Management" -and $_.Virtual -ne "True"} | Select Name
    $i=0
    foreach ($NetCard in $NetAdapterList)
    {
      Rename-NetAdapter -Name $NetCard.Name -NewName "VSwitchNetCard$i"
      $i++
    }
    if ($i -gt 0)
    {
      New-VMSwitch -NetAdapterName "VSwitchNetCard0" -Name "vswitch" -AllowManagementOS $false
    } else {
      New-VMSwitch -NetAdapterName "Management" -Name "vswitch" -AllowManagementOS $true
    }
  }
  EOH
end
