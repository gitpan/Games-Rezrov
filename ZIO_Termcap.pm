package Games::Rezrov::ZIO_Termcap;
#
# z-machine i/o for perls with Term::Cap
#
BEGIN {
  $ENV{"PERL_RL"} = 'Perl';
}

use strict;
use Term::Cap;
use POSIX;

use Games::Rezrov::GetKey;
use Games::Rezrov::GetSize;
use Games::Rezrov::ZConst;
use Games::Rezrov::ZIO_Tools;
use Games::Rezrov::ZIO_Generic;

@Games::Rezrov::ZIO_Termcap::ISA = qw(Games::Rezrov::ZIO_Generic);

use constant ATTR_OFF => 'me';
use constant ATTR_REVERSE => 'mr';
use constant ATTR_BOLD => 'md';
use constant ATTR_UNDERLINE => 'us';

use constant CURSOR_MOVE => 'cm';
use constant CURSOR_UP => 'up';

use constant CLEAR_TO_EOL => 'ce';
use constant CLEAR_SCREEN => 'cl';
use constant DELETE_LINE => 'dl';
use constant DELETE_CHAR => 'dc';

use constant AUDIO_BELL => 'bl';
use constant VISIBLE_BELL => 'vb';

use constant BACKSPACE => 0x08;
# HACK

# again, a lot of statics for speed...
my $upper_lines;
my $terminal;

my ($abs_x, $abs_y) = (0,0);
# current cursor position

my $have_term_readline = 0;
my $tr;

# in v4/v5, we have a "lower" and an "upper" window.
# in <= v3, we have a window and a status line; status line will be
# considered "upper".  BROKEN: seastalker!

my ($rows, $columns);
my $read_own_lines = 0;

sub new {
  my ($type, %options) = @_;
  my $self = new Games::Rezrov::ZIO_Generic();
  bless $self, $type;

  # set up Term::Cap
  my $termios = new POSIX::Termios();
  $termios->getattr();
  my $ospeed = $termios->getospeed();
  $terminal = Tgetent Term::Cap { TERM => undef, OSPEED => $ospeed };
  
  $terminal->Trequire(
#		      CURSOR_X,
#		      CURSOR_LOWER_LEFT,
		      CLEAR_TO_EOL,
		     );
  attr_off();

  if ($options{"columns"} and $options{"rows"}) {
    $columns = $options{"columns"};
    $rows = $options{"rows"};
  } else {
    ($columns, $rows) = get_size();
    if ($columns and $rows) {
      if ($options{"flaky"} and Games::Rezrov::GetKey::can_read_single()) {
	$read_own_lines = 1;
      } else {
	$rows--;
	# hack: steal the last line on the display.
	# a newline on the last line often causes the window to scroll
	# automatically
      }
    } else {
      print "I couldn't guess the number of rows and columns in your display,\n";
      print "so you must use -rows and -columns to specify them manually.\n";
      exit;
    }
  }
  $upper_lines = 0;

  if ($options{"readline"} and find_module('Term::ReadLine')) {
    $have_term_readline = 1;
    $tr = new Term::ReadLine 'what?', \*main::STDIN, \*main::STDOUT;
    $tr->ornaments(0);
  }

  return $self;
}

sub update {
  # force screen refresh
  $|=1;
  print "";
  $|=0;
}

sub set_version {
  # called by the game
  my ($self, $status_needed, $callback) = @_;
  Games::Rezrov::StoryFile::rows($rows);
  Games::Rezrov::StoryFile::columns($columns);
  return 0;
}

sub write_string {
  my ($self, $string, $x, $y) = @_;
  $self->absolute_move($x, $y) if defined($x) and defined($y);
#  printf STDERR "ws: %s at (%d,%d)\n", $string, $abs_x, $abs_y;
  print $string;
  $abs_x += length($string);
}

sub newline {
  $abs_y++;
  if ($abs_y >= $rows) {
#    print STDERR "scrolling!\n";
#    my $restore = $_[0]->get_position(1);
    $_[0]->absolute_move(0, $upper_lines);
    do_term(DELETE_LINE);
    # scroll the lower window by deleting the first line
    # FIX ME: ONLY IN LOWER WINDOW
#    &$restore();
    $abs_y = $rows - 1;
  }
  
  $_[0]->absolute_move(0, $abs_y);

  Games::Rezrov::StoryFile::register_newline();
}

sub write_zchar {
  print chr($_[1]);
  $abs_x++;
}

sub absolute_move {
  # col, row
  my $self = shift;
  ($abs_x, $abs_y) = @_;
  print $terminal->Tgoto('cm', $abs_x, $abs_y);
}

sub get_position {
  # with no arguments, return absolute X and Y coordinates.
  # With an argument, return a sub that will restore the current cursor
  # position.
  my ($self, $sub) = @_;
  my ($x, $y) = ($abs_x, $abs_y);
  if ($sub) {
    return sub { $self->absolute_move($x, $y); };
  } else {
    return ($abs_x, $abs_y);
  }
}

sub status_hook {
  my ($self, $type) = @_;
  # 0 = before
  # 1 = after
  if ($type == 0) {
    # before printing status line
    attr_reverse();
  } else {
    # after printing status line
    attr_off();
  }
}

sub get_input {
  my ($self, $max, $single_char, %options) = @_;
  my $result;
  if ($single_char) {
    $result = get_key();
  } else {
    if ($read_own_lines) {
      $result = $self->read_line($options{"-preloaded"});
    } elsif ($have_term_readline) {
      # readline insists on resetting the line so we need to give it
      # everything up to the cursor position.
      $result = $tr->readline(Games::Rezrov::StoryFile::prompt_buffer());
      # this doesn't work with v5+ preloaded input
    } else {
      $result = <STDIN>;
      # this doesn't work with v5+ preloaded input
      unless (defined $result) {
	$result = "";
	print "\n";
      }
    }
    chomp $result;
    $result = "" unless defined($result);
    $self->newline();
#    printf STDERR "after newline: %d,%d\n", $abs_x, $abs_y;
#    print $terminal->Tgoto(CURSOR_X, 0);
    # ???
#    $self->newline();
  }
  return $result;
}

sub clear_to_eol {
  do_term(CLEAR_TO_EOL);
}

sub clear_screen {
  do_term(CLEAR_SCREEN);
}

sub split_window {
  # split upper window to specified number of lines
  my ($self, $lines) = @_;
  $upper_lines = $lines;
  # needed for scrolling the lower window
}

sub do_term {
  print $terminal->Tputs($_[0], 0) if $terminal;
}

sub attr_off {
  do_term(ATTR_OFF);
}

sub attr_reverse {
  do_term(ATTR_REVERSE);
}

sub attr_bold {
  do_term(ATTR_BOLD);
}

sub attr_underline {
  do_term(ATTR_UNDERLINE);
}

sub set_text_style {
  # sect15.html#set_text_style
  my ($self, $text_style) = @_;
  attr_off();
  attr_reverse() if ($text_style & Games::Rezrov::ZConst::STYLE_REVERSE);
  attr_bold() if ($text_style & Games::Rezrov::ZConst::STYLE_BOLD);
  attr_underline() if ($text_style & Games::Rezrov::ZConst::STYLE_ITALIC);
}

sub cleanup {
  # don't just rely on DESTROY, doesn't work for interrupts
  attr_off();
}

sub story {
  return (defined $_[1] ? $_[0]->{"story"} = $_[1] : $_[0]->{"story"});
}

sub read_line {
  my ($self, $buf) = @_;
  $buf = "" unless defined $buf;
  my ($ord, $char);
  while (1) {
    $char = get_key();
    $ord = ord($char);
    if ($ord == Games::Rezrov::ZConst::ASCII_DEL or
	$ord == Games::Rezrov::ZConst::ASCII_BS) {
      if (my $len = length($buf)) {
	print pack "c", BACKSPACE;
	do_term(DELETE_CHAR);
	$buf = substr($buf, 0, $len - 1);
      }
    } elsif ($ord == Games::Rezrov::ZConst::ASCII_LF or
	     $ord == Games::Rezrov::ZConst::ASCII_CR) {
      return $buf;
    } elsif ($ord >= 32 and $ord <=127) {
      $buf .= $char;
      print $char;
    }
  }
}


1;
