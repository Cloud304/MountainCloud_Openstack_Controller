#!/bin/bash

#get the configuration info
source config

echo "install ntp"
yum -y install ntp
systemctl enable ntpd.service
systemctl start ntpd.service

echo "openstack repos"
yum -y install net-tools mlocate wget 
yum -y update
yum -y install yum-plugin-priorities
yum -y install http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
yum -y install http://rdo.fedorapeople.org/openstack-juno/rdo-release-juno.rpm
yum -y upgrade
yum -y install openstack-selinux

echo "loosen things up"
systemctl stop firewalld.service
systemctl disable firewalld.service
sed -i 's/enforcing/disabled/g' /etc/selinux/config
echo 0 > /sys/fs/selinux/enforce

echo "install database server"
yum -y install mariadb mariadb-server MySQL-python

echo "edit /etc/my.cnf"
sed -i.bak "10i\\
bind-address = $CONTROLLER_IP\n\
default-storage-engine = innodb\n\
innodb_file_per_table\n\
collation-server = utf8_general_ci\n\
init-connect = 'SET NAMES utf8'\n\
character-set-server = utf8\n\
" /etc/my.cnf

echo "start database server"
systemctl enable mariadb.service
systemctl start mariadb.service

echo "now run through the mysql_secure_installation"
mysql_secure_installation

echo "create databases"
echo 'Enter the new MySQL root password'
mysql -u root -p <<EOF
CREATE DATABASE nova;
CREATE DATABASE cinder;
CREATE DATABASE glance;
CREATE DATABASE keystone;
CREATE DATABASE neutron;
CREATE DATABASE heat;
CREATE DATABASE trove;
CREATE DATABASE sahara;
CREATE DATABASE cloudkitty;
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON cloudkitty.* TO 'cloudkitty'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON sahara.* TO 'sahara'@'localhost' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON trove.* TO 'trove'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON cloudkitty.* TO 'cloudkitty'@'%' IDENTIFIED BY '$SERVICE_PWD';
GRANT ALL PRIVILEGES ON sahara.* TO 'sahara'@'%' IDENTIFIED BY '$SERVICE_PWD';
FLUSH PRIVILEGES;
EOF

#install messaging service
yum -y install rabbitmq-server
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service
systemctl restart rabbitmq-server.service
rabbitmqctl change_password guest '$SERVICE_PWD'


#install keystone
yum -y install openstack-keystone python-keystoneclient


#edit /etc/keystone.conf
sed -i.bak "s/#admin_token=ADMIN/admin_token=$ADMIN_TOKEN/g" /etc/keystone/keystone.conf

sed -i "/\[database\]/a \
connection = mysql://keystone:$SERVICE_PWD@$THISHOST_NAME/keystone" /etc/keystone/keystone.conf

sed -i "/\[token\]/a \
provider = keystone.token.providers.uuid.Provider\n\
driver = keystone.token.persistence.backends.sql.Token\n" /etc/keystone/keystone.conf

#finish keystone setup
keystone-manage pki_setup --keystone-user keystone --keystone-group keystone
chown -R keystone:keystone /var/log/keystone
chown -R keystone:keystone /etc/keystone/ssl
chmod -R o-rwx /etc/keystone/ssl
su -s /bin/sh -c "keystone-manage db_sync" keystone

#start keystone
systemctl enable openstack-keystone.service
systemctl start openstack-keystone.service

#schedule token purge
(crontab -l -u keystone 2>&1 | grep -q token_flush) || \
  echo '@hourly /usr/bin/keystone-manage token_flush >/var/log/keystone/keystone-tokenflush.log 2>&1' \
  >> /var/spool/cron/keystone
  
#create users and tenants
export OS_SERVICE_TOKEN=$ADMIN_TOKEN
export OS_SERVICE_ENDPOINT=http://$THISHOST_NAME:35357/v2.0


keystone tenant-create --name admin --description "Admin Tenant"
keystone user-create --name admin --pass $ADMIN_PWD
keystone role-create --name admin
keystone user-role-add --tenant admin --user admin --role admin
keystone role-create --name _member_
keystone user-role-add --tenant admin --user admin --role _member_
keystone tenant-create --name demo --description "Demo Tenant"
keystone user-create --name demo --pass $DEMO_PWD
keystone user-role-add --tenant demo --user demo --role _member_
keystone tenant-create --name service --description "Service Tenant"
keystone service-create --name keystone --type identity \
  --description "OpenStack Identity"



keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ identity / {print $2}') \
  --publicurl http://$THISHOST_NAME:5000/v2.0 \
  --internalurl http://$THISHOST_NAME:5000/v2.0 \
  --adminurl http://$THISHOST_NAME:35357/v2.0 \
  --region regionOne
identity

unset OS_SERVICE_TOKEN OS_SERVICE_ENDPOINT

#create admin credentials file
echo "export OS_TENANT_NAME=admin" > admin_creds
echo "export OS_USERNAME=admin" >> admin_creds
echo "export OS_PASSWORD=$ADMIN_PWD" >> admin_creds
echo "export OS_AUTH_URL=http://$THISHOST_NAME:35357/v2.0" >> admin_creds
source admin_creds

#create demo credentials file
echo "export OS_TENANT_NAME=demo" > demo_creds
echo "export OS_USERNAME=demo" >> demo_creds
echo "export OS_PASSWORD=$DEMO_PWD" >> demo_creds
echo "export OS_AUTH_URL=http://$THISHOST_NAME:5000/v2.0" >> demo_creds

#create keystone entries for glance
keystone user-create --name glance --pass $SERVICE_PWD
keystone user-role-add --user glance --tenant service --role admin
keystone service-create --name glance --type image \
  --description "OpenStack Image Service"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ image / {print $2}') \
  --publicurl http://$THISHOST_NAME:9292 \
  --internalurl http://$THISHOST_NAME:9292 \
  --adminurl http://$THISHOST_NAME:9292 \
  --region regionOne

#install glance
yum -y install openstack-glance python-glanceclient

#edit /etc/glance/glance-api.conf
sed -i.bak "/\[database\]/a \
connection = mysql://glance:$SERVICE_PWD@$THISHOST_NAME/glance" /etc/glance/glance-api.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = glance\n\
admin_password = $SERVICE_PWD" /etc/glance/glance-api.conf

sed -i "/\[paste_deploy\]/a \
flavor = keystone" /etc/glance/glance-api.conf

sed -i "/\[glance_store\]/a \
default_store = file\n\
filesystem_store_datadir = /var/lib/glance/images/" /etc/glance/glance-api.conf

#edit /etc/glance/glance-registry.conf
sed -i.bak "/\[database\]/a \
connection = mysql://glance:$SERVICE_PWD@$THISHOST_NAME/glance" /etc/glance/glance-registry.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = glance\n\
admin_password = $SERVICE_PWD" /etc/glance/glance-registry.conf

sed -i "/\[paste_deploy\]/a \
flavor = keystone" /etc/glance/glance-registry.conf

#start glance
su -s /bin/sh -c "glance-manage db_sync" glance
systemctl enable openstack-glance-api.service openstack-glance-registry.service
systemctl start openstack-glance-api.service openstack-glance-registry.service

#upload the cirros image to glance
yum -y install wget
wget http://cdn.download.cirros-cloud.net/0.3.3/cirros-0.3.3-x86_64-disk.img
glance image-create --name "cirros-0.3.3-x86_64" --file cirros-0.3.3-x86_64-disk.img \
  --disk-format qcow2 --container-format bare --is-public True --progress

mkdir -p /mnt/images
cp cirros-0.3.3-x86_64-disk.img /mnt/images
rm -rf cirros-0.3.3-x86_64-disk.img
  
#create the keystone entries for nova
keystone user-create --name nova --pass $SERVICE_PWD
keystone user-role-add --user nova --tenant service --role admin
keystone service-create --name nova --type compute \
  --description "OpenStack Compute"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ compute / {print $2}') \
  --publicurl http://$THISHOST_NAME:8774/v2/%\(tenant_id\)s \
  --internalurl http://$THISHOST_NAME:8774/v2/%\(tenant_id\)s \
  --adminurl http://$THISHOST_NAME:8774/v2/%\(tenant_id\)s \
  --region regionOne

#install the nova controller components
yum -y install openstack-nova-api openstack-nova-cert openstack-nova-conductor \
  openstack-nova-console openstack-nova-novncproxy openstack-nova-scheduler \
  python-novaclient

#edit /etc/nova/nova.conf
sed -i.bak "/\[database\]/a \
connection = mysql://nova:$SERVICE_PWD@$THISHOST_NAME/nova" /etc/nova/nova.conf

sed -i "/\[DEFAULT\]/a \
rpc_backend = rabbit\n\
rabbit_host = $THISHOST_NAME\n\
rabbit_password = $SERVICE_PWD\n\
auth_strategy = keystone\n\
my_ip = $CONTROLLER_IP\n\
vncserver_listen = $CONTROLLER_IP\n\
vncserver_proxyclient_address = $CONTROLLER_IP\n\
network_api_class = nova.network.neutronv2.api.API\n\
security_group_api = neutron\n\
linuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver\n\
firewall_driver = nova.virt.firewall.NoopFirewallDriver" /etc/nova/nova.conf

sed -i "/\[keystone_authtoken\]/i \
[database]\nconnection = mysql://nova:$SERVICE_PWD@$THISHOST_NAME/nova" /etc/nova/nova.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = nova\n\
admin_password = $SERVICE_PWD" /etc/nova/nova.conf

sed -i "/\[glance\]/a host = $THISHOST_NAME" /etc/nova/nova.conf

sed -i "/\[neutron\]/a \
url = http://$THISHOST_NAME:9696\n\
auth_strategy = keystone\n\
admin_auth_url = http://$THISHOST_NAME:35357/v2.0\n\
admin_tenant_name = service\n\
admin_username = neutron\n\
admin_password = $SERVICE_PWD\n\
service_metadata_proxy = True\n\
metadata_proxy_shared_secret = $META_PWD" /etc/nova/nova.conf

#start nova
su -s /bin/sh -c "nova-manage db sync" nova

systemctl enable openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service
systemctl start openstack-nova-api.service openstack-nova-cert.service \
  openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service openstack-nova-novncproxy.service

#create keystone entries for neutron
keystone user-create --name neutron --pass $SERVICE_PWD
keystone user-role-add --user neutron --tenant service --role admin
keystone service-create --name neutron --type network \
  --description "OpenStack Networking"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ network / {print $2}') \
  --publicurl http://$THISHOST_NAME:9696 \
  --internalurl http://$THISHOST_NAME:9696 \
  --adminurl http://$THISHOST_NAME:9696 \
  --region regionOne

#install neutron
yum -y install openstack-neutron openstack-neutron-ml2 python-neutronclient openswan openstack-neutron-vpn-agent which

#edit /etc/neutron/neutron.conf
sed -i.bak "/\[database\]/a \
connection = mysql://neutron:$SERVICE_PWD@$THISHOST_NAME/neutron" /etc/neutron/neutron.conf

SERVICE_TENANT_ID=$(keystone tenant-list | awk '/ service / {print $2}')

sed -i '0,/\[DEFAULT\]/s//\[DEFAULT\]\
rpc_backend = rabbit\
rabbit_host = '"$THISHOST_NAME"'\
rabbit_password = '"$SERVICE_PWD"'\
auth_strategy = keystone\
core_plugin = ml2\
service_plugins = neutron.services.vpn.plugin.VPNDriverPlugin,neutron.services.loadbalancer.plugin.LoadBalancerPlugin,neutron.services.firewall.fwaas_plugin.FirewallPlugin,router\
allow_overlapping_ips = True\
notify_nova_on_port_status_changes = True\
notify_nova_on_port_data_changes = True\
nova_url = http:\/\/'"$THISHOST_NAME"':8774\/v2\
nova_admin_auth_url = http:\/\/'"$THISHOST_NAME"':35357\/v2.0\
nova_region_name = regionOne\
nova_admin_username = nova\
nova_admin_tenant_id = '"$SERVICE_TENANT_ID"'\
nova_admin_password = '"$SERVICE_PWD"'/' /etc/neutron/neutron.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = neutron\n\
admin_password = $SERVICE_PWD" /etc/neutron/neutron.conf

#edit /etc/neutron/plugins/ml2/ml2_conf.ini
sed -i "/\[ml2\]/a \
type_drivers = flat,gre\n\
tenant_network_types = gre\n\
mechanism_drivers = openvswitch" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[ml2_type_gre\]/a \
tunnel_id_ranges = 1:1000" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[securitygroup\]/a \
enable_security_group = True\n\
enable_ipset = True\n\
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver" /etc/neutron/plugins/ml2/ml2_conf.ini

sed -i "/\[DEFAULT\]/a \
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver" /etc/neutron/vpn_agent.ini

sed -i "/\[vpnagent\]/a \
vpn_device_driver=neutron.services.vpn.device_drivers.ipsec.OpenSwanDriver" /etc/neutron/vpn_agent.ini

sed -i "/\[ipsec\]/a \
ipsec_status_check_interval=60" /etc/neutron/vpn_agent.ini

sed -i "/\[fwaas\]/a \
driver = neutron.services.firewall.drivers.linux.iptables_fwaas.IptablesFwaasDriver\n\
enabled = True" /etc/neutron/fwaas_driver.ini

sed -i "/\[service_providers\]/a \
service_provider = FIREWALL:Iptables:neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver:default" /etc/neutron/neutron.conf

#start neutron
ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade juno" neutron
systemctl restart openstack-nova-api.service openstack-nova-scheduler.service \
  openstack-nova-conductor.service
systemctl enable neutron-server.service neutron-vpn-agent
systemctl start neutron-server.service neutron-vpn-agent

#stop firewall
systemctl stop firewalld
systemctl disable firewalld

#install dashboard
yum -y install openstack-dashboard httpd mod_wsgi memcached python-memcached

#edit /etc/openstack-dashboard/local_settings
sed -i.bak "s/ALLOWED_HOSTS = \['horizon.example.com', 'localhost'\]/ALLOWED_HOSTS = ['*']/" /etc/openstack-dashboard/local_settings
sed -i 's/OPENSTACK_HOST = "127.0.0.1"/OPENSTACK_HOST = "'"$THISHOST_NAME"'"/' /etc/openstack-dashboard/local_settings

#modify dashboard images
tar cvf /usr/share/openstack-dashboard/static/dashboard/img.tar.bak /usr/share/openstack-dashboard/static/dashboard/img
rm -rf /usr/share/openstack-dashboard/static/dashboard/img
cp img.tar /usr/share/openstack-dashboard/static/dashboard/
cd /usr/share/openstack-dashboard/static/dashboard/
tar xvf img.tar
cd ~/Controller_files/

#start dashboard
setsebool -P httpd_can_network_connect on
chown -R apache:apache /usr/share/openstack-dashboard/static
systemctl enable httpd.service memcached.service
systemctl start httpd.service memcached.service

#create keystone entries for cinder
keystone user-create --name cinder --pass $SERVICE_PWD
keystone user-role-add --user cinder --tenant service --role admin
keystone service-create --name cinder --type volume \
  --description "OpenStack Block Storage"
keystone service-create --name cinderv2 --type volumev2 \
  --description "OpenStack Block Storage"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ volume / {print $2}') \
  --publicurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --internalurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --adminurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --region regionOne
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ volumev2 / {print $2}') \
  --publicurl http://$THISHOST_NAME:8776/v2/%\(tenant_id\)s \
  --internalurl http://$THISHOST_NAME:8776/v2/%\(tenant_id\)s \
  --adminurl http://$THISHOST_NAME:8776/v2/%\(tenant_id\)s \
  --region regionOne

#install cinder controller
yum -y install openstack-cinder python-cinderclient python-oslo-db

#edit /etc/cinder/cinder.conf
sed -i.bak "/\[database\]/a connection = mysql://cinder:$SERVICE_PWD@$THISHOST_NAME/cinder" /etc/cinder/cinder.conf

sed -i "/\[DEFAULT\]/a \
rpc_backend = rabbit\n\
rabbit_host = $THISHOST_NAME\n\
rabbit_password = $SERVICE_PWD\n\
auth_strategy = keystone\n\
my_ip = $CONTROLLER_IP" /etc/cinder/cinder.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = cinder\n\
admin_password = $SERVICE_PWD" /etc/cinder/cinder.conf

#start cinder controller
su -s /bin/sh -c "cinder-manage db sync" cinder
systemctl enable openstack-cinder-api.service openstack-cinder-scheduler.service
systemctl start openstack-cinder-api.service openstack-cinder-scheduler.service

#create keystone entries for swift
keystone user-create --name swift --pass $SERVICE_PWD
keystone user-role-add --user swift --tenant service --role admin
keystone service-create --name swift --type object-store \
  --description "OpenStack Object Storage"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ object-store / {print $2}') \
  --publicurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --internalurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --adminurl http://$THISHOST_NAME:8776/v1/%\(tenant_id\)s \
  --region regionOne

mkdir -p /etc/swift

#get the configuration info
source config

keystone user-create --name heat --pass $ADMIN_PWD
keystone user-role-add --tenant service --user heat --role admin
keystone role-create --name heat_stack_user
keystone role-create --name heat_stack_owner
keystone service-create --name heat --type orchestration \
  --description "Orchestration"
keystone service-create --name heat --type cloudformation \
  --description "Orchestration"
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ orchestration / {print $2}') \
  --publicurl http://$THISHOST_NAME:8004/v1/%\(tenant_id\)s \
  --internalurl http://$THISHOST_NAME:8004/v1/%\(tenant_id\)s \
  --adminurl http://$THISHOST_NAME:8004/v1/%\(tenant_id\)s \
  --region regionOne
keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ cloudformation / {print $2}') \
  --publicurl http://$THISHOST_NAME:8004/v1 \
  --internalurl http://$THISHOST_NAME:8004/v1 \
  --adminurl http://$THISHOST_NAME:8004/v1 \
  --region regionOne


#install heat
yum -y install openstack-heat-api openstack-heat-api-cfn openstack-heat-engine \
python-heatclient

#edit /etc/heat/heat.conf
sed -i.bak "/\[database\]/a \
connection = mysql://heat:$SERVICE_PWD@$THISHOST_NAME/heat" /etc/heat/heat.conf

sed -i "/\[DEFAULT\]/a \
rpc_backend = rabbit\n\
rabbit_host = $THISHOST_NAME\n\
rabbit_password = $SERVICE_PWD\n\
auth_strategy = keystone\n\
heat_metadata_server_url = http://$CONTROLLER_IP:8000\n\
heat_waitcondition_server_url = http://$CONTROLLER_IP:8000/v1/waitcondition" /etc/heat/heat.conf

sed -i "/\[keystone_authtoken\]/a \
ath_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = heat\n\
admin_password = $SERVICE_PWD" /etc/heat/heat.conf

sed -i "/\[ec2authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0" /etc/heat/heat.conf

#populate The Orchestration database
su -s /bin/sh -c "heat-manage db_sync" heat

#Start the Orchestration services
systemctl enable openstack-heat-api.service openstack-heat-api-cfn.service \
openstack-heat-engine.service
systemctl start openstack-heat-api.service openstack-heat-api-cfn.service \
openstack-heat-engine.service

#Add Telemetry monitor

source admin_creds

#Install MongoDB 

yum -y install mongodb-server mongodb

#edit /etc/mongodb.conf
sed -i.bak "s/bind_ip = 127.0.0.0/bind_ip = $CONTROLLER_IP/g" /etc/mongodb.conf

systemctl enable mongod.service
systemctl start  mongod.service

#Create Ceilometer database
mongo --host controller --eval 'db = db.getSiblingDB("ceilometer");db.createUser({user:"ceilometer",pwd: "CEILOMETER_DBPASS",roles: [ "readWrite", "dbAdmin" ]})'


keystone user-create --name ceilometer --pass CEILOMETER_PASS
keystone service-create --name ceilometer --type metering --description "Telemetry"

keystone endpoint-create \
  --service-id $(keystone service-list | awk '/ identity / {print $2}') \
  --publicurl http://$THISHOST_NAME:8777 \
  --internalurl http://$THISHOST_NAME:8777 \
  --adminurl http://$THISHOST_NAME:8777 \
  --region regionOne

yum -y install openstack-ceilometer-api openstack-ceilometer-collector openstack-ceilometer-notification openstack-ceilometer-central openstack-ceilometer-alarm python-ceilometerclient

METERING_SECRET=$(openssl rand -hex 10 | awk '{print $1}')

#edit /etc/ceilometer/ceilometer.conf
sed -i.bak "/\[database\]/a \
connection = mongodb://ceilometer:$CEILOMETER_PWD@$THISHOST_NAME:27017/ceilometer" /etc/ceilometer/ceilometer.conf

sed -i "/\[DEFAULT\]/a \
rpc_backend = rabbit\n\
rabbit_host = $THISHOST_NAME\n\
rabbit_password = $SERVICE_PWD\n\
auth_strategy = keystone" /etc/ceilometer/ceilometer.conf

sed -i "/\[keystone_authtoken\]/a \
auth_uri = http://$THISHOST_NAME:5000/v2.0\n\
identity_uri = http://$THISHOST_NAME:35357\n\
admin_tenant_name = service\n\
admin_user = ceilometer\n\
admin_password = $SERVICE_PWD" /etc/ceilometer/ceilometer.conf


sed -i "/\[service_credentials\]/a \
os_auth_url = http://$THISHOST_NAME:5000/v2.0\n\
os_username = ceilometer\n\
os_tenant_name = service\n\
os_password = $SERVICE_PWD" /etc/ceilometer/ceilometer.conf


sed -i "/\[publisher\]/a \
metering_secret = $METERING_SECRET" /etc/ceilometer/ceilometer.conf

#start Telemetry

systemctl enable openstack-ceilometer-api.service openstack-ceilometer-notification.service openstack-ceilometer-central.service openstack-ceilometer-collector.service openstack-ceilometer-alarm-evaluator.service openstack-ceilometer-alarm-notifier.service

systemctl start openstack-ceilometer-api.service openstack-ceilometer-notification.service openstack-ceilometer-central.service openstack-ceilometer-collector.service openstack-ceilometer-alarm-evaluator.service openstack-ceilometer-alarm-notifier.service
