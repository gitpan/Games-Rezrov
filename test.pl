#!/usr/local/bin/perl -w
#
# rezrov: a pure perl z-code interpreter; test script
#
# Copyright (c) 1998, 1999 Michael Edmonson.  All rights reserved.  
# This program is free software; you can redistribute it and/or modify 
# it under the same terms as Perl itself.
#

# standard modules:
use strict;
use 5.005;

# local modules:
use Games::Rezrov::StoryFile;
use Games::Rezrov::ZInterpreter;
use Games::Rezrov::ZOptions;
use Games::Rezrov::ZConst;

my %FLAGS;

use constant TK_VERSION_REQUIRED => 800;

use constant SPECIFIED => 1;
use constant DETECTING => 2;

use constant INTERFACES => (
			    ["tk", "Tk", \&tk_validate ],
			    ["win32", "Win32::Console"],
			    # look for Win32::Console before Curses
			    # because setscrreg() doesn't seem to work
			    # w/Curses for win32 (5.004 bindist)
			    ["curses", "Curses"],
			    ["termcap", [ "Term::Cap", "POSIX" ] ],
			    ["dumb" ],
			   );
# available interfaces

#
#  determine interface implementation to use:
#
my $zio_type = get_interface(DETECTING);
# guess the "best" interface

#
#  Figure out name of storyfile
#
my $storyfile = "minizork.z3";

die sprintf 'File "%s" does not exist.' . "\n", $storyfile
  unless (-f $storyfile);

#
#  Initialize selected i/o module
#
my $zio;

if ($zio_type eq "tk") {
  # GUI interface
  require Games::Rezrov::ZIO_Tk;
  unless (exists $FLAGS{"max-scroll"}) {
#    Games::Rezrov::ZOptions::MAXIMUM_SCROLLING(1);
  }
  $zio = new Games::Rezrov::ZIO_Tk(%FLAGS);
} elsif ($zio_type eq "win32") {
  # windows console
  require Games::Rezrov::ZIO_Win32;
  $zio = new Games::Rezrov::ZIO_Win32(%FLAGS);
} elsif ($zio_type eq "curses") {
  # smart terminal w/Curses
  require Games::Rezrov::ZIO_Curses;
  $zio = new Games::Rezrov::ZIO_Curses(%FLAGS);
} elsif ($zio_type eq "termcap") {
  # address terminal w/Term::Cap
  require Games::Rezrov::ZIO_Termcap;
  $zio = new Games::Rezrov::ZIO_Termcap(%FLAGS);
} else {
  # dumb terminal and/or limited perl installation
  require Games::Rezrov::ZIO_dumb;
  $FLAGS{"readline"} = 1 if (!exists($FLAGS{"readline"}) and exists $ENV{"TERM"});
  $zio = new Games::Rezrov::ZIO_dumb(%FLAGS);
}

my $story;

$SIG{"INT"} = sub {
  $zio->set_game_title(" ") if $story->game_title();
  #    $zio->fatal_error("Caught signal @_.");
  $zio->cleanup();
  exit 1;
};

Games::Rezrov::ZOptions::GUESS_TITLE(0) unless $zio->can_change_title();

#
#  Initialize story file
#
$story = new Games::Rezrov::StoryFile($storyfile, $zio);
Games::Rezrov::StoryFile::font_3_disabled(1) if $FLAGS{"no-graphics"};
my $z_version = Games::Rezrov::StoryFile::load(1);

1;
cont() unless $zio->set_version(($z_version <= 3 ? 1 : 0),
				\&cont);
# Tk version invokes cont() itself, as a callback, since Tk's MainLoop blocks.
# A better way???

sub cont () {
  Games::Rezrov::StoryFile::setup();
  # complete inititialization

  if ($FLAGS{"playback"}) {
    Games::Rezrov::StoryFile::input_stream(Games::Rezrov::ZConst::INPUT_FILE, $FLAGS{"playback"});
  }
  
  #
  #  Start interpreter
  #
  my $zi = new Games::Rezrov::ZInterpreter($zio);
}

sub tk_validate {
  # called to see if the version of the Tk module available on the system
  # is new enough.
  my $type = shift;
  if ($Tk::VERSION >= TK_VERSION_REQUIRED) {
    # OK
    return 1;
  } elsif ($type == SPECIFIED) {
    # user specifically asked to use Tk
    die sprintf "I need Tk %s or later, you seem to have version %s.  Pity.\n", TK_VERSION_REQUIRED, $Tk::VERSION;
  } elsif ($type == DETECTING) {
    # just trying to figure out whether we can use Tk; nope!
    return 0;
  } else {
    die;
  }

  return 1;
}

sub get_interface {
  my ($search_type) = @_;
 INTERFACE:
  foreach (INTERFACES) {
    my ($name, $modules, $validate_sub) = @{$_};
    my @modules = $modules ? 
      (ref $modules ? @{$modules} : ($modules)) : ();
    if ($search_type == SPECIFIED) {
      #
      # we're looking to see if the user specified a particular type
      #
      if ($FLAGS{$name}) {
	# they did (this one)
	foreach (@modules) {
	  my $cmd = 'use ' . $_ . ";";
#	  print STDERR "eval: $cmd\n";
	  eval $cmd;
	  die sprintf "You can't use -%s, as the module %s is not installed.\nPity.\n", $name, $_ if $@;
	}
	if ($validate_sub) {
	  next unless &$validate_sub($search_type);
	}
	return $name;
	# OK
      }
    } elsif ($search_type == DETECTING) {
      #
      #  we're trying to find the "nicest" interface to use.
      #
      if (@modules) {
	foreach (@modules) {
	  my $cmd = 'use ' . $_ . ";";
#	  print STDERR "eval: $cmd\n";
	  eval $cmd;
	  next INTERFACE if $@;
	}
	if ($validate_sub) {
	  next unless &$validate_sub($search_type);
	}
	return $name;
	# OK
      } else {
	# no requirements, OK
	return $name;
      }
    } else {
      die;
    }
  }
  return undef;
}
