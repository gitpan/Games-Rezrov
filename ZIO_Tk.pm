package Games::Rezrov::ZIO_Tk;
#
# z-machine i/o for perls with Perl/Tk
#

use strict;
use Tk;
use Tk::Font;

use Carp qw(cluck carp confess);

use Games::Rezrov::ZConst;
use Games::Rezrov::ZIO_Generic;

use constant X_BORDER => 2;
# FIX ME?

use constant STANDARD_COMPLIANT_BUT_EVEN_SLOWER => 0;
# if 0 (noncompliant) we buffer output in the upper window.

use constant FIXED_FAMILY => "Courier";
# FIX ME!

use constant DEFAULT_BACKGROUND_COLOR => 'blue';
use constant DEFAULT_FOREGROUND_COLOR => 'white';
use constant DEFAULT_CURSOR_COLOR => 'black';

use constant DEFAULT_BLINK_DELAY => 1000;

#use constant TEXT_ANCHOR => "nw";
use constant TEXT_ANCHOR => "w";

@Games::Rezrov::ZIO_Tk::ISA = qw(Games::Rezrov::ZIO_Generic);

use Games::Rezrov::MethodMaker qw(
			   story
			   sfg
			   sbg
			   dumb_fonts
			   font_cache

			   font_size
			   line_height
			   last_zstatus
			   fixed_font_width
			   current_font

			   cursor_id
			   cursor_x
			   cursor_status
			   blink_id

			   last_font
			   last_text_id

			   options
			   variable_font_family
			  );

# again, a lot of statics for speed...
my ($w_main, $c, $status_line, $upper_lines);
my ($abs_x, $abs_y, $abs_row, $rows, %widgets);
my $Y_BORDER;

sub new {
  my ($type, %options) = @_;
  my $self = new Games::Rezrov::ZIO_Generic();
  bless $self, $type;
  $self->options(\%options);
  $self->font_cache({});
  $self->last_font(Games::Rezrov::ZConst::FONT_NORMAL);
  return $self;
}

sub set_version {
  my ($self, $story, $need_status, $init_sub) = @_;
  $self->story($story);
  # set up window
  $w_main = MainWindow->new();
  $w_main->title("rezrov");
  $w_main->bind('<Configure>' => [ $self => 'handle_resize' ]);
  $w_main->bind('<Control-c>' => [ $self => 'cleanup' ]);

  my $is_win32 = ($^O =~ /mswin32/i) ? 1 : 0;
  my ($DEFAULT_VARIABLE_FAMILY, $DEFAULT_FONT_SIZE);
  if ($is_win32) {
      $DEFAULT_VARIABLE_FAMILY = "times new roman";
      $DEFAULT_FONT_SIZE = 10;
  } else {
      $DEFAULT_VARIABLE_FAMILY = "times";
      $DEFAULT_FONT_SIZE = 18;
  }

  my $options = $self->options();
  my $vff = lc($options->{"family"} || $DEFAULT_VARIABLE_FAMILY);
  unless (grep {lc($_) eq $vff} $w_main->fontFamilies()) {
    $self->fatal_error(sprintf "Invalid font family \"%s\"; available families are:\n  %s\n", $vff, join "\n  ", sort $w_main->fontFamilies());
  }
  $self->variable_font_family($vff);
  $self->font_size($options->{"fontsize"} || $DEFAULT_FONT_SIZE);
  
  $self->init_colors($options);

  my $f_variable = $self->set_text_style(Games::Rezrov::ZConst::STYLE_ROMAN);
  my $f_fixed = $self->set_text_style(Games::Rezrov::ZConst::STYLE_FIXED);
  $self->set_text_style(Games::Rezrov::ZConst::STYLE_ROMAN);

  # Determine the approximate font geometry
  die "Couldn't init fixed font!" unless $f_fixed;
  die "Couldn't init variable font!" unless $f_variable;

  my $font_width = $w_main->fontMeasure($f_fixed, "X");

  my $line_height = $self->biggest_metric($f_fixed, $f_variable, "-linespace");
#  my $line_height = $w_main->fontMetrics($f_fixed, "-linespace");

  $line_height += $options->{"fontspace"} if exists $options->{"fontspace"};

#  $self->line_ascent($self->biggest_metric($f_fixed, $f_variable, "-ascent"));
#  $self->line_descent($self->biggest_metric($f_fixed, $f_variable, "-descent"));

  my $canvas_x = $options->{"x"} || int($w_main->screenwidth * 0.7);
  my $canvas_y;
  if ($options->{"y"}) {
    $canvas_y = $options->{"y"};
  } else {
    my $y = int($w_main->screenheight * 0.6);
    my $rows = int($y / $line_height);
    $canvas_y = $rows * $line_height;
    # round to a multiple of the line height
  }

  $c = $w_main->Canvas(
		       "-width" => $canvas_x,
		       "-height" => $canvas_y,
		       "-bg" => $self->default_bg(),
		       "-takefocus" => 1,
		       "-highlightthickness" => 0,
		      );

  if ($need_status) {
    $status_line = $w_main->Canvas(
				   "-borderwidth" => 0,
				   "-relief" => "flat",
				   "-width" => $canvas_x,
				   "-height" => $line_height,
				   "-bg" => $self->sbg(),
				   "-takefocus" => 0,
				  );
    
    $status_line->pack("-anchor" => "n",
		       "-fill" => "x");
  }

  $self->line_height($line_height);
  $Y_BORDER = $line_height / 2;

  $self->fixed_font_width($font_width);

  $self->set_geometry();

  $abs_x = X_BORDER;
  # HACK
  $abs_y = $canvas_y - $line_height;

  $c->pack("-anchor" => "s",
	   "-expand" => 1,
	   "-fill" => "both");

  $w_main->after(0, $init_sub);
  # delay required??

  MainLoop;

  return 1;
}

sub update {
  # force screen refresh
  $c->update();
}

sub fatal_error {
  $_[0]->SUPER::fatal_error($_[1]);
}

sub fixed_font_default {
  # true or false: does this zio use a fixed-width font?
  return 0;
}

sub manual_status_line {
  # true or false: does this zio want to draw the status line itself?
  return 1;
}

sub create_text {
  # given a widget, create text w/specified properties.
  # automatically adds the tag for the current font in effect.
  my ($self, $widget, @args) = @_;
  push @args, ("-font" => $self->current_font()) if $self->current_font();
#  printf STDERR "ct in %s: %s\n", $widget, join ",",@args;
  my $id = $widget->create("text", @args);
#  print "ct: $id\n";
  return $self->last_text_id($id);
}

sub write_string {
  my ($self, $string, $x, $y) = @_;
  $self->absolute_move($x, $y) if defined($x) and defined($y);
  
#  printf STDERR "ws: \"%s\" at %s,%d; ax=%s\n", $string, $abs_x, $abs_y, $w_main->fontMeasure($self->current_font(), $string);

  my $lh = ($self->line_height() / 2) + 1;
  my $ffw = $self->fixed_font_width();
  my $x_fudge = $ffw / 2;
  my $after = $abs_x + (length($string) * $ffw) + $x_fudge;
#  printf STDERR "Wrote \"%s\" x=%s-%s, y=%s-%s\n", $string, $abs_x - $x_fudge, $after, $abs_y, $abs_y + $lh if $string =~ /more/i;
#  printf STDERR "Wrote \"%s\" at %s,%s\n", $string, $abs_x, $abs_y if $string =~ /more/i;

  foreach ($c->find("enclosed", $abs_x, $abs_y - $lh,
		    $after, $abs_y + $lh)) {
    if ($c->type($_) eq "text") {
#      printf STDERR "  removing item #%d (%s)\n", $_, $c->itemcget($_, "-text");
      $c->delete($_);
    }
  }
  
#  printf STDERR "ws: \"%s\" at: x=%s y=%s\n", $string, $abs_x, $abs_y;
  my $is_reverse = $self->story()->font_mask() & Games::Rezrov::ZConst::STYLE_REVERSE;

  my $id = $self->create_text($c, $abs_x, $abs_y,
			      "-anchor" => TEXT_ANCHOR,
			      "-text" => $string,
			      "-fill" => $is_reverse ? $self->bg() : $self->fg());
  confess "ouch" unless defined $self->current_window();
  $widgets{$self->current_window()}{$id} = $abs_row;
#  printf STDERR "Creating %s at line %d\n", $string, $abs_row;

  my ($x1, $y1, $x2, $y2) = $c->bbox($id);
  my $sw = $self->string_width($string);
  $self->create_reverse($id, $sw, $is_reverse) if $is_reverse or
    $self->bg() ne $self->default_bg();
  $abs_x += $sw;
  # FIX ME; if using default fonts!
#  printf STDERR "ax+=%d, now:%s\n", $x2- $x1, $abs_x;
}

sub create_reverse {
  my ($self, $text_id, $width, $is_reverse) = @_;

#  printf STDERR "reversing: %s\n", $c->itemcget($text_id, "-text");

  unless (defined $text_id) {
    $width = $self->get_width() - $abs_x;
    $is_reverse = 0;
  }

  my $top = $abs_y;
  my $bottom = $abs_y + $self->line_height();

  my $lh2 = $self->line_height() / 2;
  $top = $abs_y - $lh2;
  $bottom = $abs_y + $lh2;

  my $id = $c->create("polygon",
		      $abs_x, $top,
		      $abs_x + $width, $top,
		      $abs_x + $width, $bottom,
		      $abs_x, $bottom,
		      "-fill" => $is_reverse ? $self->fg() : $self->bg(),
		     );
  $c->lower($id);
  $widgets{$self->current_window()}{$id} = $abs_row;

  $c->lower($id, $text_id) if defined $text_id;
}

sub string_width {
  # return width, in pixels, of the given string
  my $cf = $_[0]->current_font();
  if ($cf) {
    return $w_main->fontMeasure($cf, $_[1]);
  } else {
    my $id = $c->create("text", 0,0, "-text" => $_[1]);
    my ($x1, $y1, $x2, $y2) = $c->bbox($id);
    $c->delete($id);
    printf STDERR "eek! %d\n", $x2 - $x1;
    return ($x2 - $x1);
  }
}

sub newline {
#  print STDERR "nl\n";
#  carp "nl";
  $_[0]->story->flush();
  if ($_[0]->bg() ne $_[0]->default_bg()) {
    # we're ending the line, and the current background color
    # differs from the default.  Fill out the rest of the line
    # the the current background color.
    print "newline fill\n";
    $_[0]->create_reverse();
  }

  my $line_height = $_[0]->line_height();
  $abs_x = X_BORDER;
  $abs_y += $line_height;
  $abs_row++;

#  my $count = 0;

  my $ch = get_height();

#  print STDERR "ar=$abs_row; $ch $abs_y $line_height\n";
#  if ($abs_y >= $ch - $line_height) {
  if ($abs_row >= $rows) {
    # cursor is at bottom of screen; scroll needed
    my ($id, $protected, $line, $ref);
    foreach my $win (keys %widgets) {
      $protected = $win == Games::Rezrov::ZConst::UPPER_WIN ? $upper_lines - 1 : undef;
      # items created in the upper window do not scroll if they are within the
      # current bounds of the upper window.
      $ref = $widgets{$win};
      while (($id, $line) = each %{$ref}) {
#	$count++;
	unless (defined($protected) and $line <= $protected) {
	  if ($line-- <= $upper_lines) {
	    # item will be offscreen after scroll, delete it instead
#	    print STDERR "deleting $id\n";
	    $c->delete($id);
	    delete $ref->{$id};
	  } else {
	    # scroll up
	    $c->move($id, 0, - $line_height);
	    $ref->{$id} = $line;
	  }
	}
      }
    }
#    print "widgets: $count\n";

    $abs_y -= $line_height;
    $abs_row--;
  }

  $_[0]->story()->register_newline();
  $c->update() if Games::Rezrov::ZOptions::MAXIMUM_SCROLLING();
}

sub write_zchar {
  # write an unbuffered character
#  printf STDERR "wz: \"%s\"\n", chr($_[1]);
  if (STANDARD_COMPLIANT_BUT_EVEN_SLOWER) {
    # This is compliant with the spec but bogs down mighty quick.
    # Spec says the upper window output must not be buffered;
    # unfortunately this requires we create a widget for every
    # character in the upper window  :P
    $_[0]->write_string(chr($_[1]));
  } else { 
    # not compliant with spec but much more efficient.
    # the various other flush() calls in the package are required
    # to make this work.
    $_[0]->SUPER::buffer_zchar($_[1]);
  }
}

sub absolute_move {
  # set absolute column, row position; independent of window!
  my ($self, $col, $row) = @_;

  $self->story->flush();
  $abs_x = X_BORDER + ($col * $self->fixed_font_width());
  $abs_y = $Y_BORDER + ($row * $self->line_height());
  # when text items are created, with anchor "w" they are centered
  # vertically at the given coordinates.  So at row 0, text will
  # be drawn from  (- (font_height / 2)) to (font_height / 2).
  #
  # An earlier version just anchored text to the NW which was
  # simpler.  However, reversed text was centered funny if the font 
  # metrics were very different between fixed and variable fonts.

#  printf STDERR "am: %d,%d = %s,%s\n", $col, $row, $abs_x, $abs_y;
  $abs_row = $row;
}

sub absolute_move_pixels {
  ($abs_x, $abs_y) = @_[1,2];
}

sub get_pixel_position {
  return ($abs_x, $abs_y);
}

sub get_pixel_geometry {
  return (get_width() - X_BORDER, get_height());
  # HACK
}

sub get_position {
  # with no arguments, return absolute X and Y coordinates (column/row).
  # With an argument, return a sub that will restore the current cursor
  # position.
  my ($self, $sub) = @_;
  my ($x, $y) = ($abs_x, $abs_y);
  if ($sub) {
    return sub {
#      print STDERR "restoring x=$x y=$y\n";
      $abs_x = $x;
      $abs_y = $y;
    };
  } else {
    return (int($abs_x / $self->fixed_font_width()),
	    int($abs_y / $self->line_height()));
  }
}

sub status_hook {
  # we're drawing the status line manually.
  # might be possible to move this back to story:
  #  - measure string widths to position?
  #  - redraw when columns change?
  my ($self, $zstatus) = @_;

  $self->last_zstatus($zstatus);
  my $y = $status_line->height() / 2;
  $status_line->delete($status_line->find("all"));
  my $id = $self->create_text($status_line,
			      X_BORDER, $y,
			      "-anchor" => "w",
			      "-text" => $zstatus->location,
			      "-fill" => $self->sfg());

  my $string;
  if ($zstatus->time_game()) {
    my $hours = $zstatus->hours();
    my $minutes = $zstatus->minutes();
    my $style = $hours < 12 ? "AM" : "PM";
    $string = sprintf("Time: %d:%02d%s",
			 ($hours > 12 ? $hours - 12 : $hours),
			 $minutes, $style);
  } else {
    my $score = $zstatus->score();
    my $moves = $zstatus->moves();
    my $buf = length($score) + length($moves);
    $string = "Score: " . $score . "  Moves: " . $moves;
  }
  $id = $self->create_text($status_line,
			   200, $y,
			   "-anchor" => "e",
			   "-text" => $string,
			   "-fill" => $self->sfg());
  my ($x1, $y1, $x2, $y2) = $status_line->bbox($id);
  $status_line->move($id, $c->width() - X_BORDER - $x2, 0);
  # right-justify the text
}

sub cursor_on {
  my ($self, $x) = @_;
  $self->cursor_x($x);
  $self->cursor_status(1);
  $self->draw_cursor();
  $self->blink_init();
}

sub draw_cursor {
  my ($self) = @_;
  my $x = $self->cursor_x();
  return unless $x;
  $self->cursor_off();
  # make sure we remove old cursor
  if ($self->cursor_status()) {
    # if "blinking" only draw if on
#    my $top = $abs_y;
#    my $bottom = $abs_y + $self->line_height();

    my $lh2 = $self->line_height() / 2;
    my $top = $abs_y - $lh2;
    my $bottom = $abs_y + $lh2;

    my $cx = $self->fixed_font_width() * 0.7;
    my $id = $c->create("polygon",
			$x, $top,
			$x + $cx, $top,
			$x + $cx, $bottom,
			$x, $bottom,
			"-fill" => $self->cc());
    #  print "drawing cursor at $x w=$cx t=$top b=$bottom\n";
    $self->cursor_id($id);
  }
}

sub cursor_off {
  $c->delete($_[0]->cursor_id()) if $_[0]->cursor_id();
}

sub get_input {
  my ($self, $max, $single_char, %options) = @_;
  my $buffer = "";
  my $last_id;
  if ($options{"-preloaded"}) {
    # preloaded text in the buffer, but already displayed by the game; ugh.
    #
    # from sect15.html#read --
    #
    #   "Just a tremendous pain in my butt"
    #       -- Andrew Plotkin
    #   "the most unfortunate feature of the Z-machine design"
    #       -- Stefan Jokisch
    #
    my $pre = $options{"-preloaded"};
    my $last = $self->last_text_id();
    my $last_text = $c->itemcget($last, "-text");
    if ($last_text =~ /$pre$/) {
      $last_text =~ s/$pre$//;
      $c->itemconfigure($last, "-text" => $last_text);
      my $width = $self->string_width($pre);
      $last_id = $self->create_text($c,
				    $abs_x - $width,
				    $abs_y,
				    "-anchor" => TEXT_ANCHOR,
				    "-text" => $pre,
				    "-fill" => $self->fg(),
				   );
      $widgets{$self->current_window()}{$last_id} = $abs_row;
      $buffer = $pre;
      $self->cursor_on($abs_x);
      # start the cursor *after* the preloaded input...
      $abs_x -= $width;
      # ...and redraw the line from *before* it
    } else {
      print STDERR "miserable preload failure in get_input...\n";
    }
  } else {
    $self->cursor_on($abs_x);
  }
  my $done = 0;

  my $callback = sub {
    my $key = ord($w_main->XEvent()->A());
#    printf "callback: %s (%d)\n", $_[1], ord($_[1]);
    if ($key == Games::Rezrov::ZConst::ASCII_CR or
	$key == Games::Rezrov::ZConst::ASCII_LF) {
      $done = 1;
      $self->cursor_off();
      if ($single_char) {
	$buffer = chr(Games::Rezrov::ZConst::Z_NEWLINE);
      } else {
	$self->newline();
      }
      return;
    } elsif ($key == Games::Rezrov::ZConst::ASCII_DEL or
	     $key == Games::Rezrov::ZConst::ASCII_BS) {
      if ($single_char) {
	$done = 1;
	$buffer = chr(Games::Rezrov::ZConst::Z_DELETE);
      } else {
	$buffer = substr($buffer, 0, length($buffer) - 1) if length $buffer;
      }
    } elsif ($key >= 32 and $key <= 126) {
      $buffer .= chr($key);
    } else {
      printf STDERR "unhandled key code %d (%s)\n", $key, chr($key) if $key;
#      $buffer .= $key;
    }
    if ($single_char) {
      $done = 1;
    } else {
      my $cwin = $self->current_window();
      if ($last_id) {
	$c->delete($last_id);
	delete $widgets{$cwin}{$last_id};
      }
      $self->cursor_off();
      $last_id = $self->create_text($c,
				    $abs_x, $abs_y,
				    "-anchor" => TEXT_ANCHOR,
				    "-text" => $buffer,
				    "-fill" => $self->fg());
      $widgets{$cwin}{$last_id} = $abs_row;

      my ($x1, $y1, $x2, $y2) = $c->bbox($last_id);
      # FIX ME: get_width(), etc.
      $self->cursor_on($x2);
      $c->update();
    }
  };
  $self->bind_keys_to($callback);
  while ($done == 0) {
    $c->after(10);
    # to cut down on CPU time a little (does this help?)
    $c->update();
    # FIX ME: why do we need this???
  }
  $self->cursor_off();
  $self->blink_init(1);
  $self->bind_keys_to(sub {});
  return $buffer;
}

sub bind_keys_to {
  my ($self, $callback) = @_;

  $w_main->bind("<Any-KeyPress>" => $callback);
}

sub clear_to_eol {
  my $lh = $_[0]->line_height();

  my @l = $c->find("enclosed",
		   0,
		   $abs_y - $lh,
		   $c->width(),
		   $abs_y + $lh);

  $c->delete(@l);
#  print STDERR "el: $_[1]\n";
#  $c->create("text", 10, $abs_y, "-text" => "line $_[1]");
#  $c->update;
#  sleep 1000;
}

sub clear_screen {
  # clear the entire screen
  $c->delete($c->find("all"));
  $c->configure("-bg" => $_[0]->bg());
  # make sure the canvas background is set to the background color
  # currently in effect.  This is critical for games like "photopia.z5"
}

sub set_text_style {
  # arg is the font mask currently in effect; higher-level code
  # manages this
  my ($self, $mask) = @_;
  if ($self->dumb_fonts()) {
    return $self->current_font("");
  } else {
    my $family = ($mask & Games::Rezrov::ZConst::STYLE_FIXED) ?
      FIXED_FAMILY : $self->variable_font_family();
    my $weight = ($mask & Games::Rezrov::ZConst::STYLE_BOLD) ? "bold" : "normal";
    my $slant = ($mask & Games::Rezrov::ZConst::STYLE_ITALIC) ? "italic" : "roman";
    
    my $key = $family . "_" . $weight . "_" . $slant;
    my $fc = $self->font_cache();
    my $font;
    unless ($font = $fc->{$key}) {
#      print "new font\n";
      $font = $w_main->fontCreate("-family" => $family,
				  "-weight" => $weight,
				  "-slant" => $slant,
				  "-size" => $self->font_size());
      $fc->{$key} = $font;
    }
#    printf "%d: %s/%s/%s = %s\n", $mask, $family, $weight, $slant, $font;
    $self->current_font($font);
    return $font;
  }
}

sub can_change_title {
  return 1;
}

sub can_use_color {
  return 1;
}

sub set_game_title {
  $w_main->title($_[1]);
}

sub cleanup {
  # don't just rely on DESTROY, doesn't work for interrupts
  $w_main->destroy() if $w_main;
#  Tk::exit();
  # cleaner; see Tk::exit.pod.  Without, often coredumps.
  # but if we do this, will we miss a die() message elsewhere?
}

sub init_colors {
  my ($self, $options) = @_;
  if ($options->{"fg"} and $options->{"bg"}) {
    # FIX ME: check colors
    $self->default_fg($options->{"fg"});
    $self->default_bg($options->{"bg"});
    if ($options->{"sfg"} and $options->{"sbg"}) {
      $self->sfg($options->{"sfg"});
      $self->sbg($options->{"sbg"});
    } else {
      # default; use inverse for status line
      $self->sfg($self->default_bg());
      $self->sbg($self->default_fg());
    }
  } else {
    $self->default_fg(DEFAULT_FOREGROUND_COLOR);
    $self->default_bg(DEFAULT_BACKGROUND_COLOR);
    $self->sfg(DEFAULT_BACKGROUND_COLOR);
    $self->sbg(DEFAULT_FOREGROUND_COLOR);
    # status = invert
  }
  $self->fg($self->default_fg());
  $self->bg($self->default_bg());
  $self->cc($options->{"cc"} || DEFAULT_CURSOR_COLOR);
}

sub validate_family {
  my ($self, $family) = @_;
  my %families = map {lc($_) => 1} $w_main->fontFamilies();
  if (exists ($families{lc($family)})) {
    return $family;
  } else {
    die sprintf "%s is not a valid font family on your system.  Valid families are: %s\n", $family, join ", ", sort keys %families;
    
  }
}

sub handle_resize {
  my ($self) = @_;
  $self->status_hook($self->last_zstatus()) if $self->last_zstatus();
  $self->set_geometry();
}

sub blink_init {
  my ($self, $cancel) = @_;
  $w_main->afterCancel($self->blink_id()) if $self->blink_id();
  # called whenever cursor is turned on by the app; leave cursor
  # alone for X milliseconds, then blink periodically

  unless ($cancel) {
    my $blink_delay = exists $self->options()->{"blink"} ?
      $self->options()->{"blink"} : DEFAULT_BLINK_DELAY;
    if ($blink_delay) {
      $self->blink_id($w_main->repeat($blink_delay, [ $self => 'cursor_blinker' ]));
    }
  }
}

sub cursor_blinker {
  my ($self) = @_;
  $self->cursor_status(!$self->cursor_status());
  $self->draw_cursor();
  # needs work: if cursor is printed by the app, we should
  # leave it on for awhile...
}

sub split_window {
  $upper_lines = $_[1];
#  print STDERR "ul: $upper_lines\n";
}

sub get_height {
  my $h = $c->height();
  $h = $c->reqheight() if $h == 1;
  return $h;
}

sub get_width {
  my $w = $c->width();
  $w = $c->reqwidth() if $w == 1;
  return $w;
}

sub set_geometry {
  # figure out rows/columns
  my $self = shift;
  my ($cx, $cy) = $self->get_pixel_geometry();
  my $lh = $self->line_height();

  $rows = int($cy / $lh);
  my $columns = int($cx / $self->fixed_font_width());
#  printf STDERR "cx:%d cy:%d lh:%d geometry: %dx%d\n",
#  $cx, $cy, $self->line_height(), $columns, $rows;
  my $story = $self->story();

#  print STDERR "rows: $rows\n";
  $story->rows($rows);
  $story->columns($columns);
  
  if (defined($abs_y)) {
      my $bottom = $Y_BORDER + ($rows * $self->line_height());
      if ($abs_y > $bottom) {
	  # eek, cursor is below the bottom of the new screen
	  $abs_y = $bottom;
      }
  }
}

sub biggest_metric {
  my ($self, $f1, $f2, $metric) = @_;
  my $v1 = $w_main->fontMetrics($f1, $metric);
  my $v2 = $w_main->fontMetrics($f2, $metric);
#  print "$metric $v1 $v2\n";
  return $v1 > $v2 ? $v1 : $v2;
}

sub set_font {
  my ($self, $type) = @_;
  printf "set_font: %s win=%s\n", $type, $self->current_window();
  if ($type == Games::Rezrov::ZConst::FONT_NORMAL) {
    $self->last_font($type);
    return $type;
  }
  return 0;
}

1;
