#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Temp qw(tempfile);

# Run inside the named container before ZNC starts. Keep users, networks, and
# authentication in the existing mutable config; Tailscale owns client TLS.
my ($path) = @ARGV;
die "Expected one ZNC config path\n" unless @ARGV == 1;
die "ZNC config must be a regular file\n" unless -f $path && !-l $path;
open(my $source, '<', $path) or die "Cannot open ZNC config\n";
my @metadata = stat($source);
local $/;
my $config = <$source>;
close($source) or die "Cannot close ZNC config\n";

my @matches;
my @blocks;
my %listener_offsets;
while ($config =~ m{^[ \t]*<(/?)([^> \t\r\n]+)(?:[ \t]+[^>\r\n]*)?>[ \t]*\r?$}gm) {
    my ($closing, $name, $offset) = ($1, lc($2), $-[0]);
    if ($closing) {
        die "Malformed ZNC config blocks\n" unless @blocks && pop(@blocks) eq $name;
    } else {
        $listener_offsets{$offset} = 1 if !@blocks && $name eq 'listener';
        push @blocks, $name;
    }
}
die "Unclosed ZNC config block\n" if @blocks;
while ($config =~ m{^<Listener[ \t]+[^>\r\n]+>[ \t]*\r?\n(.*?)^</Listener>[ \t]*(?:\r?\n|\z)}gmsi) {
    my ($start, $length, $body) = ($-[0], $+[0] - $-[0], $1);
    next unless $listener_offsets{$start};
    my @ports = $body =~ /^[ \t]*Port[ \t]*=[ \t]*([^\r\n]*?)[ \t]*\r?$/gmi;
    next unless grep { $_ eq '6697' } @ports;
    die "Ambiguous ZNC listener port\n" unless @ports == 1;
    die "Unexpected nested ZNC listener block\n" if $body =~ /^[ \t]*</m;
    my @ssl = $body =~ /^[ \t]*SSL[ \t]*=[ \t]*([^\r\n]*?)[ \t]*\r?$/gmi;
    die "Expected one explicit ZNC listener SSL setting\n"
        unless @ssl == 1 && $ssl[0] =~ /\A(?:true|false)\z/i;
    my $listener = substr($config, $start, $length);
    $listener =~ s/^([ \t]*SSL[ \t]*=[ \t]*)true([ \t]*\r?)$/${1}false$2/mi;
    push @matches, [$start, $length, $listener];
}
die "Expected exactly one ZNC listener on port 6697\n" unless @matches == 1;
my ($start, $length, $listener) = @{$matches[0]};
my $updated = $config;
substr($updated, $start, $length, $listener);
exit 0 if $updated eq $config;

# Atomic replacement in the same directory keeps partial writes out of the
# live config. The temporary file is private and removed on failure, with no
# backup of account credentials left behind.
my ($output, $temporary) = tempfile('.znc-tailscale-XXXXXX', DIR => dirname($path), UNLINK => 1);
print {$output} $updated or die "Cannot write ZNC config\n";
close($output) or die "Cannot close new ZNC config\n";
chown($metadata[4], $metadata[5], $temporary) == 1
    or die "Cannot preserve ZNC config owner\n";
chmod($metadata[2] & 07777, $temporary) == 1
    or die "Cannot preserve ZNC config permissions\n";
rename($temporary, $path) or die "Cannot replace ZNC config\n";
