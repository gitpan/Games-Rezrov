#!/usr/local/bin/perl -w
#
# rezrov: a pure perl z-code interpreter
#
# Copyright (c) 1998, 1999 Michael Edmonson.  All rights reserved.  
# This program is free software; you can redistribute it and/or modify 
# it under the same terms as Perl itself.
#

# standard modules:
use strict;
use Getopt::Long;
use 5.004;

# local modules:
use Games::Rezrov::StoryFile;
use Games::Rezrov::ZInterpreter;
use Games::Rezrov::ZOptions;
use Games::Rezrov::ZConst;

$main::VERSION = $main::VERSION = '0.15';
# twice to shut up perl -w

my %FLAGS;

use constant TK_VERSION_REQUIRED => 800;

use constant SPECIFIED => 1;
use constant DETECTING => 2;

use constant OPTIONS =>
  (
   # interface selection:
   "tk",
   "dumb",
   "curses",
   "termcap",
   "win32",
     
   "game=s",
   # game to run

   # color control options:
   "fg=s",
   "bg=s",
   "sfg=s",
   "sbg=s",
   "cc=s",
   
   # font control (tk only):
   "fontsize=i",
   "family=s",

   # tk-related graphics options
   "x=i",
   "y=i",
   "fontspace=i",
   "blink=i",

   # other interface controls:
   "no-title",
   "rows=s",
   "columns=s",
   "max-scroll",
   "flaky=i",

   # other
   "highlight-objects",
   "cheat",
   "snoop-obj",
   "snoop-properties",
   "snoop-attr-set",
   "snoop-attr-test",
   "snoop-attr-clear",
   "count-opcodes",
   "debug:s",
   "undo=i",
   "readline=i",
   "playback=s",
   "id=i",
   "tandy",
   "hack",
   "shameless=i",
  );

die sprintf("Legal options are:\n  %s\nSee \"perldoc rezrov\" for documentation.\n", join "\n  ",
	    sort map {"-" . $_} OPTIONS)
  unless (GetOptions(\%FLAGS, OPTIONS));

if ($FLAGS{"fg"} or $FLAGS{"bg"}) {
  die "You must specify both -fg and -bg\n" unless $FLAGS{"fg"} and $FLAGS{"bg"};
}

#
# set options:
#
Games::Rezrov::ZOptions::SNOOP_OBJECTS($FLAGS{"snoop-obj"} ? 1 : 0);
Games::Rezrov::ZOptions::SNOOP_ATTR_CLEAR($FLAGS{"snoop-attr-clear"} ? 1 : 0);
Games::Rezrov::ZOptions::SNOOP_ATTR_SET($FLAGS{"snoop-attr-set"} ? 1 : 0);
Games::Rezrov::ZOptions::SNOOP_ATTR_TEST($FLAGS{"snoop-attr-test"} ? 1 : 0);
Games::Rezrov::ZOptions::SNOOP_PROPERTIES($FLAGS{"snoop-properties"} ? 1 : 0);

Games::Rezrov::ZOptions::GUESS_TITLE($FLAGS{"no-title"} ? 0 : 1);
Games::Rezrov::ZOptions::MAXIMUM_SCROLLING($FLAGS{"max-scroll"} ? 1 : 0);
Games::Rezrov::ZOptions::COUNT_OPCODES($FLAGS{"count-opcodes"} ? 1 : 0);
Games::Rezrov::ZOptions::WRITE_OPCODES(exists $FLAGS{"debug"} ? $FLAGS{"debug"} || "STDERR" : 0);

if (exists $FLAGS{"undo"}) {
  Games::Rezrov::ZOptions::EMULATE_UNDO($FLAGS{"undo"});
  Games::Rezrov::ZOptions::UNDO_SLOTS($FLAGS{"undo"});
} else {
  Games::Rezrov::ZOptions::EMULATE_UNDO(1);
  Games::Rezrov::ZOptions::UNDO_SLOTS(10);
}

Games::Rezrov::ZOptions::MAGIC(exists $FLAGS{"cheat"} ? 1 : 0);
Games::Rezrov::ZOptions::HIGHLIGHT_OBJECTS(exists $FLAGS{"highlight-objects"} ? 1 : 0);
Games::Rezrov::ZOptions::INTERPRETER_ID($FLAGS{"id"}) if exists $FLAGS{"id"};
Games::Rezrov::ZOptions::TANDY_BIT(1) if exists $FLAGS{"tandy"};
Games::Rezrov::ZOptions::SHAMELESS($FLAGS{"shameless"}) if exists $FLAGS{"shameless"};

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
my $zio_type = get_interface(SPECIFIED);
# check if user specified one
$zio_type = get_interface(DETECTING) unless $zio_type;
# none specified; guess the "best" one

#
#  Figure out name of storyfile
#
my $storyfile;
if ($FLAGS{"game"}) {
  $storyfile = $FLAGS{"game"};
} elsif (@ARGV) {
  $storyfile = $ARGV[0];
} elsif ($0 eq "test.pl") {
  # being run under "make test"
  $storyfile = "minizork.z3";
} else {
  die "You must specify a game file to interpret; e.g. \"rezrov zork1.dat\".\n";
}

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
my $z_version = $story->load(1);

cont() unless $zio->set_version($story,
				($z_version <= 3 ? 1 : 0),
				\&cont);
# Tk version calls cont() itself, since MainLoop blocks...
# better way??

sub cont () {
  $story->setup();
  # complete inititialization

  if ($FLAGS{"hack"}) {
    # for debugging
    $story->get_property_addr(500,22);
    die;
  }
  
  if ($FLAGS{"playback"}) {
    $story->input_stream(Games::Rezrov::ZConst::INPUT_FILE, $FLAGS{"playback"});
  }
  
  #
  #  Start interpreter
  #
  my $zi = new Games::Rezrov::ZInterpreter($story, $zio);
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

__END__

=head1 NAME

rezrov - a pure Perl Infocom (z-code) game interpreter

=head1 SYNOPSIS

rezrov game.dat [flags]

=head1 DESCRIPTION

Rezrov is a program that lets you play Infocom game data files.
Infocom's data files (e.g. "zork1.dat") are actually
platform-independent "z-code" programs written for a virtual machine
known as the "z-machine".  Rezrov is a z-code interpreter which can
run programs written z-code version 3 (nearly complete support),
version 4 (partial support), and version 5 (very limited support).

=head1 INTERFACE

I/O operations have been abstracted to allow the games to be playable
through any of several front-end interfaces.  Normally rezrov tries to
use the "best" interface depending on the Perl modules available on
your system, but you can force the use of any of them manually.

=head2 Dumb

Designed to work on almost any perl installation.  Optionally uses
Term::ReadKey and/or local system commands to guess the terminal size,
clear the screen, and read the keyboard.  While there is no status
line or multiple window support, this interface is perfectly adequate
for playing most version 3 games.  Can be forced with "-dumb".

=head2 Termcap

Makes use of the standard Term::Cap module to provide support for a
status line and multiple windows.  I've had difficulties making the
last line on the display usable while reading from STDIN or
Term::ReadLine; it seems the line-terminating newline entered by the
user scrolls the screen, wiping out the status line.  Maybe there's a
simple termcap feature to help with this; advice would be appreciated.

So, by default the termcap interface avoids using the last line on
your display.  There's an experimental workaround you can try that
doesn't seem to work on all systems; enable it by specifying "-flaky
1" on the command line.  This will only work if the program can figure
out how to read characters one at a time from the terminal, and it
also breaks Term::ReadLine support.

Usage of the Termcap interface can be forced with "-termcap".

=head2 Curses

Use the Curses module to improve the features available in the Termcap
interface, adding support for color, clean access to all the lines on
the screen and better keyboard handling.  Some problems remain: if you
specify screen colors, the terminal may not be reset correctly when
the program exits.  Also, I've only tested this with a few versions of
Curses (Linux/ncurses and Digital Unix's OEM curses), and was
unpleasantly surprised by the difficulties I encountered getting this
to work properly under both of them.  Can be forced with "-curses".

=head2 Windows console

Uses the Win32::Console module to act much like the Curses version.
Only works under win32 (Windows 95, 98, etc).  Force with "-win32".

=head2 Tk

Uses the Tk module; supports variable-width and fixed fonts and color.
Requires the 800+ series of Tk; tested under Linux and the ActiveState
binary distribution of perl under win32.

=head1 FEATURES

=head2 Advanced command emulation

Rezrov emulates a number of in-game commands which were either not or
only sporadically available in version 3 games:

=over 4

=item *

B<undo>: undoes your previous turn.  This allows you to recover from
foolish or irresponsible behavior (walking around in the dark, jumping
off cliffs, etc) without a saved game.  You can undo multiple turns by
repeatedly entering "undo"; the -undo switch can be used to specify
the maximum number of turns that may be undone (default is 10).

=item *

B<oops>: allows you to specify the correct spelling for a word you
misspelled on the previous line.  For example:

  >give lmap to troll
  I don't know the word "lmap".
  
  >oops lamp
  The troll, who is not overly proud, graciously accepts the
  gift and not having the most discriminating tastes,       
  gleefully eats it.                                        
  You are left in the dark...   

=item *

B<notify>: has the game tell you when your score goes up or down.  This
is especially useful when playing without a status line (ie with the
"dumb" interface).

=item *

B<#reco>: Writes a transcript of the commands you enter to the file
you specify.

=item *

B<#unre>: Stops transcripting initiated by the #reco command.

=item *

B<#comm>: Plays back commands from the transcript file you specify.
You can also start a game with recorded commands by specifying the
"-playback" command-line option.

=back


Rezrov also expands the following "shortcut" commands for games
that do not support them:

    x = "examine"
    g = "again"
    z = "wait"
    l = "look"
    o = "oops"

=head2 Cheating

The "-cheat" command-line parameter enables the interpretation of
several fun new verbs.  Using these commands in a game you haven't
played honestly will most likely ruin the experience for you.
However, they can be entertaining to play around with in games you
already know well.  Note that none of them work if the game
understands the word they use; for example, "Zork I" defines "frotz"
in its dictionary (alternate verbs are available).  You can turn
cheating on and off within the game by entering "#cheat".

=over 4

=item *

B<teleport, #teleport>: moves you to any room in the game.  For example:
"teleport living room".  Location names are guessed so they all might
not be available; see "rooms" command below.  If you specify the name
of an item, rezrov will attempt to take you to the room where the
item is located.

=item *

B<pilfer>: moves any item in the game to your current location, and
then attempts to move it into your inventory.  For example: "pilfer
sword".  Doesn't work for some objects (for example, the thief from
Zork I).  Can be dangerous -- for example, pilfering the troll from
Zork I can be hazardous to your health.

I'd be very curious to know about any easter eggs this command might
uncover.  For example, I remember in Planetfall there was a
blacked-out room you couldn't see in.  There was a lamp, but it was in
a lab full of deadly radiation -- you could enter the lab and take the
lamp, but would die of radiation poisoning before you could get back
to the darkened room.  I always wondered, if you could get the lamp
somehow, what was in the dark room?  Now you can find out.

=item *

B<bamf>: makes the object you specify disappear from the game.  For
example: "bamf troll".  This works nicely for some objects but less so
for others.  For example, in Zork I the troll disappears obligingly,
but the bamf'ing the cyclops doesn't help.

=item *

B<frotz, futz, lumen>: attempts to emulate the "frotz" spell from
Enchanter, which means "cause something to give off light."  It can
turn any item into a light source, thus obviating the need to worry
about your lamp/torch running out while you wander around in the dark.
I would have liked to just use the word "frotz"; unfortunately Zorks
I-III define that word in their dictionaries (interesting, as these
games predate Enchanter), and I am reluctant to interfere with its
"original" use in those games (if any?).

While this is just a simple tweak, turning on a particular object
property, exactly *which* property varies by game and I know of no
easy way to determine this dynamically, so at present this only works
in a few games: Zork I, Zork II, Zork III, and Infidel (I'm taking
requests).

=item *

B<tail>: follow a character in the game -- as they move from room to
room, so do you.  Also allows you to follow characters where you
ordinarily aren't allowed to, for example the unlucky Veronica in
"Suspect".

=item *

B<travis>: attempts to fool the game into thinking the object
you specify is a weapon.  Like "frotz" this is very game-specific; it
only works in Zork I at present:

    >i
    You are carrying:                        
      A brass lantern (providing light)
      A leaflet

    >north
    The Troll Room
    This is a small room with passages to the east and south
    and a forbidding hole leading west. Bloodstains and deep
    scratches (perhaps made by an axe) mar the walls.
    A nasty-looking troll, brandishing a bloody axe, blocks all
    passages out of the room.

    >kill troll with leaflet                         
    Trying to attack the troll with a leaflet is suicidal.

    >travis leaflet
    The leaflet glows wickedly.                             

    >kill troll
    (with the leaflet)                                         
    Your leaflet misses the troll by an inch.                               
    The axe crashes against the rock, throwing sparks!

    >g
    You charge, but the troll jumps nimbly aside.
    The troll's axe barely misses your ear.

    >g
    It's curtains for the troll as your leaflet removes his head.
    Almost as soon as the troll breathes his last breath, a
    cloud of sinister black fog envelops him, and when the fog
    lifts, the carcass has disappeared.

    >

=item *

B<lingo>: prints out all the words in the dictionary.

=item *

B<rooms>: print a list of rooms/locations in the game.  This is a
rough guess based on descriptions taken from the game's object table,
and so may contain a few mistakes.

=item *

B<items>: print a list of items in the game.  Like "rooms", this is a
rough guess based on descriptions taken from the game's object table.

=item *

B<omap>: prints a report of the objects in the game, indented by
parent-child relationship.

=item *

B<embezzle>: sets your score in version 3 games to the value you
specify.  Useful for "finishing" games in a hurry.  You could use this
to quickly see the effects of the Tandy bit on the ending of Zork I,
for example.

=back

=head2 Snooping

Several command-line flags allow you to observe some of the internal
machinations of your game as it is running.  These options will
probably be of limited interest to most people, but may be the
foundation of future trickery.

=over 4

=item B<-snoop-obj>

Whenever an object in the game is moved, it tells you the name
of the object and where it was moved to.  Using this feature
you can, among other things, see the name Infocom assigned to
the "player" object in a number of their early games:

 West of House
 There is a small mailbox here.

 >north
 [Move "cretin" to "North of House"]
 North of House                     
 You are facing the north side of a white house. There is no
 door here, and all the windows are boarded up. To the north
 a narrow path winds through the trees.

=item B<-snoop-properties>

Each object in the game has a list of properties associated with it.
This flag lets you see when object properties are changed.  As an
example, in my version of Zork 1 the "blue glow" given off by the
sword in the presence of enemies is property number 12 (1 for "a faint
blue glow" and 2 for "glowing very brightly").

=item B<-snoop-attr-set>

Likewise, each object has an associated list of single-bit attributes.
This flag lets you observe when object attributes are set.  As an
example, in my version of Zork I the "providing light" attribute is
number 20.

=item B<-snoop-attr-test>

This option lets you see when object attributes are tested.

=item B<-snoop-attr-clear>

This option lets you see when object attributes are cleared.

=item B<-highlight-objects>

Highlights object descriptions in the text printed out via the
B<print_obj> opcode (1OP, 0x0a).

=back

=head2 Interface flags

=over 4

=item B<-fg, -bg>

If the interface you want to use supports colored text, this allows
you to specify foreground (text) and background colors used in the
game.  If you specify one you must specify the other, i.e. you cannot
specify just the foreground or background color.  Example: "-fg white
-bg blue".

When using the Curses interface, allowable colors are black, blue,
cyan, green, magenta, red, white, and yellow.

When using the Win32::Console interface, allowable colors are black,
blue, lightblue, red, lightred, green, lightgreen, magenta,
lightmagenta, cyan, lightcyan, brown, yellow, gray, and white.  Note
that the program tries to shift to lighter colors to simulate "bold"
text attributes: bold blue text uses lightblue, bold gray text uses
white, etc.  For this reason it looks best if you not use white or any
of the "light" colors directly (for "white" text, specify "gray").

=item B<-sfg, -sbg>

Specifies the foreground and background colors use for the status line
in version 3 games; the same restrictions apply as to -fg and -bg.
These must also be used as a pair, and -fg and -bg must be specified
as well.  Example: "-fg white -bg blue -sbg black -sfg white".

=item B<-cc>

Specifies the color of the cursor.  At present this only works for the
Tk interface, and defaults to black.  Note: if the game changes the
screen's background color to the cursor color, the cursor color will
be changed to the foreground color to prevent it from "disappearing".

=item B<-columns, -rows>

Allows you to manually specify the number of columns and/or lines in
your display.

=item B<-max-scroll>

Updates the screen with every line printed, so scrolling is always
visible.  As this disables any screen buffering provided by the I/O
interface it will slow things down a bit, but some people might like
the visual effect.

=back

=head2 Tk-specific flags

=over 4

=item B<-family [name]>

Specifies the font family to use for variable-width fonts.  Under
win32, this defaults to "Times New Roman".  On other platforms
defaults to "times".

=item B<-fontsize [points]>

Specifies the size of the font to use, as described in Tk::Font.
Under win32 this defaults to 10, on other platforms it defaults to 18.
If your fonts have a "jagged" appearance under X you should probably
experiment with this value; for best results this should match a
native font point size on your system.

=item B<-blink [milliseconds]>

Specifies the blink rate of the cursor, in milliseconds.
The default is 1000 (one second).  To disable blinking entirely,
specify a value of 0 (zero).

=item B<-x [pixels]>

Specifies the width of the text canvas, in pixels.  The default
is 70% of the screen's width.

=item B<-y [pixels]>

Specifies the height of the text canvas, in pixels.  The default
is 60% of the screen's height.

=back

=head2 Term::ReadLine support

If you have the Term::ReadLine module installed, support for it is
available in the dumb, termcap, and curses interfaces.  By default
support is enabled in the "dumb" module, and disabled in the termcap
and curses interfaces (because it doesn't work right C<:P> ).  You can
enable/disable support for it with the "-readline" flag: "-readline 1"
enables support, and "-readline 0" disables it.

=head2 Miscellaneous flags

=over 4

=item B<-debug [file]>

Writes a log of the opcodes being executed and their arguments.  If a
filename is specified, the log is written to that file, otherwise it
is sent to STDERR.

=item B<-count-opcodes>

Prints a count and summary of the opcodes executed by the game between
your commands.

=item B<-undo turns>

Specifies the number of turns that can be undone when emulating the
"undo" command; the default is 10 turns.

Undo emulation works by creating a temporary saved game in memory
between every command you enter.  To disable undo emulation entirely,
specify a value of zero (0).

=item B<-playback file>

When the game starts, reads commands from the file specified instead
of the keyboard.  Control is returned to the keyboard when there are
no more commands left in the file.

=item B<-no-title>

Disables rezrov's attempts to guess the name of the game you're
playing for use in the title bar.  To guess the title, rezrov actually
hijacks the interpreter before your first command, submitting a
"version" command and parsing the game's output.  This can slow the
start of your game by a second or so, which is why you might want to
turn it off.  This also currently causes problems with the Infocom
Sampler (sampler1_R55.z3) and Beyond Zork.

=item B<-id>

Specifies the ID number used by the interpreter to identify itself to
the game.  See section 11.1.3 of Graham Nelson's z-machine
specification (see acknowledgments section) for a list of interpreter
identifiers.  The default is 6, IBM PC.

=head1 GOALS

My primary goal has been to write a z-code interpreter in Perl which
is competent enough to play my favorite old Infocom games, which are
mostly z-code version 3.  Infocom's version 3 games are Ballyhoo,
Cutthroats, Deadline, Enchanter, The Hitchhiker's Guide To The Galaxy,
Hollywood Hijinx, Infidel, Leather Goddesses of Phobos, The Lurking
Horror, Moonmist, Planetfall, Plundered Hearts, Seastalker, Sorcerer,
Spellbreaker, Starcross, Stationfall, Suspect, Suspended, Wishbringer,
The Witness, and Zork I, II, and III.  These all seem to work pretty
well under the current interpreter.

Version 4 and later games introduce more complex screen handling and
difficult-to-keep-portable features such as timed input.  Later games
also introduce a dramatic increase in the number of opcodes executed
between commands, making a practical implementation more problematic.
For example, consider the number of opcodes executed by the
interpreter to process a single "look" command:

                             Zork 1 (version 3):  387 opcodes
                            Trinity (version 4):  905 opcodes
 Zork: The Undiscovered Underground (version 5): 2186 opcodes (!)

If you seriously want to *play* these later games, I recommend you use
an interpreter written in C, such as frotz or zip; these are much
faster and more accurate than rezrov.  Come to think of it, this
really is a silly undertaking, but hey -- it had to be done.

A secondary goal has been to produce a relatively clean,
compartmentalized implementation of the z-machine that can be read
along with the Specification (see acknowledgments section).  Though
the operations of the interpreter are broken into logical packages,
performance considerations have kept me from strict OOP; more static
variables remain than I'd like.  The Perl version is actually based on
my original version of rezrov, which was written in Java.

=head1 ACKNOWLEDGMENTS

rezrov would not have been possible to write without the work of the
following individuals:

=over 4

=item *

B<Graham Nelson> for his amazing z-machine specification:

 http://www.gnelson.demon.co.uk/zspec/

=item *

B<Marnix Klooster> for "The Z-Machine, and How to Emulate It",
a critical second point of view on the spec:

 ftp://ftp.gmd.de/if-archive/infocom/interpreters/specification/zmach06e.txt

=item *

B<Mark Howell> for his "zip" interpreter, whose source code made
debugging all my stupid mistakes possible:

 ftp://ftp.gmd.de/if-archive/infocom/interpreters/zip

=item *

B<Martin Frost> for his Quetzal universal save-game file format, which is
implemented by rezrov:

 ftp://ftp.gmd.de/if-archive/infocom/interpreters/specification/savefile_14.txt

=item *

B<Andrew Plotkin> for "TerpEtude" (etude.z5), his suite of z-machine
torture tests.

=item *

B<Torbjorn Andersson> for his "strictz.z5", a suite of torture tests for
the (nonexistent) object 0.

=item *

The folks at the B<IF-archive> for their repository:

 ftp://ftp.gmd.de/if-archive/README

=item *

B<William Seltzer> for Curses.pm, B<"sanders@bsdi.com"> for Term::Cap,
B<Aldo Calpini> for Win32::Console, and of course B<Larry Wall> and
the perl development team for Perl.

=item *

And lastly, the mighty Implementers:

 >read dusty book
 The first page of the book was the table of contents. Only
 two chapter names can be read: The Legend of the Unseen   
 Terror and The Legend of the Great Implementers.          

 >read legend of the implementers
 This legend, written in an ancient tongue, speaks of the
 creation of the world. A more absurd account can hardly be
 imagined. The universe, it seems, was created by          
 "Implementers" who directed the running of great engines. 
 These engines produced this world and others, strange and 
 wondrous, as a test or puzzle for others of their kind. It
 goes on to state that these beings stand ready to aid those
 entrapped within their creation. The great                 
 magician-philosopher Helfax notes that a creation of this  
 kind is morally and logically indefensible and discards the
 theory as "colossal claptrap and kludgery."                

=back

=head1 BUGS

Too many to list: the interpreter is not compliant with the
specification in many areas.  With that said, I currently know of no
flaws that prevent version 3 games from being perfectly playable.
Version 4 games (A Mind Forever Voyaging, Bureaucracy, Nord and Bert
Couldn't Make Head or Tail of It, and Trinity) I'm less sure about,
this complicated by the fact that I haven't completed any of them C<:) >
Version 5 games (Beyond Zork, Border Zone, Sherlock) need serious
work and I would be surprised if any of them are playable to any
serious extent.  Hopefully compatibility will improve in the future.

=head1 HELP WANTED

Things I need:

=over 4 

=item *

A saved game from Seastalker before the sonar scope is used.  This is
(I think) the only example of a version 3 game splitting the screen,
and I'd like to test it (I know it won't work correctly now).

=item *

Command transcripts/walkthroughs for version 4 games, for testing
purposes.  On second thought, I should really play Trinity first.

=item *

Any examples of bugs or crashes, the fewer steps to reproduce the
better.

=item *

Feedback and suggestions for spiffy new features.

=item *

Advice about termcap behavior and scrolling; see the Termcap
description at the top of this document.

=back

=head1 REZROV?

 >up
 Jewel Room
 This fabulous room commands a magnificent view of the Lonely
 Mountain which lies to the north and west. The room itself is
 filled with beautiful chests and cabinets which once contained
 precious jewels and other objets d'art. These are empty.
 Winding stone stairs lead down to the base of the tower.
 There is an ornamented egg here, both beautiful and complex. It
 is carefully crafted and bears further examination.

 >get egg then examine it     
 Taken.

 This ornamented egg is both beautiful and complex. The egg
 itself is mother-of-pearl, but decorated with delicate gold
 traceries inlaid with jewels and other precious metals. On the
 surface are a lapis handle, an emerald knob, a silver slide, a
 golden crank, and a diamond-studded button carefully and
 unobtrusively imbedded in the decorations. These various
 protuberances are likely to be connected with some machinery
 inside.
 The beautiful, ornamented egg is closed.

 >read spell book

 My Spell Book

 The rezrov spell (open even locked or enchanted objects).
 The blorb spell (safely protect a small object as though in a
 strong box).
 The nitfol spell (converse with the beasts in their own
 tongue).
 The frotz spell (cause something to give off light).
 The gnusto spell (write a magic spell into a spell book).

 >learn rezrov then rezrov egg 
 Using your best study habits, you learn the rezrov spell.

 The egg seems to come to life and each piece slides
 effortlessly in the correct pattern. The egg opens, revealing a
 shredded scroll inside, nestled among a profusion of shredders,
 knives, and other sharp instruments, cunningly connected to the
 knobs, buttons, etc. on the outside.

=head1 AUTHOR

Michael Edmonson E<lt>edmonson@poboxes.comE<gt>

=cut
