#
# rezrov test script
#

# standard modules:
use strict;
use 5.005;

# local modules:
use Games::Rezrov::StoryFile;
use Games::Rezrov::ZInterpreter;
use Games::Rezrov::ZOptions;
use Games::Rezrov::ZConst;
use Games::Rezrov::ZIO_dumb;

my $storyfile = "minizork.z3";

die sprintf 'File "%s" does not exist.' . "\n", $storyfile
  unless (-f $storyfile);

my $zio = new Games::Rezrov::ZIO_dumb(
				      "columns" => 80, "rows" => 25
# HACK: dumb interface will die if it can't detect size (win32)
				      );

Games::Rezrov::ZOptions::GUESS_TITLE(0) unless $zio->can_change_title();

my $story = new Games::Rezrov::StoryFile($storyfile, $zio);
my $z_version = Games::Rezrov::StoryFile::load(1);

Games::Rezrov::ZOptions::END_OF_SESSION_MESSAGE(0);

&cont() unless $zio->set_version(($z_version <= 3 ? 1 : 0),
				\&cont);

exit(0);

sub cont () {
  Games::Rezrov::StoryFile::setup();
  # complete inititialization

  Games::Rezrov::StoryFile::input_stream(Games::Rezrov::ZConst::INPUT_FILE,
					 *main::DATA);
  # send commands to interpreter from __DATA__
  
  #
  #  Start interpreter
  #
  my $zi = new Games::Rezrov::ZInterpreter($zio);
}

__DATA__
open mailbox
read leaflet
quit
y
