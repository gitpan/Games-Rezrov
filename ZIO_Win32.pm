package Games::Rezrov::ZIO_Win32;
# z-machine i/o for perls with Win32::Console
# TO DO:
# - can we set hourglass when busy?

use strict;
use Win32::Console;

use Games::Rezrov::ZIO_Generic;
use Games::Rezrov::ZConst;
use Games::Rezrov::MethodMaker qw(
			   sfg
			   sbg
			   
			   story
			   );

use Carp qw(cluck);

use constant DEBUG => 0;

@Games::Rezrov::ZIO_Win32::ISA = qw(Games::Rezrov::ZIO_Generic);

my $upper_lines;
# number of lines in upper window

my ($IN, $OUT);
# win32 instances

my ($rows, $columns);

use FileHandle;

if (DEBUG) {
  # debugging; tough to redirect STDERR under win32 :(
  open(LOG, ">zio.log") || die;
  LOG->autoflush(1);
}

my %FOREGROUND = (
		  "black" => $main::FG_BLACK,
		  "blue" => $main::FG_BLUE,
		  "lightblue" =>$main::FG_LIGHTBLUE,
		  "red" => $main::FG_RED,
		  "lightred" => $main::FG_LIGHTRED,
		  "green" => $main::FG_GREEN,
		  "lightgreen" => $main::FG_LIGHTGREEN,
		  "magenta" => $main::FG_MAGENTA,
		  "lightmagenta" => $main::FG_LIGHTMAGENTA,
		  "cyan" => $main::FG_CYAN,
		  "lightcyan" => $main::FG_LIGHTCYAN,
		  "brown" => $main::FG_BROWN,
		  "yellow" => $main::FG_YELLOW,
		  "gray" => $main::FG_GRAY,
		  "white" => $main::FG_WHITE
		 );

my %BACKGROUND = (
		  "black" => $main::BG_BLACK,
		  "blue" => $main::BG_BLUE,
		  "lightblue" =>$main::BG_LIGHTBLUE,
		  "red" => $main::BG_RED,
		  "lightred" => $main::BG_LIGHTRED,
		  "green" => $main::BG_GREEN,
		  "lightgreen" => $main::BG_LIGHTGREEN,
		  "magenta" => $main::BG_MAGENTA,
		  "lightmagenta" => $main::BG_LIGHTMAGENTA,
		  "cyan" => $main::BG_CYAN,
		  "lightcyan" => $main::BG_LIGHTCYAN,
		  "brown" => $main::BG_BROWN,
		  "yellow" => $main::BG_YELLOW,
		  "gray" => $main::BG_GRAY,
		  "white" => $main::BG_WHITE
		 );

my %BOLD = (
	    "black" => "gray",
	    "blue" => "lightblue",
	    "red" => "lightred",
	    "green" => "lightgreen",
	    "magenta" => "lightmagenta",
	    "cyan" => "lightcyan",
	    "brown" => "yellow",
	    "gray" => "white",
	    "yellow" => "white",
	    "white" => "white",
	   );

#my ($NORMAL, $REVERSE, $BOLD, $STATUS);
#my $current_attr;
my $in_status;

sub new {
    my ($type, %options) = @_;
    my $self = new Games::Rezrov::ZIO_Generic();
    bless $self, $type;

    if ($options{"fg"} and $options{"bg"}) {
	foreach ("bg", "fg", "sfg", "sbg") {
	    next unless exists $options{$_};
	    my $c = lc($options{$_});
	    unless (exists $FOREGROUND{$c}) {
		die sprintf "Unknown color \"%s\"; available colors: %s\n", $c, join ", ", sort keys %FOREGROUND;
	    }
	}
	$self->fg($options{"fg"});
	$self->bg($options{"bg"});
	if ($options{"sfg"} and $options{"sbg"}) {
	    $self->sfg($options{"sfg"});
	    $self->sbg($options{"sbg"});
	} else {
	    # reverse
	    $self->sfg($options{"bg"});
	    $self->sbg($options{"fg"});
	}
    } else {
	$self->fg("gray");
	$self->bg("blue");
	$self->sfg("black");
	$self->sbg("cyan");
    }
    
    # set up i/o
    $IN = new Win32::Console(STD_INPUT_HANDLE);
    $OUT = new Win32::Console(STD_OUTPUT_HANDLE);
    
    my @size = $OUT->Size();
    $columns = $options{"-columns"} || $size[0] || die "need columns!";
    $rows = $options{"-rows"} || $size[1] || die "need rows!";
    $upper_lines = 0;
    return $self;
}

sub update {
  $OUT->Flush();
}

sub set_version {
  # called by the game
  my ($self, $story, $status_needed, $callback) = @_;
  $self->story($story);
  $story->rows($rows);
  $story->columns($columns);
  return 0;
}

sub absolute_move {
  # move to X, Y
  $OUT->Cursor($_[1], $_[2]);
}

sub write_string {
  my ($self, $string, $x, $y) = @_;
  $self->absolute_move($x, $y) if defined($x) and defined($y);
#  $OUT->Attr($current_attr);
  $OUT->Attr($self->get_attr());
  $OUT->Write($string);
}

sub newline {
  # newline/scroll
  my ($x, $y) = $OUT->Cursor();
  if (++$y >= $rows) {
      # scroll needed
      my $last_line = $rows - 1;
      $y = $last_line;
      my $top = $upper_lines;
    #	$OUT->Write(sprintf "before: at %d,%d, top=%d last=%d\n", $x, $y, $top, $last_line);
#    log_it(sprintf "before: at %d,%d, top=%d last=%d\n", $x, $y, $top, $last_line);
    #	sleep(1);
      $OUT->Scroll(0, $top + 1, $columns - 1, $last_line,
		   0, $top, Games::Rezrov::ZConst::ASCII_SPACE, $_[0]->get_attr(0),
		   0, $top, $columns - 1, $last_line);
      # ugh: we have to specify the clipping region, or else
      # Win32::Console barfs about uninitialized variables (with -w)
  }
  $_[0]->story()->register_newline();
  $_[0]->absolute_move(0, $y);
}

sub write_zchar {
  $OUT->Attr($_[0]->get_attr());
  $OUT->Write(chr($_[1]));
}

sub status_hook {
  my ($self, $type) = @_;
  # 0 = before
  # 1 = after
  if ($type == 0) {
    # before printing status line
    $OUT->Cursor(0,0);
    $in_status = 1;
    $OUT->FillAttr($self->get_attr(), $columns, 0, 0);
  } else {
    # after printing status line
    $in_status = 0;
  }
}

sub get_input {
    my ($self, $max, $single_char, %options) = @_;
    $IN->Flush();
    
    my ($start_x, $y) = $OUT->Cursor();
    my $buf = $options{"-preloaded"} || "";
    # preloaded text in the buffer, but already displayed by the game; ugh.
    my @event;
    my ($code, $char);
    while (1) {
	@event = $IN->Input();
	if ($event[0] == 1 and $event[1]) {
	    # a key pressed
	    $code = $event[5];
	    if ($single_char and $code >= 1 and $code <= 127) {
		return chr($code);
	    } elsif ($code == Games::Rezrov::ZConst::ASCII_BS) {
		if (length($buf) > 0) {
#	  log_it("backsp " . length($buf) . " " . $buf);
		    my ($x, $y) = $OUT->Cursor();
		    $OUT->Cursor($x - 1, $y);
		    $OUT->Write(" ");
		    $OUT->Cursor($x - 1, $y);
		    $buf = substr($buf, 0, length($buf) - 1);
		}
	    } elsif ($code == Games::Rezrov::ZConst::ASCII_CR) {
		last;
	    } else {
		if ($code >= 32 and $code <= 127) {
		    $char = chr($code);
		    $buf .= $char;
		    $OUT->Attr($self->get_attr(0));
		    $OUT->Write($char);
		}
	    }
	}
    }
    $self->newline();
    return $buf;
}

sub clear_screen {
    $OUT->Cls($_[0]->get_attr(0));
#    log_it("cls");
}

sub clear_to_eol {
    $OUT->Attr($_[0]->get_attr(0));
    $OUT->Write(' ' x ($columns - ($OUT->Cursor())[1]));
}

sub split_window {
  # split upper window to specified number of lines
  my ($self, $lines) = @_;
  #  $w_main->setscrreg($lines, $rows - 1);
  $upper_lines = $lines;
  #  print STDERR "split_window to $lines\n";
}

sub can_change_title {
  return 1;
}

sub can_use_color {
  return 1;
}

sub set_game_title {
  $OUT->Title($_[1]);
}

sub log_it {
  if (DEBUG) {
    print LOG $_[0] . "\n";
  }
}

sub get_attr {
    # return attribute code for color/style currently in effect.
    my ($self, $mask) = @_;
    
    $mask = $self->story()->font_mask() unless defined($mask);
    # might be called with an override
    my ($fg, $bg);
    if ($in_status) {
	$fg = $self->sfg();
	$bg = $self->sbg();
    } else {
	my $is_reverse = $mask & Games::Rezrov::ZConst::STYLE_REVERSE ? 1 : 0;
	if ($is_reverse) {
	  $fg = $self->bg();
	  $bg = $self->fg();
	} else {
	  $fg = $self->fg();
	  $bg = $self->bg();
	}
	if ($mask &
	    (Games::Rezrov::ZConst::STYLE_BOLD|Games::Rezrov::ZConst::STYLE_ITALIC)) {
	    # bold or italic
	    $fg = $BOLD{$fg} || $fg;
#	    $bg = $BOLD{$bg} || $bg;
	}
    }
    return $BACKGROUND{$bg} | $FOREGROUND{$fg};
}

sub get_position {
  # with no arguments, return absolute X and Y coordinates.
  # With an argument, return a sub that will restore the current cursor
  # position.
  my ($self, $sub) = @_;
  my ($x, $y) = $OUT->Cursor();
  if ($sub) {
    return sub { $OUT->Cursor($x, $y); };
  } else {
    return ($x, $y);
  }
}

1;
