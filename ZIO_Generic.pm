package Games::Rezrov::ZIO_Generic;
#
# shared z-machine i/o
#
use strict;

use Games::Rezrov::ZIO_Tools;
use Games::Rezrov::MethodMaker qw(
			   current_window

			   cc
			   fg
			   bg
			   default_fg
			   default_bg
			  );

my $buffer = "";

sub new {
  return bless {}, $_[0];
}

sub can_split {
  # true or false: can this zio split the screen?
  return 1;
}

sub fixed_font_default {
  # true or false: does this zio use a fixed-width font?
  return 1;
}

sub can_change_title {
  # true or false: can this zio change title?
  return set_xterm_title();
}

sub can_use_color {
  return 0;
}

sub split_window {}
sub set_text_style {}
sub clear_screen {}
sub color_change_notify {}

sub set_game_title {
  set_xterm_title($_[1]);
}

sub manual_status_line {
  # true or false: does this zio want to draw the status line itself?
  return 0;
}

sub get_buffer {
  # get buffered text; fix me: return a ref?
#  print STDERR "get_buf: $buffer\n";
  return $buffer;
}

sub reset_buffer {
  $buffer = "";
}

sub buffer_zchunk {
  # receive a z-code string; newlines may be present.
  my $nl = chr(Games::Rezrov::ZConst::Z_NEWLINE);
  foreach (unpack "a" x length ${$_[1]}, ${$_[1]}) {
    # this unpack() seems a little faster than a split().
    # Any better way ???
    if ($_ eq $nl) {
      $_[0]->story()->flush();
      $_[0]->newline();
    } else {
      $buffer .= $_;
    }
  }
}

sub buffer_zchar {
  $buffer .= chr($_[1]);
}

sub set_font {
#  print STDERR "set_font $_[1]\n";
  return 0;
}

sub play_sound_effect {
  my ($self, $effect) = @_;
#  flash();
}

sub set_window {
  $_[0]->current_window($_[1]);
}

sub cleanup {
}

sub DESTROY {
  # in case of a crash, make sure we exit politely
  $_[0]->cleanup();
}

sub fatal_error {
  my ($self, $msg) = @_;
  $self->write_string("Error: " . $msg);
  $self->newline();
  $self->get_input(1,1);
  $self->cleanup();
  exit 1;
}

1;
