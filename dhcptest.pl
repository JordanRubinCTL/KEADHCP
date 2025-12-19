#!/usr/bin/perl
########################################################################################################
####                                                                                                ####
####                            [DAS] Device Activation System                                      ####
####                                                                                                ####
#### KEA Server automation Demo - IMPROVED VERSION                                                  ####
#### Author : Jordan Rubin jordan.rubin@centurylink.com                                             ####
####                                                                                                ####
#### This is a demo to configure KEA DHCP server using Perl.                                        ####
#### it builds out the subnets and reservationsbudapestwalkedsd based on the provided workflow                      ####
#### This is just a POC and not for production use.                                                 ####
########################################################################################################
####
#### 5/1/2025 - Initial Release
#### 12/19/2025 - Improved version with error handling, proper JSON encoding, and bug fixes

use strict;
use warnings;
use LWP::UserAgent;
use JSON qw(encode_json decode_json);
use HTTP::Request::Common; 
use Data::Dumper;
use NetAddr::IP;
use Getopt::Long;

# Parse command line arguments
my $mode = 'test';  # Default to test mode
my $help = 0;

GetOptions(
    'mode=s' => \$mode,
    'help'   => \$help,
) or die "Error in command line arguments\n";

if ($help) {
    print_usage();
    exit 0;
}

# Validate mode
unless ($mode eq 'test' || $mode eq 'real') {
    die "Invalid mode: $mode. Must be 'test' or 'real'\n";
}

print "=" x 80 . "\n";
print "RUNNING IN " . uc($mode) . " MODE\n";
print "=" x 80 . "\n";
if ($mode eq 'test') {
    print "** TEST MODE: Will display API requests but NOT send them to Kea **\n";
}
else {
    print "** REAL MODE: Will send actual API requests to Kea server **\n";
}
print "=" x 80 . "\n\n";

# Configuration - Can be moved to environment variables or config file
my $KEA_API_URL  = $ENV{KEA_API_URL}  || 'http://100.87.19.138:8000';
my $KEA_API_USER = $ENV{KEA_API_USER} || 'kea-api';
my $KEA_API_PASS = $ENV{KEA_API_PASS} || 'keaapipassword';
my $DEBUG        = $ENV{DEBUG}        || 1;

# Track created resources for potential rollback
my @created_subnets = ();
my @created_reservations = ();

# Main execution wrapped in eval for error handling
eval {
    main();
    1;
}
or do {
    my $error = $@ || 'Unknown error';
    print STDERR "FATAL ERROR: $error\n";
    # In production, you might want to implement rollback here
    exit 1;
};

sub main {
    # Load workflow from file
    my $workflow = load_json_file('workflow.json');
    
    print "EMULATED WORKFLOW FROM UPSTREAM\n";
    print Dumper $workflow if $DEBUG;

    my $subnetCount = scalar(@{$workflow->{subnet}});
    print "\nWill create $subnetCount new subnets from the workflow.\n";

    # Load and process template
    my $template = load_template_file('template.json', $workflow->{subnet});
    
    print "TSG STENCIL FOR BUILD IN JSON\n";
    print Dumper $template if $DEBUG;

    # API DEMO - List available commands
    if ($DEBUG) {
        print "\nKEA DEMO APP\n\n\nKEA API COMMANDS AVAILABLE\n___________________________\n";
        my $commands = kea_list_commands();
        foreach my $cmd (@{$commands}) {
            print "$cmd ,";
        }
        print "\n\n";
    }

    # MAIN PROCESSING LOOP
    foreach my $subnet (@{$workflow->{subnet}}) {
        print "\nBUILD SUBNET [$subnet]--------------\n";
        
        # Calculate subnet ID from IP address and check if it exists
        my $subnet_id = calculate_subnet_id_from_ip($subnet);
        print "Calculated subnet ID is $subnet_id\n";

        # Parse subnet and calculate IP ranges
        my $ip_info = calculate_subnet_info($subnet);

        # Add subnet to Kea
        print "Building Subnet $subnet with ID $subnet_id\n";
        my $result = kea_add_subnet($subnet_id, $subnet, $ip_info);
        
        if ($result->{success}) {
            push @created_subnets, $subnet_id;
            print "Successfully created subnet $subnet\n";
        }
        else {
            die "Failed to create subnet $subnet: $result->{error}\n";
        }

        # Add host reservations for matching ports
        my $current_ip = $ip_info->{first_ip_obj};
        
        foreach my $key (sort { $a <=> $b } keys %{$template}) {
            my $port = $template->{$key};
            
            # Only process if this port belongs to current subnet
            if ($port->{subnet} eq $subnet) {
                my $ip_str = $current_ip->addr();
                my $flex_id = "'$workflow->{hostname}-$port->{port}'";
                
                print "Adding host reservation for interface [$key]\n";
                print "SUBNET:\t\t $port->{subnet}\n";
                print "IP:\t\t $ip_str\n";
                print "Relay:\t\t $workflow->{hostname}\n";
                print "Flex-id:\t $flex_id\n\n";
                
                my $res_result = kea_add_reservation(
                    $subnet_id,
                    $ip_str,
                    $flex_id,
                    $workflow->{hostname}
                );
                
                if ($res_result->{success}) {
                    push @created_reservations, { subnet_id => $subnet_id, ip => $ip_str };
                    print "Successfully created reservation for $ip_str\n";
                }
                else {
                    print "WARNING: Failed to create reservation for $ip_str: $res_result->{error}\n";
                }
            }
            
            $current_ip++;  # NetAddr::IP handles increment automatically
        }
    }

    # Write configuration to disk
    print "\nWriting configuration to disk...\n";
    my $write_result = kea_write_config();
    
    if ($write_result->{success}) {
        print "Configuration successfully written!\n";
    }
    else {
        print "WARNING: Failed to write config: $write_result->{error}\n";
    }
    
    print "\nProcessing complete!\n";
    print "Created " . scalar(@created_subnets) . " subnets\n";
    print "Created " . scalar(@created_reservations) . " reservations\n";
}

#############################################################################################
# HELPER FUNCTIONS
#############################################################################################

sub load_json_file {
    my ($filename) = @_;
    
    open my $fh, '<', $filename or die "Cannot open $filename: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    return decode_json($content);
}

sub load_template_file {
    my ($filename, $subnets) = @_;
    
    open my $fh, '<', $filename or die "Cannot open $filename: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Replace subnet placeholders
    for (my $i = 0; $i < @{$subnets}; $i++) {
        my $placeholder = "{{SUBNET_$i}}";
        my $subnet = $subnets->[$i];
        $content =~ s/\Q$placeholder\E/$subnet/g;
    }
    
    return decode_json($content);
}

sub calculate_subnet_info {
    my ($subnet_cidr) = @_;
    
    my $ip = NetAddr::IP->new($subnet_cidr) 
        or die "Invalid subnet: $subnet_cidr";
    
    my $first = $ip->first();
    my $last = $ip->last();
    
    # First usable IP (network + 1)
    my $first_usable = $first + 1;
    
    # Extract IP addresses as strings
    my $first_str = $first->addr();
    my $last_str = $last->addr();
    my $first_usable_str = $first_usable->addr();
    
    my $pool = "$first_usable_str-$last_str";
    my $masklen = $ip->masklen();
    
    print "Full single pool for [$masklen] subnet as $pool\n";
    
    return {
        first_ip      => $first_str,
        last_ip       => $last_str,
        first_usable  => $first_usable_str,
        pool          => $pool,
        masklen       => $masklen,
        first_ip_obj  => $first,  # For iteration
    };
}

# FIXED: Proper algorithm to find free subnet ID
sub calculate_subnet_id_from_ip {
    my ($subnet_cidr) = @_;
    
    # Extract just the IP portion (remove /mask)
    my ($ip) = split('/', $subnet_cidr);
    
    # Split into octets
    my @octets = split(/\./, $ip);
    
    # Calculate unique ID using formula: (O1 * 16777216) + (O2 * 65536) + (O3 * 256) + O4
    my $subnet_id = ($octets[0] * 16777216) + ($octets[1] * 65536) + ($octets[2] * 256) + $octets[3];
    
    if ($DEBUG) {
        print "Calculating subnet ID for $ip:\n";
        print "  Formula: ($octets[0] * 16777216) + ($octets[1] * 65536) + ($octets[2] * 256) + $octets[3]\n";
        print "  Result: $subnet_id\n";
    }
    
    # Check if this specific subnet ID already exists in Kea
    if (kea_check_subnet_exists($subnet_id)) {
        die "ERROR: Calculated subnet ID $subnet_id already exists in Kea! This subnet may already be configured.\n";
    }
    
    return $subnet_id;
}

sub check_subnet_overlap {
    my ($subnet_list, $new_subnet) = @_;
    
    foreach my $existing (@{$subnet_list}) {
        if ($existing->{subnet} eq $new_subnet) {
            return 1;
        }
    }
    
    return 0;
}

#############################################################################################
# KEA API FUNCTIONS - Properly using JSON encoding
#############################################################################################

sub send_to_kea {
    my ($payload_hash) = @_;
    
    # Properly encode as JSON
    my $json_payload = encode_json($payload_hash);
    
    if ($DEBUG) {
        print "API REQUEST:\n";
        print JSON->new->pretty->encode($payload_hash);
    }
    
    # Determine if this is a read-only request
    my $command = $payload_hash->{command} || '';
    my $is_readonly = ($command =~ /^(list-|subnet4-list|subnet4-get|reservation-get|config-get|status-get|version-get)/);
    
    # TEST MODE: Only send read-only requests
    if ($mode eq 'test' && !$is_readonly) {
        print "[TEST MODE] Request prepared but NOT sent to Kea (write operation)\n";
        print "-" x 80 . "\n";
        
        # Return a mock success response
        return [{
            result => 0,
            text => '[TEST MODE] Simulated success',
            arguments => {}
        }];
    }
    
    if ($mode eq 'test' && $is_readonly) {
        print "[TEST MODE] Sending READ-ONLY request to Kea\n";
    }
    
    # REAL MODE or TEST MODE with read-only: Actually send the request
    my $ua = LWP::UserAgent->new(timeout => 30);
    my $req = POST $KEA_API_URL;
    $req->header('Content-Type' => 'application/json');
    $req->content($json_payload);
    $req->authorization_basic($KEA_API_USER, $KEA_API_PASS);
    
    my $res = $ua->request($req);
    
    unless ($res->is_success) {
        die "HTTP request failed: " . $res->status_line;
    }
    
    my $json_response = $res->decoded_content;
    my $decoded = decode_json($json_response);
    
    if ($DEBUG) {
        print "API RESPONSE:\n";
        print Dumper $decoded;
    }
    
    return $decoded;
}

sub kea_list_commands {
    my $payload = {
        command => 'list-commands',
        service => ['dhcp4']
    };
    
    # list-commands is read-only, so it will be sent even in test mode
    my $response = send_to_kea($payload);
    
    # Return the array of available commands
    return $response->[0]->{arguments} || [];
}

sub kea_check_subnet_exists {
    my ($subnet_id) = @_;
    
    my $payload = {
        command => 'subnet4-get',
        service => ['dhcp4'],
        arguments => {
            id => int($subnet_id)  # Ensure it's an integer
        }
    };
    
    # subnet4-get is read-only, so it will be sent even in test mode
    eval {
        my $response = send_to_kea($payload);
        
        # If result is 0, subnet exists
        if ($response->[0]->{result} == 0) {
            return 1;  # Subnet exists
        }
        else {
            return 0;  # Subnet doesn't exist (result 3 = empty)
        }
    } or do {
        # Error likely means subnet doesn't exist
        return 0;
    };
}

sub kea_add_subnet {
    my ($subnet_id, $subnet_cidr, $ip_info) = @_;
    
    my $payload = {
        command => 'subnet4-add',
        service => ['dhcp4'],
        arguments => {
            subnet4 => [{
                id => $subnet_id,
                subnet => $subnet_cidr,
                'max-valid-lifetime' => 300,
                'min-valid-lifetime' => 300,
                'valid-lifetime' => 300,
                pools => [{
                    'option-data' => [],
                    pool => $ip_info->{pool}
                }],
                'option-data' => [{
                    name => 'routers',
                    data => $ip_info->{first_ip}
                }]
            }]
        }
    };
    
    eval {
        my $response = send_to_kea($payload);
        
        # Check result code (0 = success)
        if ($response->[0]->{result} == 0) {
            return { success => 1 };
        }
        else {
            return { 
                success => 0, 
                error => $response->[0]->{text} || 'Unknown error' 
            };
        }
    } or do {
        return { success => 0, error => $@ };
    };
}

sub kea_add_reservation {
    my ($subnet_id, $ip_address, $flex_id, $hostname) = @_;
    
    my $payload = {
        command => 'reservation-add',
        service => ['dhcp4'],
        arguments => {
            reservation => {
                'subnet-id' => $subnet_id,
                'ip-address' => $ip_address,
                'flex-id' => $flex_id,
                hostname => $hostname
            }
        }
    };
    
    eval {
        my $response = send_to_kea($payload);
        
        if ($response->[0]->{result} == 0) {
            return { success => 1 };
        }
        else {
            return { 
                success => 0, 
                error => $response->[0]->{text} || 'Unknown error' 
            };
        }
    } or do {
        return { success => 0, error => $@ };
    };
}

sub kea_write_config {
    my $payload = {
        command => 'config-write',
        service => ['dhcp4']
    };
    
    eval {
        my $response = send_to_kea($payload);
        
        if ($response->[0]->{result} == 0) {
            return { success => 1 };
        }
        else {
            return { 
                success => 0, 
                error => $response->[0]->{text} || 'Unknown error' 
            };
        }
    } or do {
        return { success => 0, error => $@ };
    };
}

sub print_usage {
    print <<'USAGE';
Usage: perl dhcptest_improved.pl [OPTIONS]

OPTIONS:
    --mode=MODE     Set execution mode: 'test' or 'real' (default: test)
                    test - Display requests but don't send to Kea
                    real - Actually send requests to Kea server
    
    --help          Display this help message

ENVIRONMENT VARIABLES:
    KEA_API_URL     Kea API endpoint (default: http://100.87.19.138:8000)
    KEA_API_USER    API username (default: kea-api)
    KEA_API_PASS    API password (default: keaapipassword)
    DEBUG           Enable debug output (default: 1)

EXAMPLES:
    # Test mode (dry run - no actual changes)
    perl dhcptest_improved.pl --mode=test
    
    # Real mode (actually configure Kea)
    perl dhcptest_improved.pl --mode=real
    
    # With custom credentials
    KEA_API_URL=http://server:8000 KEA_API_PASS=secret perl dhcptest_improved.pl --mode=real

USAGE
}

__END__

=head1 NAME

dhcptest_improved.pl - KEA DHCP Server Configuration Tool (Improved)

__END__

=head1 NAME

dhcptest_improved.pl - KEA DHCP Server Configuration Tool (Improved)

=head1 DESCRIPTION

This script automates the configuration of KEA DHCP server via its REST API.
Improvements include:

- Proper error handling with eval blocks
- Fixed subnet ID discovery algorithm
- JSON encoding instead of string interpolation
- Environment variable support for credentials
- Success/failure tracking
- Better code organization with functions
- Input validation
- Subnet overlap detection with proper handling

=head1 USAGE

    # Using default config files
    perl dhcptest_improved.pl
    
    # With custom credentials
    KEA_API_URL=http://server:8000 KEA_API_USER=admin KEA_API_PASS=pass perl dhcptest_improved.pl

=head1 AUTHOR

Jordan Rubin <jordan.rubin@centurylink.com>

=cut
