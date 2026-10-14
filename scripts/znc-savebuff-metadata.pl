#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Glob qw(bsd_glob);

# macOS creates AppleDouble resource-fork files on exFAT. ZNC savebuff tries
# to decrypt every directory entry and clears its key on the first invalid one.
# Preserve verified metadata outside savebuff; never touch actual saved buffers.
my ($root) = @ARGV;
die "Expected one ZNC state directory\n" unless @ARGV == 1 && -d $root && !-l $root;
my $count = 0;
for my $path (bsd_glob("$root/users/*/networks/*/moddata/savebuff/._*")) {
    die "Unexpected savebuff metadata type\n" unless -f $path && !-l $path;
    open(my $source, '<', $path) or die "Cannot read savebuff metadata\n";
    binmode($source);
    my $header;
    my $length = read($source, $header, 4);
    close($source) or die "Cannot close savebuff metadata\n";
    next unless defined($length) && $length == 4 && $header eq pack('H*', '00051607');
    my $relative = substr($path, length($root) + 1);
    my $destination = "$root/.appledouble-savebuff/$relative";
    die "Savebuff metadata archive already exists\n" if -e $destination || -l $destination;
    make_path(dirname($destination), {mode => 0700});
    rename($path, $destination) or die "Cannot preserve savebuff metadata\n";
    $count++;
}
print "Preserved $count AppleDouble savebuff metadata files\n" if $count;
