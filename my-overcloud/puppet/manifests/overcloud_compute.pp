# Copyright 2014 Red Hat, Inc.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

include tripleo::packages

create_resources(kmod::load, hiera('kernel_modules'), {})
create_resources(sysctl::value, hiera('sysctl_settings'), {})
Exec <| tag == 'kmod::load' |>  -> Sysctl <| |>

if count(hiera('ntp::servers')) > 0 {
  include ::ntp
}

include ::timezone

file { ['/etc/libvirt/qemu/networks/autostart/default.xml',
        '/etc/libvirt/qemu/networks/default.xml']:
  ensure => absent,
  before => Service['libvirt']
}
# in case libvirt has been already running before the Puppet run, make
# sure the default network is destroyed
exec { 'libvirt-default-net-destroy':
  command => '/usr/bin/virsh net-destroy default',
  onlyif => '/usr/bin/virsh net-info default | /bin/grep -i "^active:\s*yes"',
  before => Service['libvirt'],
}

# When utilising images for deployment, we need to reset the iSCSI initiator name to make it unique
exec { 'reset-iscsi-initiator-name':
  command => '/bin/echo InitiatorName=$(/usr/sbin/iscsi-iname) > /etc/iscsi/initiatorname.iscsi',
  onlyif  => '/usr/bin/test ! -f /etc/iscsi/.initiator_reset',
}->

file { '/etc/iscsi/.initiator_reset':
  ensure => present,
} ~>
service{"iscsid":
  ensure => 'running',
} ~>
Service["nova-compute"]

include ::nova
include ::nova::config
include ::nova::compute

nova_config {
  'DEFAULT/my_ip':                     value => $ipaddress;
  'DEFAULT/linuxnet_interface_driver': value => 'nova.network.linux_net.LinuxOVSInterfaceDriver';
}

$nova_enable_rbd_backend = hiera('nova_enable_rbd_backend', false)
if $nova_enable_rbd_backend {
  if str2bool(hiera('ceph_ipv6', false)) {
    $mon_host = hiera('ceph_mon_host_v6')
  } else {
    $mon_host = hiera('ceph_mon_host')
  }
  class { '::ceph::profile::params':
    mon_host            => $mon_host,
  }
  include ::ceph::profile::client

  $client_keys = hiera('ceph::profile::params::client_keys')
  $client_user = join(['client.', hiera('ceph_client_user_name')])
  class { '::nova::compute::rbd':
    libvirt_rbd_secret_key => $client_keys[$client_user]['secret'],
  }
}

if hiera('cinder_enable_nfs_backend', false) {
  if ($::selinux != "false") {
    selboolean { 'virt_use_nfs':
        value => on,
        persistent => true,
    } -> Package['nfs-utils']
  }

  package {'nfs-utils': } -> Service['nova-compute']
}

# START CVE-2017-2637 - Switch to SSH for migration
# Libvirt setup (live-migration)
class { '::nova::migration::libvirt':
  transport          => 'ssh',
  client_user        => 'nova_migration',
  client_extraparams => {'keyfile' => '/etc/nova/migration/identity'}
}

class { '::nova::compute::libvirt':
  migration_support => false
}

# Nova SSH tunnel setup (cold-migration)
# Server side
include ::ssh::server
$allow_type = sprintf('LocalAddress %s User', join(hiera('migration_ssh_localaddrs'),','))
$allow_name = 'nova_migration'
$deny_type = 'LocalAddress'
$deny_name = sprintf('!%s', join(hiera('migration_ssh_localaddrs'),',!'))
ssh::server::match_block { 'nova_migration deny':
  name    => $deny_name,
  type    => $deny_type,
  order   => 2,
  options => {
    'DenyUsers' => 'nova_migration'
  },
  notify  => Service['sshd']
}
ssh::server::match_block { 'nova_migration allow':
  name    => $allow_name,
  type    => $allow_type,
  order   => 1,
  options => {
    'ForceCommand'           => '/bin/nova-migration-wrapper',
    'PasswordAuthentication' => 'no',
    'AllowTcpForwarding'     => 'no',
    'X11Forwarding'          => 'no',
    'AuthorizedKeysFile'     => '/etc/nova/migration/authorized_keys'
  },
  notify  => Service['sshd']
}
$migration_ssh_key = hiera('migration_ssh_key')
file { '/etc/nova/migration/authorized_keys':
  content => $migration_ssh_key['public_key'],
  mode    => '0640',
  owner   => 'root',
  group   => 'nova_migration',
  require => Package['openstack-nova-migration'],
}
# Client side
file { '/etc/nova/migration/identity':
  content => $migration_ssh_key['private_key'],
  mode    => '0600',
  owner   => 'nova',
  group   => 'nova',
  require => Package['openstack-nova-migration'],
}

# Remove the VIR_MIGRATE_TUNNELLED from the block_migration_flags which is
# needed to work in RHOSP7, other versions work with the defaults. See
# rhbz#1211457
if !defined(Nova_config['libvirt/block_migration_flag']) {
  nova_config {
    'libvirt/block_migration_flag': value => 'VIR_MIGRATE_UNDEFINE_SOURCE,VIR_MIGRATE_PEER2PEER,VIR_MIGRATE_LIVE,VIR_MIGRATE_NON_SHARED_INC';
  }
}
package {'openstack-nova-migration':
  ensure => installed
}
# END CVE-2017-2637118

include ::nova::network::neutron
include ::neutron

# If the value of core plugin is set to 'nuage',
# include nuage agent,
# else use the default value of 'ml2'
if hiera('neutron::core_plugin') == 'neutron.plugins.nuage.plugin.NuagePlugin' {
  include ::nuage::vrs
  include ::nova::compute::neutron

  class { '::nuage::metadataagent':
    nova_os_tenant_name => hiera('nova::api::admin_tenant_name'),
    nova_os_password    => hiera('nova_password'),
    nova_metadata_ip    => hiera('nova_metadata_node_ips'),
    nova_auth_ip        => hiera('keystone_public_api_virtual_ip'),
  }
} else {
  class { '::neutron::plugins::ml2':
    flat_networks        => split(hiera('neutron_flat_networks'), ','),
    tenant_network_types => [hiera('neutron_tenant_network_type')],
  }

  class { '::neutron::agents::ml2::ovs':
    bridge_mappings => split(hiera('neutron_bridge_mappings'), ','),
    tunnel_types    => split(hiera('neutron_tunnel_types'), ','),
  }

  if 'cisco_n1kv' in hiera('neutron_mechanism_drivers') {
    class { '::neutron::agents::n1kv_vem':
      n1kv_source  => hiera('n1kv_vem_source', undef),
      n1kv_version => hiera('n1kv_vem_version', undef),
    }
  }
}


include ::ceilometer
include ::ceilometer::agent::compute
include ::ceilometer::agent::auth

$snmpd_user = hiera('snmpd_readonly_user_name')
snmp::snmpv3_user { $snmpd_user:
  authtype => 'MD5',
  authpass => hiera('snmpd_readonly_user_password'),
}
class { 'snmp':
  agentaddress => ['udp:161','udp6:[::1]:161'],
  snmpd_config => [ join(['rouser ', hiera('snmpd_readonly_user_name')]), 'proc  cron', 'includeAllDisks  10%', 'master agentx', 'trapsink localhost public', 'iquerySecName internalUser', 'rouser internalUser', 'defaultMonitors yes', 'linkUpDownNotifications yes' ],
}

package_manifest{'/var/lib/tripleo/installed-packages/overcloud_compute': ensure => present}
hiera_include('compute_classes')
