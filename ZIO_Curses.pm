package Games::Rezrov::ZIO_Curses;
#
# z-machine i/o for perls with the Curses module installed.
#
use strict;
use Carp qw(cluck);

@Games::Rezrov::ZIO_Curses::ISA = qw(Games::Rezrov::ZIO_Generic);

use Curses;
use Games::Rezrov::ZIO_Generic;
use Games::Rezrov::ZConst;
use Games::Rezrov::ZIO_Tools;
use Games::Rezrov::MethodMaker qw(
			   need_endwin
			   story
			   custom_status_colors
			   rows
			   columns
			   term_readline
			   color_pairs
			);

my $w_main;
my %COLORMAP = (black => COLOR_BLACK,
		red => COLOR_RED,
		green => COLOR_GREEN,
		yellow => COLOR_YELLOW,
		blue => COLOR_BLUE,
		magenta => COLOR_MAGENTA,
		cyan => COLOR_CYAN,
		white => COLOR_WHITE);
my $color_pair_counter = 0;
# HACKS

sub new {
  my ($type, %options) = @_;
  my $self = new Games::Rezrov::ZIO_Generic();
#  my $self = [];
  bless $self, $type;

  # set up Curses:
  initscr() || die;
  $self->need_endwin(1);
#  printf STDERR "ew: %s %s\n", $self, $self->need_endwin();
  # isendwin() is not present in all Curses implementations (eg dec_osf)
  # ...actually it's more like Curses.pm doesn't autoconfigure correctly
  # under dec_osf  :(

  if ($options{"readline"} and find_module("Term/ReadLine.pm")) {
    my $tr = $self->term_readline(new Term::ReadLine 'what?', \*main::STDIN, \*main::STDOUT);
    $tr->ornaments(0);
  }

  my $columns = $options{"columns"} || $Curses::COLS || die "need columns!";
  my $rows = $options{"rows"} || $Curses::LINES || die "need rows!";

  $self->rows($rows);
  $self->columns($columns);

  $w_main = newwin($rows, $columns, 0, 0);
  # create main window

  $self->color_pairs({});
  $self->init_colors(\%options);
  
  return $self;
}

sub can_use_color {
  return has_colors() ? 1 : 0;
}

sub update {
  # force screen refresh
  $w_main->refresh();
}

sub set_version {
  # called by the game
  my ($self, $story, $status_needed, $callback) = @_;
  $self->story($story);
  $story->rows($self->rows());
  $story->columns($self->columns());
  $self->clear_screen();
  scrollok($w_main, 1);
  noecho();
  return 0;
}

sub clear_screen {
  my $self = shift;
  $self->do_colors($self->fg(), $self->bg())
    if has_colors() and $self->fg() and $self->bg();
  # make sure colors are set up correctly
  $w_main->erase();
  # erase
}

sub get_position {
  # with no arguments, return absolute X and Y coordinates.
  # With an argument, return a sub that will restore the current cursor
  # position.
  my ($self, $sub) = @_;
  my ($x, $y);
  $w_main->getyx($y,$x);
#  carp "pos is $x, $y\n";
  if ($sub) {
    return sub { $w_main->move($y, $x); };
  } else {
    return ($x, $y);
  }
}

sub newline {
  # use autoscrolling
  $w_main->addstr("\n");
  # broken: what if not lower window??
  $_[0]->story()->register_newline();
  update() if Games::Rezrov::ZOptions::MAXIMUM_SCROLLING;
}

sub write_zchar {
  # write an unbuffered z-char to the screen
  $w_main->addch(chr($_[1]));
}

sub status_hook {
  my ($self, $type) = @_;
  # 0 = before
  # 1 = after
  my $custom_status = $self->custom_status_colors();
  if ($type == 0) {
    # before printing status line
    if ($custom_status) {
      $w_main->bkgd(0);
#      $w_main->attrset(COLOR_PAIR(2));
      $self->do_colors($self->sfg(), $self->sbg());
    } else {
      $w_main->attrset(A_REVERSE);
    }
  } else {
    # after printing status line
#    $w_main->bkgdset(COLOR_PAIR(1)) if $custom_status;
    $self->do_colors($self->fg(), $self->bg());
    $w_main->attrset(A_NORMAL);
  }
}

sub write_string {
  my ($self, $string, $x, $y) = @_;
  $self->absolute_move($x, $y) if defined($x) and defined($y);
#  printf STDERR "write string: ->%s<-\n", $string;
  $w_main->addstr($string);
}

sub get_input {
  my ($self, $max, $single_char, %options) = @_;
  my $result;
  echo();
  if ($single_char) {
    $result = get_char();
#    printf STDERR "get_char: %d\n", ord($result);
  } else {
    my ($x, $y) = $self->get_position();
    scrollok($w_main, 0);
    # temporarily disable autoscrolling; some Curses seem to generate
    # a newline/scroll with user input (ie DEC OSF)
    
    if ($self->term_readline()) {
      $result = $self->term_readline()->readline($self->story()->prompt_buffer());
      # this doesn't work with v5+ preloaded input
    } else {
#      $w_main->getnstr($result, $max);
      # this doesn't work with v5+ preloaded input

      $result = "";
      if ($options{"-preloaded"}) {
	$result = $options{"-preloaded"};
	$x -= length $result;
      }
      my ($char, $ord);
      noecho();
      cbreak();
      while (1) {
	$char = $w_main->getch();
	$ord = ord($char);
	if ($ord == Games::Rezrov::ZConst::ASCII_DEL or
	    $ord == Games::Rezrov::ZConst::ASCII_BS) {
	  my $len = length $result;
	  if ($len) {
	    $result = substr($result, 0, --$len);
	    $w_main->move($y, $x + $len);
	    $w_main->addch(" ");
	    $w_main->move($y, $x + $len);
	  }
	} elsif ($ord == Games::Rezrov::ZConst::ASCII_LF or
		 $ord == Games::Rezrov::ZConst::ASCII_CR) {
	  # newline: hack
	  last;
	} elsif (length $result < $max) {
	  $result .= $char;
	  $w_main->addch($char);
#	  $w_main->refresh();
	  $w_main->touchline($y, 1);
	  # may be needed to update when user types a space char
#	  print STDERR "adding \"$char\"\n";
	}
      }
      nocbreak();
    }
    scrollok($w_main, 1);
    $w_main->move($y, $x + length($result));
    # make sure the cursor is now after the input
    $self->newline();
  }
  noecho();
  return $result;
}

sub get_char {
  # read a single character (if possible)
  my $char;
  noecho();
#  raw();
  cbreak();
  $char = $w_main->getch();
#  noraw();
  nocbreak();
  echo();
  return $char;
}

sub clear_to_eol {
  $w_main->clrtoeol();
}

sub split_window {
  # split upper window to specified number of lines
  my ($self, $lines) = @_;
  $w_main->setscrreg($lines, $self->rows() - 1);
}

sub set_text_style {
  # sect15.html#set_text_style
  my ($self, $text_style) = @_;
  if ($text_style == Games::Rezrov::ZConst::STYLE_ROMAN) {
    # turn off all
    $w_main->attrset(A_NORMAL);
  } else {
    my $mask = 0;
    $mask |= A_REVERSE if ($text_style & Games::Rezrov::ZConst::STYLE_REVERSE);
    $mask |= A_BOLD if ($text_style & Games::Rezrov::ZConst::STYLE_BOLD);
    $mask |= A_UNDERLINE if ($text_style & Games::Rezrov::ZConst::STYLE_ITALIC);
    $w_main->attrset($mask);
  }
}

sub cleanup {
  # don't just rely on DESTROY, doesn't work for interrupts
  if ($_[0]->need_endwin()) {
    endwin();
    $_[0]->need_endwin(0);
  }
}

sub absolute_move {
  # move to X, Y
#  carp "move to x=$_[1] y=$_[2]\n";
  $w_main->move($_[2], $_[1]);
}

sub init_colors {
  # initialize color support
  my ($self, $options) = @_;
  my $fg = lc($options->{"fg"});
  my $bg = lc($options->{"bg"});
  my $sfg = lc($options->{"sfg"});
  my $sbg = lc($options->{"sbg"});

  if (has_colors()) {
    $fg = "white" unless $fg;
    $bg = "blue" unless $bg;
    foreach ($fg, $bg, $sfg, $sbg) {
      if ($_ and !exists $COLORMAP{$_}) {
	$self->fatal_error(sprintf "Unknown color \"%s\"; available colors are %s.\n", $_, join ", ", sort keys %COLORMAP);
      }
    }
    start_color();
    $self->fg($fg);
    $self->bg($bg);
    $self->default_fg($fg);
    $self->default_bg($bg);
    $self->do_colors($fg, $bg);
    if ($sfg and $sbg) {
      # foreground/background colors for status line
      $self->sfg($sfg);
      $self->sbg($sbg);
      #	init_pair(2, $colormap{$sfg}, $colormap{$sbg});
      $self->custom_status_colors(1);
      }
  } elsif ($fg and $bg) {
    # we specified colors to use, but terminal can't handle color
    my $message = "Your terminal does not seem to support color.\nIs your TERM variable set correctly?\n";
    if ($^O =~ /linux/i) {
      $message .= "You seem to be using Linux; if you are using color_xterm,\nhave you tried setting TERM to \"xterm-color\"?";
    }
    $self->fatal_error($message);
  }
}

sub color_change_notify { 
  $_[0]->do_colors($_[0]->fg(), $_[0]->bg());
}

sub do_colors {
  my ($self, $fg, $bg) = @_;
  if (has_colors()) {
    my $color_pairs = $self->color_pairs();
    my $key = $fg . "," . $bg;
    my $pair;
    if (exists $color_pairs->{$key}) {
      # pair already exists, use it
      $pair = $color_pairs->{$key};
    } else {
      # if pair is not in cache, create it
      $pair = ++$color_pair_counter;
      init_pair($pair, $COLORMAP{$fg}, $COLORMAP{$bg});
      #    print STDERR "create new $fg $bg = $pair\n";
      $color_pairs->{$key} = $pair;
    }
    #  $w_main->bkgdset(COLOR_PAIR($pair)) if $set_background;
    #  printf STDERR "want %s/%s = %d\n", $fg, $bg, $pair;
    $w_main->bkgdset(COLOR_PAIR($pair));
  }
}


1;
