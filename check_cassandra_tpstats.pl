#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2013-10-15 04:56:49 +0100 (Tue, 15 Oct 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#  

$DESCRIPTION = "Nagios Plugin to fetch Cassandra's thread pool stats by parsing 'nodetool tpstats'.

Checks Pending/Blocked operations against warning/critical thresholds.
Check the baseline first and then set appropriate thresholds since a build up of Pending/Blocked operations is indicative of performance problems.

Also returns Active and Dropped operations with perfdata for graphing.

Can specify a remote host and port otherwise it checks the local node's stats (for calling over NRPE on each Cassandra node)

Written and tested against Cassandra 2.0, DataStax Community Edition";

$VERSION = "0.3";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils;

my $nodetool = "nodetool";

my $host;
my $port;

my $default_warning  = 0;
my $default_critical = 0;

$warning  = $default_warning;
$critical = $default_critical;

%options = (
    "n|nodetool=s"  => [ \$nodetool, "Path to 'nodetool' command if not in \$PATH ($ENV{PATH})" ],
    "H|host=s"      => [ \$host,     "Cassandra node to connect to     (default: localhost)" ],
    "P|port=s"      => [ \$port,     "Cassandra JMX port to connect to (default: 7199)" ],
    "u|user=s"      => [ \$user,     "Cassandra JMX user (optional)" ],
    "p|password=s"  => [ \$password, "Cassandra JMX user (optional)" ],
    "w|warning=s"   => [ \$warning,  "Warning  threshold max (inclusive) for Pending/Blocked operations (default: $default_warning)"  ],
    "c|critical=s"  => [ \$critical, "Critical threshold max (inclusive) for Pending/Blocked operations (default: $default_critical)" ],
);

@usage_order = qw/nodetool host port user password warning critical/;
get_options();

$nodetool = validate_filename($nodetool, 0, "nodetool");
$nodetool =~ /(?:^|\/)nodetool$/ or usage "invalid path to nodetool, must end in nodetool";
which($nodetool, 1);
$host = validate_host($host) if defined($host);
$port = validate_port($port) if defined($port);
$user = validate_user($user) if defined($user);
if(defined($password)){
    $password =~ /^([^']+)$/ or usage "invalid password supplied, may not contain '";
    $password = $1;
    vlog_options "password", $password;
}
validate_thresholds(1, 1, { "simple" => "upper", "integer" => 1, "positive" => 1 } );

vlog2;
set_timeout();

$status = "OK";

my $options = "";
$options .= "--host '$host' " if defined($host);
$options .= "--port '$port' " if defined($port);
$options .= "--username '$user' " if defined($user);
$options .= "--password '$password' " if defined($password);
my $cmd = "${nodetool} ${options}tpstats";

my @output = cmd($cmd);

my $format_changed_err = "unrecognized line '%s', nodetool output format may have changed, aborting. ";
sub die_format_changed($){
    quit "UNKNOWN", sprintf("$format_changed_err$nagios_plugins_support_msg", $_[0]);
}

if($output[0] =~ /connection refused|unknown host|cannot|resolve|error|user|password/i){
    quit "CRITICAL", join(", ", @output);
}
$output[0] =~ /Pool\s+Name\s+Active\s+Pending\s+Completed\s+Blocked\s+All time blocked\s*$/i or die_format_changed($output[0]);
my @stats;
my $i = 1;
foreach(; $i < scalar @output; $i++){
    $output[$i] =~ /^\s*$/ and $i++ and last;
    $output[$i] =~ /^(\w+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$/ or die_format_changed($output[$i]);
    push(@stats,
        (
            { "$1_Blocked"          => $5, },
            { "$1_Pending"          => $3, },
            { "$1_Active"           => $2, },
            #{ "$1_Completed"        => $4, },
            #{ "$1_All_time_blocked" => $6, },
        )
    );
}
foreach(; $i < scalar @output; $i++){
    next if $output[$i] =~ /^\s*$/;
    last;
}

$output[$i] =~ /^Message type\s+Dropped/ or die_format_changed($output[$i]);
$i++;
my @stats2;
foreach(; $i < scalar @output; $i++){
    $output[$i] =~ /^(\w+)\s+(\d+)$/ or die_format_changed($output[$i]);
    push(@stats2,
        (
            { ucfirst(lc($1)) . "_Dropped" => $2 }
        )
    );
}

push(@stats2, @stats);

my $msg2;
my $msg3;
foreach(my $i = 0; $i < scalar @stats2; $i++){
    foreach my $stat3 ($stats2[$i]){
        foreach my $key (keys %$stat3){
            $msg2 = "$key=$$stat3{$key} ";
            $msg3 .= $msg2;
            if($key =~ /Pending|Blocked/i){
                unless(check_thresholds($$stat3{$key}, 1)){
                    $msg2 = uc $msg2;
                }
            }
            $msg .= $msg2;
        }
    }
}
$msg  =~ s/\s$//;
if($verbose or $status ne "OK"){
    msg_thresholds();
}
$msg .= "| $msg3";

quit $status, $msg;
