#!/usr/bin/perl -w
use strict;
use Config;

use File::Path;
use File::Copy;
use File::Spec;

my $scriptdir = $Config{"installscript"};
my $top_lib = $Config{"installsitelib"};

my $glib = File::Spec->catfile($top_lib, "Games", "Rezrov");
unless (-d $glib) {
    mkpath($glib) || die "can't create $glib";
    # make Games::Rezrov directory
}

my @modules = glob("*.pm");
foreach my $module (@modules) {
    my $target_file = File::Spec->catfile($glib, $module);
    copy($module, $target_file) || die "can't copy $module to $target_file";
}
printf "Modules installed to: %s\n", $glib;

my $script_target = File::Spec->catfile($scriptdir, "rezrov");
copy("rezrov", $script_target) || die "can't copy rezrov to $script_target";
printf "rezrov installed to: %s\n", $script_target;





