#!/usr/bin/perl
########################################################################################################
####                                                                                                ####
####                            [DAS] Device Activation System                                      ####
####                                                                                                ####
#### Device Activation from IBN Testing                                                             ####
#### Author : Jordan Rubin jordan.rubin@centurylink.com                                             ####
####                                                                                                #### 
#### Recieves workflow for DHCPackhandler in JSON Restfully.  After parsing the content             ####
#### it creates the activation object using activation module to run the functions of activation.   ####
#### activation.pm will either return success, or failure with XML formatted content to return to   ####
#### WORKFLOW with the ERROR NAME, DSP CODE, and the actual text of the error.                      ####    
########################################################################################################
####
#### 02/26/2025 - PRODUCTION ROLLOUT WORK

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
                "port"   : "TenGigE0/0/0/18",
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 29
        },
        "4" : {
                "port"   : "gi1/4",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 24
        },
        "5" : {
                "port"   : "gi1/5",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 24
        },
        "6" : {
                "port"   : "gi1/6",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 24
        },
        "7" : {
                "port"   : "gi1/7",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 24
        },
        "8" : {
                "port"   : "gi1/8",   
                "subnet" : "$workflow->{subnet}->[2]",
                "type"   : "user",
                "mask"   : 24
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
        $first =~ s/\Q$delimiter\E.*//;
        $last =~ s/\Q$delimiter\E.*//;
        my $pool = "$first".'-'."$last";
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
                        "max-valid-lifetime": 0,
                        "min-valid-lifetime": 0,
                        "valid-lifetime": 0,
                        "pools" :[
                                {
                                        "option-data" : [],
                                        "pool": "$pool"
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
        $req->authorization_basic("kea-api","keaapipa55w0rd");
        my $res = $ua->request($req);
        my $json_response = $res->decoded_content;
        my $decoded_response = decode_json($json_response);
        return $decoded_response;

}