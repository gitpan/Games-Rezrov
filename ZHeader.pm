# ZHeader: version-specific information and settings
# for each game

package Games::Rezrov::ZHeader;

use Games::Rezrov::ZConst;

use strict;

use constant FLAGS_1 => 0x01;  # one byte
use constant FLAGS_2 => 0x10;  # TWO BYTES
# location of various flags in the header

# see spec section 11:
use constant RELEASE_NUMBER => 0x02;
use constant PAGED_MEMORY_ADDRESS => 0x04;
use constant FIRST_INSTRUCTION_ADDRESS => 0x06;
use constant DICTIONARY_ADDRESS => 0x08;
use constant OBJECT_TABLE_ADDRESS => 0x0a;
use constant GLOBAL_VARIABLE_ADDRESS => 0x0c;
use constant STATIC_MEMORY_ADDRESS => 0x0e;
use constant SERIAL_CODE => 0x12;
use constant ABBREV_TABLE_ADDRESS => 0x18;
use constant FILE_LENGTH => 0x1a;
use constant CHECKSUM => 0x1c;

use constant STATUS_NOT_AVAILABLE => 0x10;  # bit 4 (#5)
use constant SCREEN_SPLITTING_AVAILABLE => 0x20; # bit 5 (#6)

# Flags 1
use constant TANDY => 0x08;

# Flags 2
use constant TRANSCRIPT_ON => 0x01;            # bit 0
use constant FORCE_FIXED => 0x02;              # bit 1
use constant REQUEST_STATUS_REDRAW => 0x04;    # bit 2

# Flags 2, v5+:
use constant WANTS_PICTURES => 0x08;
use constant WANTS_UNDO => 0x10;
use constant WANTS_MOUSE => 0x20;
use constant WANTS_COLOR => 0x40;
use constant WANTS_SOUND => 0x80;
# Flags 2, v6+:
use constant WANTS_MENUS => 0x0100;  # ??

use constant BACKGROUND_COLOR => 0x2c;
use constant FOREGROUND_COLOR => 0x2d;
# 8.3.2, 8.3.3

use constant SCREEN_HEIGHT_LINES => 0x20;
use constant SCREEN_WIDTH_CHARS => 0x21;
use constant SCREEN_WIDTH_UNITS => 0x22;
use constant SCREEN_HEIGHT_UNITS => 0x24;

use constant FONT_WIDTH_UNITS_V5 => 0x26;
use constant FONT_WIDTH_UNITS_V6 => 0x27;

use constant FONT_HEIGHT_UNITS_V5 => 0x27;
use constant FONT_HEIGHT_UNITS_V6 => 0x26;

use Games::Rezrov::MethodMaker ([],
			 qw(
			    abbrev_table_address
			    file_checksum
			    release_number
			    paged_memory_address
			    object_table_address
			    global_variable_address
			    static_memory_address
			    first_instruction_address
			    dictionary_address
			    serial_code
			    file_length
			    story
			    version
			    object_bytes
			    attribute_bytes
			    pointer_size
			    max_properties
			    max_objects
			    attribute_starter
			    object_count
			    encoded_word_length
			    is_time_game
			   ));

use SelfLoader;

1;

__DATA__

sub new {
  my ($type, $story, $zio) = @_;
  my $self = [];
  bless $self, $type;
  $self->story($story);
  
  my $version = $story->get_byte_at(0);
  if ($version < 1 or $version > 10) {
    die "This does not appear to be a valid game file.\n";
  } elsif ($version < 3 or $version > 5) {
    die "Sorry, only version 3-5 games are supported at present...\nEven those don't always work right :)\n"
  } else {
    $self->version($version);
  }

  my $f1 = $story->get_byte_at(FLAGS_1);
  $self->is_time_game($f1 & 0x02 ? 1 : 0);
  # a "time" game: 8.2.3.2

  my $start_rows = $story->rows();
  my $start_columns = $story->columns();

  $f1 |= TANDY if Games::Rezrov::ZOptions::TANDY_BIT();
  # turn on the "tandy bit"
  
  if ($version <= 3) {
    $self->encoded_word_length(6);
    # 13.3, 13.4

    # set bits 4 (status line) and 5 (screen splitting) appropriately
    # depending on the ZIO implementation's abilities
    if ($zio->can_split()) {
      # yes
      $f1 |= SCREEN_SPLITTING_AVAILABLE;
      $f1 &= ~ STATUS_NOT_AVAILABLE;
    } else {
      # no
      $f1 &= ~ SCREEN_SPLITTING_AVAILABLE;
      $f1 |= STATUS_NOT_AVAILABLE;
    }

    # "bit 6" (#7): variable-pitch font is default?
    if ($zio->fixed_font_default()) {
      $f1 |= 0x40;
    } else {
      $f1 &= ~0x40;
    }
  } else {
    #
    # versions 4+
    #
    $self->encoded_word_length(9);
    # 13.3, 13.4

    if ($version >= 4) {
      $f1 |= 0x04;
      # "bit 2" (#3): boldface available
      $f1 |= 0x08;
      # "bit 3" (#4): italic available
      $f1 |= 0x10;
      # "bit 4" (#5): fixed-font available

#      $f1 |= 0x80;
      $f1 &= ~0x80;
      # "bit 7" (#8): timed input NOT available

      $story->set_byte_at(30, Games::Rezrov::ZOptions::INTERPRETER_ID());
      # interpreter number
      $story->set_byte_at(31, ord 'R');
      # interpreter version; "R" for rezrov
      
      $self->set_columns($start_columns);
      $self->set_rows($start_rows);
    }
    if ($version >= 5) {
      if ($zio->can_use_color()) {
	# "bit 0" (#1): colors available
	$f1 |= 0x01;
      }

#      printf "dfc:%s\n", $story->get_byte_at(FOREGROUND_COLOR);
      $story->set_byte_at(BACKGROUND_COLOR, Games::Rezrov::ZConst::COLOR_BLACK);
      $story->set_byte_at(FOREGROUND_COLOR, Games::Rezrov::ZConst::COLOR_WHITE);
      # 8.3.3: default foreground and background
      # FIX ME!

      my $f2 = $story->get_word_at(FLAGS_2);
      $f2 &= ~ WANTS_PICTURES;
      # disable font 3 usage...this is a wreck
      
#      $f2 |= WANTS_UNDO;
      $f2 &= ~ WANTS_UNDO;
      # FIX ME: should we never use this???

      if ($f2 & WANTS_COLOR) {
	# 8.3.4: the game wants to use colors
#	print "wants color!\n";
      }
      $story->set_word_at(FLAGS_2, $f2);
    }
    if ($version >= 6) {
      # unimplemented
      # see 8.3.2,etc
      print STDERR ("zheader: v6+, fix me"); # debug
    }
  }

  $story->set_byte_at(FLAGS_1, $f1);
  # write back the header flags

  $self->release_number($story->get_word_at(RELEASE_NUMBER));
  $self->paged_memory_address($story->get_word_at(PAGED_MEMORY_ADDRESS));
  $self->first_instruction_address($story->get_word_at(FIRST_INSTRUCTION_ADDRESS));
  $self->dictionary_address($story->get_word_at(DICTIONARY_ADDRESS));
  $self->object_table_address($story->get_word_at(OBJECT_TABLE_ADDRESS));
  $self->global_variable_address($story->get_word_at(GLOBAL_VARIABLE_ADDRESS));
  $self->static_memory_address($story->get_word_at(STATIC_MEMORY_ADDRESS));
  $self->serial_code($story->get_string_at(SERIAL_CODE, 6));
  # see zmach06e.txt
  $self->abbrev_table_address($story->get_word_at(ABBREV_TABLE_ADDRESS));
  $self->file_checksum($story->get_word_at(CHECKSUM));

  my $flen = $story->get_word_at(FILE_LENGTH);
  if ($version <= 3) {
    # see 11.1.6
    $flen *= 2;
  } elsif ($version == 4 || $version == 5) {
    $flen *= 4;
  } else {
    $flen *= 8;
  }
  $self->file_length($flen);
  
  #
  #  set object "constants" for this version...
  #
  if ($version <= 3) {
    # 12.3.1
    $self->object_bytes(9);
    $self->attribute_bytes(4);
    $self->pointer_size(1);
    $self->max_properties(31);	# 12.2
    $self->max_objects(255);		# 12.3.1
  } else {
    # 12.3.2
    $self->object_bytes(14);
    $self->attribute_bytes(6);
    $self->pointer_size(2);
    $self->max_properties(63);	# 12.2
    $self->max_objects(65535);	# 12.3.2
  }
  die("check your math!")
    if (($self->attribute_bytes() + ($self->pointer_size() * 3) + 2)
	!= $self->object_bytes());
  
  $self->attribute_starter($self->object_table_address() +
			   ($self->max_properties() * 2));
  
  my $obj_space = $self->global_variable_address() - $self->attribute_starter();
  # how many bytes exist between the start of the object area and
  # the beginning of the global variable block?
  my $object_count;
  if ($obj_space > 0) {
    # hack:
    # guess approximate object count; most useful for games later than v3
    # FIX ME: is this _way_ off?  Better to check validity of each object
    # sequentially, stopping w/invalid pointers, etc?
    $object_count = $obj_space / $self->object_bytes();
    $object_count = $self->max_objects()
      if $object_count > $self->max_objects();
  } else {
    # header data not arranged the way we expect; oh well.
    $object_count = $self->max_objects();
  }
  $self->object_count($object_count);
#  die sprintf "objects: %s\n", $object_count;
  
  return $self;
}

sub get_abbreviation_addr {
  my ($self, $entry) = @_;
  # Spec 3.3: fetch and convert the "word address" of the given entry
  # in the abbreviations table.
#  print STDERR "gaa\n";
  my $abbrev_addr = $self->abbrev_table_address() + ($entry * 2);
  return $self->story()->get_word_at($abbrev_addr) * 2;
  # "word address"; only used for abbreviations (packed address
  # rules do not apply here)
}

sub set_columns {
  # 8.4: set the dimensions of the screen.
  # only needed in v4+
  # arg: number of columns
  $_[0]->story()->set_byte_at(SCREEN_WIDTH_CHARS, $_[1]);
  if ($_[0]->version >= 5) {
    $_[0]->story()->set_byte_at($_[0]->version >= 6 ?
				FONT_WIDTH_UNITS_V6 : FONT_WIDTH_UNITS_V5, 1);
    $_[0]->story()->set_word_at(SCREEN_WIDTH_UNITS, $_[1]);
    # ?
  }
}

sub set_rows {
  # arg: number of rows
  $_[0]->story()->set_byte_at(SCREEN_HEIGHT_LINES, $_[1]);
  if ($_[0]->version >= 5) {
    $_[0]->story()->set_byte_at($_[0]->version >= 6 ?
				FONT_HEIGHT_UNITS_V6 : FONT_HEIGHT_UNITS_V5, 1);
    $_[0]->story()->set_word_at(SCREEN_HEIGHT_UNITS, $_[1]);
  }
}

sub wants_color {
  # 8.3.4: does the game want to use colors?
  return $_[0]->story()->get_word_at(FLAGS_2) & WANTS_COLOR ? 1 : 0;
}

sub get_colors {
  my $story = $_[0]->story();
  return ($story->get_byte_at(FOREGROUND_COLOR),
	  $story->get_byte_at(BACKGROUND_COLOR));
}


1;
