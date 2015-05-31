#!/bin/bash

#get the configuration info
source network_config



neutron net-create ext-net --shared --router:external True --provider:physical_network external --provider:network_type flat

neutron subnet-create ext-net --name ext-subnet --allocation-pool start=192.168.50.190,end=192.168.50.195 --disable-dhcp --gateway 192.168.50.1 192.168.50.0/24



