#!/usr/bin/perl
########################################################################################################
####                                                                                                ####
####                            [DAS] Device Activation System                                      ####
####                                                                                                ####
#### KEA Server automation Demo                                                                     ####
#### Author : Jordan Rubin jordan.rubin@centurylink.com                                             ####
####                                                                                                ####
#### This is a demo to configure KEA DHCP server using Go.                                          ####
#### it builds out the subnets and reservations based on the provided workflow                      ####
#### This is just a POC and not fir production use.                                                 ####
########################################################################################################
####
#### 5/1/2025 - Initial Release

# Never modify this......ever
use strict;
use warnings;
#use lib "../DASLIBS/";
#use lib "/app/perl5/lib/perl5";
#use MIME::Base64;
use LWP::UserAgent;             # User agent for RESTfull Interaction
use JSON qw(decode_json);       # JSON parsing and conversion for REST JSON based workflow
use HTTP::Request::Common; 
use Data::Dumper;
use NetAddr::IP;

my $debug = 1;

#WORKFLOW
my $workflow = qq^
{
        "hostname" : "LAB3COZSYJ001",
        "vendor"   : "Cisco",
        "model"    : "NCS540",
        "subnet"   : ["192.168.1.0/30", "192.168.1.4/30", "10.237.81.136/29"]
}^;

$workflow  = decode_json($workflow);
print "EMULATED WORKFLOW FROM UPSTREAM\n";
print Dumper $workflow;

my $subnetCount = scalar(@{$workflow->{subnet}});
print "\nWill create $subnetCount new subnets from the workflow.\n";

#TEMPLATE
my $tsgtemplate = qq^{
        "1" : {
                "port"   : "gi1/1", 
                "subnet" : "$workflow->{subnet}->[0]",
                "type"   : "mgmt",
                "mask"   : 30
        },
        "2" : {
                "port"   : "gi1/2",
                "subnet" : "$workflow->{subnet}->[1]",
                "type"   : "mgmt",
                "mask"   : 30
        },
        "3" : {
                "port"   : "18",
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 29
        },
        "4" : {
                "port"   : "26",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 29
        }
}^;
print "TSG STENCIL FOR BUILD IN JSON\n";
$tsgtemplate  = decode_json($tsgtemplate);
if ($debug) {print Dumper $tsgtemplate;}

#API DEMO
if ($debug) {print "\nKEA DEMO APP\n\n\nKEA API COMMANDS AVAILABLE\n___________________________\n";}

my $jsonPayload = qq^{"command":"list-commands", 
                        "service":["dhcp4"]
                     }^;

my $resp = sendtokea($jsonPayload);
foreach my $n (@{$resp->[0]->{arguments}}) {
        if ($debug){print "$n ,";}
}
if ($debug){print "\n\n";}



my $stupidId=1;

#BIGLOOP
foreach my $subnet (@{$workflow->{subnet}}) {
        print "\nBUILD SUBNET [$subnet]--------------\n";
        #LIST ALL SUBNETS IN SYSTEM
        $jsonPayload = qq^{
                "command": "subnet4-list",
                "service":["dhcp4"]
        }^;
        $resp = sendtokea($jsonPayload);
        if ($debug){print Dumper $resp;}
        my $subnetlist =  $resp->[0]->{arguments}->{subnets};
        my $startSubnetid = 1;
        my $freesubnet;
        foreach my $id (@{$subnetlist}) {
                if ($id->{id} eq $startSubnetid){
                        print "Subnet ID $id->{id} in use\n";
                        $startSubnetid++;
                        next;
                }
                else {
                        print "Subnet ID $id->{id} free\n";
                        $startSubnetid++;
                        last;
                }
        }
        print "First free subnet id is $startSubnetid\n";

        my $ipp = new NetAddr::IP($subnet);
        my $masklen = $ipp->masklen;
        my $mask = $ipp->mask;
        my $bcst = $ipp->broadcast;
        my $net = $ipp->network;
        my $first = $ipp->first;
        my $last = $ipp->last;
        my $thisip = NetAddr::IP->new($first);
        my $delimiter = '/';
        my $firstusable = $first+1;
        $first =~ s/\Q$delimiter\E.*//;
        $last =~ s/\Q$delimiter\E.*//;
        $firstusable =~ s/\Q$delimiter\E.*//;
        my $pool = "$firstusable".'-'."$last";
        print "Full single pool for [$masklen] subnet as $pool\n";

        foreach my $thisSUBNET  (@{$subnetlist}){
                if ($subnet eq $thisSUBNET->{subnet}){
                        print "subnet overlap for $subnet\n";
#                       exit;
                }
        }

        print "Building Subnet $subnet as index $stupidId\n";

        $jsonPayload = qq^{
        "command": "subnet4-add",
        "service":["dhcp4"],
        "arguments": {
                "subnet4": [ {
                        "id": $startSubnetid,
                        "subnet": "$subnet",
                        "max-valid-lifetime": 300,
                        "min-valid-lifetime": 300,
                        "valid-lifetime": 300,
                        "pools" :[
                                {
                                        "option-data" : [],
                                        "pool": "$pool"
                                }
                        ],
                        "option-data": [
                                {
                                        "name": "routers",
                                        "data": "$first"  
                                }              
                        ]
                } ]
        }
        }^;


if($debug){print "$jsonPayload ";}
my $resp = sendtokea($jsonPayload);

foreach my $key (sort keys %{$tsgtemplate}) {
        if ($tsgtemplate->{$key}->{subnet} eq $subnet) {
        my $myip = $thisip;
        my $flexid = "'$workflow->{hostname}".'-'."$tsgtemplate->{$key}->{port}'"; 
        $myip =~ s/\Q$delimiter\E.*//;
                print "Adding host reservation for interface [$key]\n";
                print "SUBNET:\t\t $tsgtemplate->{$key}->{subnet}\n";
                print "IP:\t\t $myip\n";
                print "Relay:\t\t $workflow->{hostname}\n\n";
                print "Flex-id: $flexid";
        #json for reservatiohn here
$jsonPayload = qq^{
    "command": "reservation-add",
    "service":["dhcp4"],
    "arguments": {
        "reservation": {
            "subnet-id": $startSubnetid,
            "ip-address": "$myip",
            "flex-id":"$flexid",
            "hostname" : "$workflow->{hostname}"
        }
    }
}^;
print "$jsonPayload\n";

$resp = sendtokea($jsonPayload);


print Dumper $resp;


        }
        $thisip++;

}


$stupidId++;


}
























$jsonPayload = qq^{
    "command": "config-write",
    "service":["dhcp4"]
}^;

 $resp = sendtokea($jsonPayload);


print Dumper $resp;


sub sendtokea{
        my $jsonPayload = shift;
        my $ua = LWP::UserAgent->new();
        my $req = POST 'http://100.87.19.138:8000';
        $req->header( 'Content-Type' => 'application/json' );
        $req->header( 'Content-Length' => length( $jsonPayload ) );
        $req->content( $jsonPayload );
        $req->authorization_basic("kea-api","keaapipassword");
        my $res = $ua->request($req);
        my $json_response = $res->decoded_content;
        my $decoded_response = decode_json($json_response);
        return $decoded_response;

}