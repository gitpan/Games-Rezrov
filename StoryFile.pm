package Games::Rezrov::StoryFile;
# manages game file data and implements many non-io-related opcodes.
# Opcode inclusion made more sense in Java, where the data was a
# more sensible instance variable; oh well.
#
#  - Separate functions for routines that use and increment the PC
#    as opposed to specifying an absolute address; done for speed
#    - get_byte() / get_byte_at(), etc

use strict;
use FileHandle;
use Carp qw(cluck croak confess);
#use integer;
# "use integer" is required for mod() to work correctly; see
# math tests in "etude.z5"

use Games::Rezrov::ZHeader;
use Games::Rezrov::ZFrame;
use Games::Rezrov::ZObject;
use Games::Rezrov::ZText;
use Games::Rezrov::ZStatus;
use Games::Rezrov::ZDict;
use Games::Rezrov::ZReceiver;
use Games::Rezrov::ZConst;
use Games::Rezrov::Quetzal;
use Games::Rezrov::ZIO_Tools;
use Games::Rezrov::ZObjectCache;
use Games::Rezrov::Inliner;

use constant ROWS => 0;
use constant COLUMNS => 1;

use Games::Rezrov::MethodMaker ([2],
			 qw(
			    guessing_title
			    flushing
			    object_cache
			    prompt_buffer
			    last_savefile
			    title_guessed
			    filename
			    zstatus
			    zdict
			    ztext
			    header
			    version
			    call_stack
			    undo_slots
			    last_input
			    last_score
			    last_prompt
			    transcript_filename
			    player_object
			    first_room
			    current_room
			    current_input_stream
			    input_filehandle
			    game_title
			    window_cursors
			    quetzal
			    lines_wrote
			    wrote_something
			    push_command
			    zios
			    selected_streams
			    tailing
			    full_version_output
			    global_variable_address
			   )
			 );

my $next_method_index = Games::Rezrov::MethodMaker::get_count();
my $FM_INDEX = $next_method_index++;

$Games::Rezrov::PC = 1;
# static: current game PC.  UGH.

$Games::Rezrov::STORY_BYTES = undef;
# story file data.
# HACK: this is *static* for speed.  having to deref $self->bytes()
# all the time seems like it's going to be really slow.
# a further compromise might be to ditch the "object" approach altogether
# and just export all these functions; story data can still be kept
# "privately" in this module.

my $dynamic_area;
# bytes in the story that can be changed by the game.
# Used for "verify" opcode and game saves/restores.
# (Also traditionally usually used for restarts, but we Lazily just 
# reload the whole image)

# more for-speed hacks related to writing bytes to the transcript stream:
my $current_window = Games::Rezrov::ZConst::LOWER_WIN;

use constant UNSIGNED_BYTE => 0xff;

use constant LINEFEED => 10;
# ascii

my $current_frame;
# keeping this global is a speedup; it's used all the time

my $buffering;
my ($upper_lines, $lower_lines);
# HACKS, FIX ME

my $INLINE_CODE = '
sub call {
  my ($self, $argv, $type) = @_;
  # call a routine, either as a procedure (result thrown away)
  # or a function (result stored).  First argument of argv
  # is address of function to call.
  if ($argv->[0] == 0) {
    # spec 6.4.3: calls to address 0 return 0
    $self->store_result(0) if ($type == Games::Rezrov::ZFrame::FUNCTION);
  } else {
    $self->push_frame();
    # make a new frame
    $current_frame->call_type($type);
    # set type of call (to this frame from parent)
    
    $Games::Rezrov::PC = $self->convert_packed_address($argv->[0]);
    # set the current PC
    
    my $args = GET_BYTE();
    # spec 5.2: routine begins with an arg count
    die "impossible arg count of $args"
      if ($args < 0 || $args > Games::Rezrov::ZFrame::MAX_LOCAL_VARIABLES);
    
    #      ZInterpreter.zdb.save("call type " + type + " argc:" + argc + " args:" + args);  # debug
    #      current.arg_count = args;
    my $argc = scalar @{$argv};
    $current_frame->arg_count($argc - 1);
    # do not count procedure being called in argument count
    
    my $arg;
    my $local_count = 0;
    my $i = 1;
    my $z_version = $self->version();
    while (--$args >= 0) {
      # set local variables
      $arg = $z_version >= 5 ? 0 : GET_WORD();
      # spec 5.2.1: default variables follow if version < 5
      $current_frame->set_local_var($local_count++, (--$argc > 0) ? $argv->[$i++] : $arg);
    }
  }
}

sub store_result {
  # called by opcodes producing a result (stores it).
  my $where = GET_BYTE();
  # see spec 4.2.2, 4.6.
  # zip code handles this in store_operand, and in the case of
  # variable zero, pushes a new variable onto the stack.
  # The store_variable() call only SETS the topmost variable,
  # and does not add a new one.   Is that code ever reached?  WTF!

#  printf STDERR "store_result: %s where:%d\n", $_[1], $where;

  if ($where == 0) {
    # routine stack: push value
    # see zmach06e, p 33
    $current_frame->routine_push(UNSIGNED_WORD($_[1]));
    # make sure the value is cast into unsigned form.
    # see add() for a lengthy debate on the subject.
  } else {
    $_[0]->set_variable($where, $_[1]);
    # set_variable does casting for us
  }
}

sub conditional_jump {
  # see spec section 4.7, zmach06e.txt section 7.3
  # argument: condition
  my $control = GET_BYTE();
  
  my $offset = $control & 0x3f;
  # basic address is six low bits of the first byte.
  if (($control & 0x40) == 0) {
    # if "bit 6" is not set, address consists of the six (low) bits 
    # of the first byte plus the next 8 bits.
    $offset = ($offset << 8) + GET_BYTE();
    if (($offset & 0x2000) > 0) {
      # if the highest bit (formerly bit 6 of the first byte)
      # is set...
      $offset |= 0xc000;
      # turn on top two bits
      # FIX ME: EXPLAIN THIS
    }
  }
  
  if ($control & 0x80 ? $_[1] : !$_[1]) {
    # normally, branch occurs when condition is false.
    # however, if topmost bit is set, jump occurs when condition is true.
    if ($offset > 1) {
      # jump
      $_[0]->jump($offset);
    } else {
      # instead of jump, this is a RTRUE (1) or RFALSE (0)
      $_[0]->ret($offset);
    }
  }
}

sub add {
  # signed 16-bit addition
  # args: self, x, y
#  my ($self, $x, $y) = @_;
#  die if $x & 0x8000 or $y & 0x8000;

#  my $result = unsigned_word(signed_word($x) + signed_word($y));
  # this does not work correctly; example:
  # die in zork 1 (teleport chasm, N [grue]), score has -10 added
  # to it, result is 65526.  Since value is always stored internally,
  # do not worry about converting to unsigned.  Brings up a larger issue:
  # sometimes store_result writes data to the story, in which case
  # we need an unsigned value!  Solution -- do this casting only if
  # we _need_ to, ie writing bytes to the story: see set_global_var()

  # Unfortunately, this breaks Trinity:
  # count:538 pc:97444 type:2OP opcode:20 (add) operands:36910,100
  # here we get into trouble because the sum uses the sign bit (0x8000) 
  # but it is an UNSIGNED value!  So in this case we *must* make sure
  # the result is unsigned.  Solution #2: change store_result to
  # make sure everything is unsigned.  Cast to signed only when we are
  # sure the data is signed (see set_variable, scores)
  
#  $self->store_result(signed_word($x) + signed_word($y));
  $_[0]->store_result(SIGNED_WORD($_[1]) + SIGNED_WORD($_[2]));
}

sub subtract {
  # signed 16-bit subtraction: args $self, $x, $y
  $_[0]->store_result(SIGNED_WORD($_[1]) - SIGNED_WORD($_[2]));
}

sub multiply {
  # signed 16-bit multiplication: args $self, $x, $y
  $_[0]->store_result(SIGNED_WORD($_[1]) * SIGNED_WORD($_[2]));
}

sub divide {
  # signed 16-bit division: args $self, $x, $y
  $_[0]->store_result(SIGNED_WORD($_[1]) / SIGNED_WORD($_[2]));
}

sub compare_jg {
  # jump if a is greater than b; signed 16-bit comparison
  $_[0]->conditional_jump(SIGNED_WORD($_[1]) > SIGNED_WORD($_[2]));
}

sub compare_jl {
  # jump if a is less than b; signed 16-bit comparison
  $_[0]->conditional_jump(SIGNED_WORD($_[1]) < SIGNED_WORD($_[2]));
}

sub output_stream {
  #
  # select/deselect output streams.
  # 
  my $self = $_[0];
  my $str = SIGNED_WORD($_[1]);
  my $table_start = $_[2];

  return if $str == 0;
  # selecting stream 0 does nothing

#  print STDERR "output_stream $str\n";
  my $astr = abs($str);
  my $selecting = $str > 0 ? 1 : 0;
  my $selected = $self->selected_streams();
  my $zios = $self->zios();
  if ($astr == Games::Rezrov::ZConst::STREAM_REDIRECT) {
    #
    #  stream 3: redirect output to a table exclusively (no other streams)
    #
    my $stack = $zios->[Games::Rezrov::ZConst::STREAM_REDIRECT];
    if ($selecting) {
      #
      # selecting
      #
      my $buf = new Games::Rezrov::ZReceiver();
      $buf->misc($table_start);
      push @{$stack}, $buf;
      $self->fatal_error("illegal number of stream3 opens!")
	if @{$stack} > 16;
      # 7.1.2.1.1: max 16 legal redirects
    } else {
      #
      # deselecting: copy table to memory
      #
      my $buf = pop @{$stack};
      my $table_start = $buf->misc();
      my $pointer = $table_start + 2;
      my $buffer = $buf->buffer();
      for (my $i=0; $i < length($buffer); $i++) {
	$self->set_byte_at($pointer++, ord substr($buffer,$i,1));
      }
      $self->set_word_at($table_start, ($pointer - $table_start - 2));
      # record number of bytes written
      if (@{$stack}) {
	# this is stacked; keep redirection on (7.1.2.1.1)
	$selected->[$astr] = 1;
      }
    }
  } elsif ($astr == Games::Rezrov::ZConst::STREAM_TRANSCRIPT) {
    if ($selecting) {
#      print STDERR "opening transcript\n";
      if (my $filename = $self->transcript_filename() ||
	  $self->filename_prompt("-check" => 1,
				 "-ext" => "txt",
				 )) {
	$self->transcript_filename($filename);
	# 7.1.1.2: only ask once
	my $fh = new FileHandle;
	if ($fh->open(">$filename")) {
	  $zios->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT] = $fh;
	} else {
	  $self->write_text(sprintf "Yikes, I can\'t open %s: %s...", $filename, lc($!));
	  $selecting = 0;
	}
      } else {
	$selecting = 0;
      }
      unless ($selecting) {
	$self->newline();
	$self->newline();
      }
    } else {
      # closing transcript
      my $fh = $zios->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT];
      $fh->close() if $fh;
    }
  } elsif ($astr == Games::Rezrov::ZConst::STREAM_COMMANDS) {
    if ($selecting) {
      my $filename = $self->filename_prompt("-ext" => "cmd",
					    "-check" => 1);
      if ($filename) {
	my $fh = new FileHandle();
	if ($fh->open(">$filename")) {
	  $zios->[Games::Rezrov::ZConst::STREAM_COMMANDS] = $fh;
	  $self->write_text("Recording to $filename.");
	} else {
	  $self->write_text("Can\'t write to $filename.");
	  $selecting = 0;
	}
      }
    } else {
      my $fh = $zios->[Games::Rezrov::ZConst::STREAM_COMMANDS];
      if ($fh) {
	$fh->close();
	$self->write_text("Recording stopped.");
      } else {
	$self->write_text("Um, I\'m not recording now.");
      }
    }
    $self->newline();
  } elsif ($astr == Games::Rezrov::ZConst::STREAM_STEAL) {
#    printf STDERR "steal: %s\n", $selecting;
    $zios->[Games::Rezrov::ZConst::STREAM_STEAL] = $selecting ? new Games::Rezrov::ZReceiver() : undef;
  } elsif ($astr != Games::Rezrov::ZConst::STREAM_SCREEN) {
    $self->fatal_error("Unknown stream $str");
  }

  $selected->[$astr] = $selecting;
}

sub erase_window {
  my $self = $_[0];
  my $window = SIGNED_WORD($_[1]);
  my $zio = $self->screen_zio();
  if ($window == -1) {
    # 8.7.3.3:
#    $self->split_window(Games::Rezrov::ZConst::UPPER_WIN, 0);
    # WRONG!
    $self->split_window(0);
    # collapse upper window to size 0
    $self->clear_screen();
    # erase the entire screen
    $self->reset_write_count();
    $self->set_window(Games::Rezrov::ZConst::LOWER_WIN);
    $self->set_cursor(($self->version() == 4 ? $self->rows() : 1), 1);
    # move cursor to the appropriate line for this version;
    # hack: at least it\'s abstracted :)
  } elsif ($window < 0 or $window > 1) {
    $zio->fatal_error("erase_window $window !");
  } else {
    #
    #  erase specified window
    #
    my $restore = $zio->get_position(1);
    my ($start, $end);
    if ($window == Games::Rezrov::ZConst::UPPER_WIN) {
      $start = 0;
      $end = $upper_lines;
    } elsif ($window == Games::Rezrov::ZConst::LOWER_WIN) {
      $start = $upper_lines;
      $end = $self->rows();
      $self->reset_write_count();
    } else {
      die "clear window $window!";
    }
    for (my $i = $start; $i < $end; $i++) {
#      $zio->erase_line($i);
      $zio->absolute_move(0, $i);
      $zio->clear_to_eol();
    }
    &$restore();
    # restore cursor position
  }
}

sub jump {
  # unconditional jump; modifies PC
  # see zmach06e.txt, section 8.4.
  # argument: new offset
  $Games::Rezrov::PC += SIGNED_WORD($_[1] - 2);
}

sub print_num {
  # print the given signed number.
  $_[0]->write_text(SIGNED_WORD($_[1]));
}

sub inc_jg {
  my ($self, $variable, $value) = @_;
  # increment a variable, and branch if it is now greater than value.
  my $before = SIGNED_WORD($self->get_variable($variable));
  my $new_val = SIGNED_WORD($before + 1);
  $self->set_variable($variable, $new_val);
  $self->conditional_jump($new_val > $value);
}

sub increment {
  # increment a variable (16 bits, signed)
  my ($self, $variable) = @_;
  my $value = SIGNED_WORD($self->get_variable($variable)) + 1;
  $self->set_variable($variable, UNSIGNED_WORD($value));
#  $self->set_variable($variable, $value);
}

sub decrement {
  # decrement a variable (16 bits, signed)
  my ($self, $variable) = @_;
  my $value = SIGNED_WORD($self->get_variable($variable)) - 1;
  $self->set_variable($variable, UNSIGNED_WORD($value));
#  $self->set_variable($variable, $value);
}

sub dec_jl {
  my ($self, $variable, $value) = @_;
  # decrement a signed 16-bit variable, and branch if it is now less than value.
  # FIX ME: is value signed or not???

  my $before = SIGNED_WORD($self->get_variable($variable));
  my $new_val = SIGNED_WORD($before - 1);
  $self->set_variable($variable, UNSIGNED_WORD($new_val));
#  $self->set_variable($variable, $new_val);
  $self->conditional_jump($new_val < $value);
}

sub mod {
  # store remainder after signed 16-bit division
  if (1) {
    use integer;
    # without "use integer", "%" operator flunks etude.z5 tests
    # (on all systems? linux anyway).
    # For example: perl normally says (13 % -5) == -2;
    #              it "should" be 3, or (13 - (-5 * -2))
    #
    # "use integer" computes math ops in integer, thus always
    # rounding towards zero and getting around the problem.
    #
    # Unfortunately, "use integer" must be scoped here lest it play
    # havoc in other places which require floating point division:
    # e.g. pixel-based text wrapping.
    $_[0]->store_result(SIGNED_WORD($_[1]) % SIGNED_WORD($_[2]));
  } else {
    # an alternative workaround?:
    my $x = SIGNED_WORD($_[1]);
    my $y = SIGNED_WORD($_[2]);
    my $times = int($x / $y);
    # how many times does $y fit into $x; always round towards zero!
    $_[0]->store_result($x - ($y * $times));
  }
}

sub set_variable {
  my $variable = $_[1];
  my $value = UNSIGNED_WORD($_[2]);
#  printf STDERR "set_variable %s = %s\n", $variable, $value;
  # see spec 4.2.2
  if ($variable == 0) {
    # top of routine stack; should we push, or just set?
    # does this ever get called like this, or is it always
    # via store_result?  (apparent discepancy in zip source code)
    die("hmm, does this ever happen?");
  } elsif ($variable <= 15) {
    # local
    $current_frame->set_local_var($variable - 1, $value);
#    printf STDERR "set local var #%d to %d\n", $variable, $value;
    # FIX ME: cast to unsigned???
  } else {
    # global
    $variable -= 16;
    # indexed starting at 0
    $_[0]->set_global_var($variable, $value);
    if (Games::Rezrov::ZOptions::EMULATE_NOTIFY() and
	$variable == 1 and
	!$_[0]->header()->is_time_game()) {
      # 8.2.3.1: "2nd" global variable holds score 
      # ("2nd" variable is index #1)
      my $score = SIGNED_WORD($value);
      my $last_score = $_[0]->last_score() || 0;
      my $diff = $score - $last_score;
      if ($diff and Games::Rezrov::ZOptions::notifying()) {
	$_[0]->write_text(sprintf "[Your score just went %s by %d points, for a total of %d.]",
			  ($diff > 0 ? "up" : "down"),
			  abs($diff), $score);
	$_[0]->newline();
	if ($last_score == 0) {
	  $_[0]->write_text("[NOTE: you can turn score notification on or off at any time with the NOTIFY command.]");
	  $_[0]->newline();
	}
      }
      $_[0]->last_score($score);
    }
  }
}

sub log_shift {
  my $number = SIGNED_WORD($_[1]);
  my $places = SIGNED_WORD($_[2]);
  my $result = $places > 0 ? $number << $places : abs($number) >> abs($places);
  # sign bit is lost when shifting right
  $_[0]->store_result($result);
}

';

Games::Rezrov::Inliner::inline(\$INLINE_CODE);
eval $INLINE_CODE;
undef $INLINE_CODE;

1;

sub new {
  my ($type, $filename, $zio) = @_;
  my $self = [];
  bless $self, $type;
  $zio->set_window(Games::Rezrov::ZConst::LOWER_WIN);
  $self->filename($filename);
  my $zios = [];
  $zios->[Games::Rezrov::ZConst::STREAM_SCREEN] = $zio;
  $zios->[Games::Rezrov::ZConst::STREAM_REDIRECT] = [];
  # this stream redirects to memory and can be a stack
  $self->zios($zios);
  $self->selected_streams([]);

  $self->version(0);
  # don't even ask :P

  return $self;
}

sub compare_jz {
  # branch if the value is zero
  $_[0]->conditional_jump($_[1] == 0);
}

sub setup {
  my $self = shift;
  my $zio = $self->screen_zio();

  my $rows = $self->rows();
  my $columns = $self->columns();
  die "zio did not set up geometry" unless $rows and $columns;

  # 
  #  Set up "loading" message:
  #
  if ($zio->can_split()) {
    my $message = "The story is loading...";
    $self->clear_screen();
    if ($zio->fixed_font_default()) {
      my $start_x = int(($columns / 2) - length($message) / 2);
      my $start_y = int($rows / 2);
      $zio->write_string($message, $start_x, $start_y);
    } else {
      my $width = $zio->string_width($message);
      my ($max_x, $max_y) = $zio->get_pixel_geometry();
      $zio->absolute_move_pixels(($max_x / 2) - ($width / 2),
				 $max_y / 2);
      $zio->write_string($message);
    }
    $zio->update();
  }
  
  $self->load();
  $self->current_input_stream(Games::Rezrov::ZConst::INPUT_KEYBOARD);
  $self->undo_slots([]);
  $self->window_cursors([]);
  # cursor positions for individual windows
  $self->reset_write_count();
  $self->object_cache(new Games::Rezrov::ZObjectCache($self));
  $self->quetzal(new Games::Rezrov::Quetzal($self));
  
  # story _must_ be loaded beyond this point...
  my $z_version = $self->version();
  Games::Rezrov::ZOptions::EMULATE_NOTIFY(0) if ($z_version > 3);
  # our notification trick only works for v3 games
  
  $self->ztext(new Games::Rezrov::ZText($self));
  $self->zstatus(new Games::Rezrov::ZStatus($self));
  my $zd = new Games::Rezrov::ZDict($self);
  if (Games::Rezrov::ZOptions::EMULATE_UNDO() and
      $zd->get_dictionary_address("undo")) {
    # disable undo emulation for games that supply the word "undo"
    Games::Rezrov::ZOptions::EMULATE_UNDO(0);
  }
  
  $self->output_stream(Games::Rezrov::ZConst::STREAM_SCREEN());
  
  $current_window = Games::Rezrov::ZConst::LOWER_WIN;
  # HACKS, FIX ME
#  $zio->set_version($self);
  $self->zdict($zd);
  $self->erase_window(-1);
  # collapses the upper window

  if ($zio->can_split() and
      !$zio->manual_status_line() and
     $z_version <= 3) {
    # in v3, do a bogus split_window(), using the "upper window" 
    # for the status line.
    # this is broken: seastalker!
    $self->split_window(1);
  }
  
  $self->set_window(Games::Rezrov::ZConst::LOWER_WIN);

  if (0) {
    # debugging
    $self->set_cursor(1,1);
    my $message = "line 1, column 1";
    $self->write_zchunk(\$message);
    $self->screen_zio()->update();
    sleep 10;
  }
}

sub AUTOLOAD {
  # probably an unimplemented opcode.
  # Send output to the ZIO to print it, as STDERR might not be "visible"
  # for some ZIO implementations
  $_[0]->fatal_error(sprintf 'unknown sub "%s": unimplemented opcode?', $Games::Rezrov::StoryFile::AUTOLOAD);
}

sub load {
  # completely (re-) load game data.  Resets all state info.
  my ($self, $just_version) = @_;
  my $filename = $self->filename();
  my $size = -s $filename;
  open(GAME, $filename) || die "can't open $filename: $!\n";
  binmode GAME;
  if ($just_version) {
    #
    # hack: just get the version of the game (first byte).
    #
    # We do this so we can initialize the I/O layer and put up
    # a "loading" message while we wait.  We need the version
    # to figure out whether to create a status line in the ZIO;
    # important for Tk version (visually annoying to create status
    # line later on)
    #
    my $buf;
    if (read(GAME, $buf, 1) == 1) {
      return unpack "C", $buf;
    } else {
      die "huh?";
    }
  } else {
    my $read = read(GAME, $Games::Rezrov::STORY_BYTES, $size);
    close GAME;
    die "read error" unless $read == $size;
    
    my $header = new Games::Rezrov::ZHeader($self, $self->screen_zio());
    $self->global_variable_address($header->global_variable_address());
    my $static = $header->static_memory_address();
    $dynamic_area = substr($Games::Rezrov::STORY_BYTES, 0, $static);
    #  vec($dynamic_area, 0x50, 8) = 12;
    
    $self->header($header);
    $self->version($header->version());
  }
}

sub get_byte_at {
  # return an 8-bit byte at specified storyfile offset.
#  die unless @_ == 2;
#  print STDERR "get_byte_at $_[1]\n" if $_[1] < 0x38;
#  print STDERR "gba\n";
  return vec($Games::Rezrov::STORY_BYTES, $_[1], 8);
}

sub save_area_byte {
  # return byte in "pristine" game image
  return vec($dynamic_area, $_[1], 8);
}

sub get_save_area {
  # return ref to "pristine" game image
  # Don't use this :)
  return \$dynamic_area;
}

sub get_story {
  # return ref to game data
  # Don't use this :)
  return \$Games::Rezrov::STORY_BYTES;
}

sub set_byte_at {
  # set an 8-bit byte at the specified storyfile offset to the
  # specified value.
  die unless @_ == 3;
#  print STDERR "sba\n";
  vec($Games::Rezrov::STORY_BYTES, $_[1], 8) = $_[2];
#  printf STDERR "  set_byte_at %s = %s\n", $_[1], $_[2];
}

sub get_word_at {
  # return unsigned 16-bit word at specified offset
#  die unless @_ == 2;
  
#  print STDERR "gwa\n";

#  return ((vec($Games::Rezrov::STORY_BYTES, $_[1], 8) << 8) + vec($Games::Rezrov::STORY_BYTES, $_[1] + 1, 8));
#  return unpack "n", substr($Games::Rezrov::STORY_BYTES, $_[1], 2);

  # using vec() and doing our bit-twiddling manually seems faster
  # than using unpack(), either with a substr...
  #
  #     $x = unpack "n", substr($Games::Rezrov::STORY_BYTES, $where, 2);
  #
  # or with using null bytes in the unpack...
  #
  #     $x = unpack "x$where n", $Games::Rezrov::STORY_BYTES
  #
  # Oh well...
  
#  print STDERR "get_word_at $_[1]\n" if $_[1] < 0x38;

  return ((vec($Games::Rezrov::STORY_BYTES, $_[1], 8) << 8) +
	  vec($Games::Rezrov::STORY_BYTES, $_[1] + 1, 8));
}

sub set_word_at {
  # set 16-bit word at specified index to specified value
  die unless @_ == 3;
#  croak if ($_[1] == 30823);
#  print STDERR "swa\n";
  vec($Games::Rezrov::STORY_BYTES, $_[1], 8) = ($_[2] >> 8) & UNSIGNED_BYTE;
  vec($Games::Rezrov::STORY_BYTES, $_[1] + 1, 8) = $_[2] & UNSIGNED_BYTE;
  if ($_[1] == Games::Rezrov::ZHeader::FLAGS_2) {
    # activity in flags controlling printer transcripting.
    # Transcripting is set by the game and not by its own opcode.
    # see 7.3, 7.4
    my $str = $_[2] & Games::Rezrov::ZHeader::TRANSCRIPT_ON ? Games::Rezrov::ZConst::STREAM_TRANSCRIPT : - Games::Rezrov::ZConst::STREAM_TRANSCRIPT;
    # temp variable to prevent "modification of read-only value"
    # error when output_stream() tries to cast @_ to signed short

    $_[0]->output_stream($str);
    # use stream-style notification to tell the game about transcripting
  }
#  printf STDERR "  set_word_at %s = %s\n", $_[1], $_[2];
}

sub get_string_at {
  # return string of bytes at given offset
  return substr($Games::Rezrov::STORY_BYTES, $_[1], $_[2]);
}

sub reset_game {
  # init/reset game state
  my $self = shift;
  $self->call_stack([]);
  $Games::Rezrov::PC = 0;
  $self->push_frame();
  # create toplevel "dummy" frame: no parent, but can still
  # create local and stack variables.  Also consistent with
  # Quetzal savefile model
  $Games::Rezrov::PC = $self->header()->first_instruction_address();
  # FIX ME: we could pack the address and then do a standard call()...
    
  $self->set_buffering(1);
  # 7.2.1: buffering is always on for v1-3, on by default for v4+.
  # We call this here so each implementation of ZIO doesn't have
  # to set the default.

  $self->reset_write_count();
  $self->clear_screen();
  $self->set_window(Games::Rezrov::ZConst::LOWER_WIN());

  # FIX ME: reset zios() array here!
  # centralize all this with setup() stuff...
}

sub reset_storyfile {
  # FIX ME: everything in the header should be wiped but the
  # "printer transcript bit," etc.
  my $self = shift;
  $self->load();
  # hack
}

sub set_current_frame {
  # set the current frame
  my $s = $_[0]->call_stack();
  $current_frame = $s->[$#$s];
}

sub push_frame {
  # push a call frame onto call stack
  my $self = shift;
  my $current = new Games::Rezrov::ZFrame($Games::Rezrov::PC);
  push @{$self->call_stack()}, $current;
  $self->set_current_frame();
}

sub load_variable {
  # get the value of a variable and store it.
  $_[0]->store_result($_[0]->get_variable($_[1]));
}

sub convert_packed_address {
  # unpack a packed address.  See spec 1.2.3
  my $version = $_[0]->version();
  if ($version >= 1 and $version <= 3) {
    return $_[1] * 2;
  } elsif ($version == 4 or $version == 5) {
    return $_[1] * 4;
  } else {
    die "don't know how to unpack addr for version $version";
  }
}

sub ret {
  my ($self, $value) = @_;
  # return from a subroutine
  my $call_type = $self->pop_frame();

  if ($call_type == Games::Rezrov::ZFrame::FUNCTION) {
    $self->store_result($value);
  } elsif ($call_type != Games::Rezrov::ZFrame::PROCEDURE) {
    die("known frame call type!");
  }
  return $value;
  # might be needed for an interrupt call (not yet implemented)
}


sub get_variable {
  # argument: variable
  if ($_[1] == 0) {
    # section 4.2.2: pop from top of stack
#    print STDERR "rp\n";
    return $current_frame->routine_pop();
  } elsif ($_[1] <= 15) {
    # local var
#    print STDERR "lv\n";
    return $current_frame->get_local_var($_[1] - 1);
  } else {
    # global var
#    print STDERR "gv\n";
    return $_[0]->get_global_var($_[1] - 16);
    # convert to index starting at 0
  }
}

sub signed_byte {
  # convert an unsigned byte to a signed byte
  return unpack "c", pack "c", $_[0];
}

sub unsigned_word {
  # pack a signed value into an unsigned value.
  # Necessary to ensure the sign bit is placed at 0x8000.
  return unpack "S", pack "s", $_[0];
}

sub compare_je {
  # branch if first operand is equal to any of the others
  my ($self, $first) = splice(@_,0,2);
  foreach (@_) {
    $self->conditional_jump(1), return if $_ == $first;
  }
  $self->conditional_jump(0);
}

sub store_word {
  my ($self, $array_address, $word_index, $value) = @_;
  # set a word at a specified offset in a specified array offset.
  $array_address += (2 * $word_index);
  $self->set_word_at($array_address, $value);
}

sub store_byte {
  my ($self, $array_address, $byte_index, $value) = @_;
  $array_address += $byte_index;
  $self->set_byte_at($array_address, $value);
}

sub pop_frame {
  my $self = shift;
  my $stack = $self->call_stack();
  my $last_frame = pop @{$stack};
  $self->set_current_frame();
  $Games::Rezrov::PC = $last_frame->rpc();
  return $last_frame->call_type();
}

sub get_word_index {
  # get a word from the specified index of the specified array
  my ($self, $address, $index) = @_;
  $self->store_result($self->get_word_at($address + (2 * $index)));
}

sub put_property {
  my ($self, $object, $property, $value) = @_;
  my $zobj = $self->get_zobject($object);
  my $zprop = $zobj->get_property($property);
  $zprop->set_value($value);
}

sub test_attr {
  # jump if some object has an attribute set
  my ($self, $object, $attribute) = @_;
  my $zobj = $self->get_zobject($object);
  $self->conditional_jump($zobj and $zobj->test_attr($attribute));
  # watch out for object 0
}

sub set_attr {
  # turn on given attribute of given object
  my ($self, $object, $attribute) = @_;
  if (my $zobj = $self->get_zobject($object)) {
    # unless object 0
    $zobj->set_attr($attribute);
  }
}

sub clear_attr {
  # clear given attribute of given object
  my ($self, $object, $attribute) = @_;
  if (my $zobj = $self->get_zobject($object)) {
    # unless object 0
    $zobj->clear_attr($attribute);
  }
}

sub print_text {
  # decode a string at the PC and move PC past it
  my $blob;
  ($blob, $Games::Rezrov::PC) = $_[0]->ztext()->decode_text($Games::Rezrov::PC);
  $_[0]->write_zchunk($blob);
}

sub write_zchunk {
  my ($self, $chunk) = @_;

  my $selected = $_[0]->selected_streams();
  my $zios = $_[0]->zios();
#  print STDERR "Chunk: $$chunk\n";
  if ($selected->[Games::Rezrov::ZConst::STREAM_REDIRECT]) {
    # 7.1.2.2: when active, no other streams get output
    my $stack = $zios->[Games::Rezrov::ZConst::STREAM_REDIRECT];
    $stack->[$#$stack]->buffer_zchunk($chunk);
  } else {
    #
    #  other streams
    #
    if ($selected->[Games::Rezrov::ZConst::STREAM_SCREEN]) {
      #
      #  screen
      #
      if ($selected->[Games::Rezrov::ZConst::STREAM_STEAL] and
	  $current_window == Games::Rezrov::ZConst::LOWER_WIN) {
	# temporarily steal lower window output
	$zios->[Games::Rezrov::ZConst::STREAM_STEAL]->buffer_zchunk($chunk);
      } else {
	my $zio = $zios->[Games::Rezrov::ZConst::STREAM_SCREEN];
	
	if ($buffering and $current_window != Games::Rezrov::ZConst::UPPER_WIN) {
	  $zio->buffer_zchunk($chunk);
	} else {
	  foreach (unpack("c*", $$chunk)) {
	    if ($_ == Games::Rezrov::ZConst::Z_NEWLINE) {
	      $_[0]->prompt_buffer("");
	      $zio->newline();
	    } else {
	      $zio->write_zchar($_);
	    }
	  }
	}
      }
    }

    if ($selected->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT] and
	$current_window == Games::Rezrov::ZConst::LOWER_WIN) {
      # 
      #  Game transcript
      #
      if (my $fh = $zios->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT]) {
	my $c = $$chunk;
	my $nl = chr(Games::Rezrov::ZConst::Z_NEWLINE);
	$c =~ s/$nl/\n/g;
	print $fh $c;
      }
    }
  }
}
  
sub print_ret {
  # print string at PC, move past it, then return true
  $_[0]->print_text();
  $_[0]->newline();
  $_[0]->rtrue();
}

sub newline {
  $_[0]->write_zchar(Games::Rezrov::ZConst::Z_NEWLINE());
}

sub loadb {
  # get the byte at index "index" of array "array"
  my ($self, $array, $index) = @_;
  $self->store_result($self->get_byte_at($array + $index));
}

sub bitwise_and {
  # story bitwise "and" of the arguments.
  # FIX ME: signed???
  $_[0]->store_result($_[1] & $_[2]);
}

sub bitwise_or {
  # story bitwise "or" of the arguments.
  # FIX ME: signed???
  $_[0]->store_result($_[1] | $_[2]);
}

sub rtrue {
  # return TRUE from this subroutine.
  $_[0]->ret(1);
}

sub rfalse {
  # return FALSE from this subroutine.
  $_[0]->ret(0);
}

sub write_text {
  # write a given string to ZIO.
  $_[0]->write_zchunk(\$_[1]);
#  foreach (unpack "C*", $_[1]) {
#    $_[0]->write_zchar($_);
#  }
}

sub insert_obj {
  my ($self, $object, $destination_obj) = @_;
  # move object to become the first child of the destination
  # object. 
  #
  # object = O, destination_obj = D
  #
  # reorganize me: move to ZObject?
  
#  my $o = new Games::Rezrov::ZObject($object, $self);
  return unless $object;
  # if object being moved is ID 0, do nothing (bogus object)

  my $o = $self->get_zobject($object);
#  my $d = new Games::Rezrov::ZObject($destination_obj, $self);
  my $d = $self->get_zobject($destination_obj);

  if (my $po = $self->player_object()) {
    # already know the object ID for the player
    if ($po == $object) {
      $self->current_room($destination_obj);
    }
    if (my $tail_id = $self->tailing()) {
      # we're tailing an object...
      if ($tail_id == $object) {
	$self->newline();
	$self->write_text(sprintf "Tailing %s: you are now in %s...", ${$o->print}, ${$d->print});
	$self->newline();
	$self->insert_obj($po, $destination_obj);
#        $self->suppress_hack();
#        $self->push_command("look");
      }
    }
  } else {
    # record first object moved; sometimes but not always the player
    # object, aka "cretin"  :)
    my $desc = $o->print($self->ztext());
    if ($$desc eq "Tip" or $$desc eq "stool") {
      # hack exceptions: "Tip" Seastalker, and "stool" for LGOP...
#      print STDERR "Gilligan!\n";
    } else {
      $self->player_object($object);
      $self->first_room($destination_obj);
      $self->current_room($destination_obj);
    }
  }

  if (Games::Rezrov::ZOptions::SNOOP_OBJECTS()) {
    my $zt = $self->ztext();
    my $o1 = $o->print($zt);
    my $o2 = $d ? $d->print($zt) : "(null)";
    $self->write_text(sprintf '[Move "%s" to "%s"]', $$o1, $$o2);
    $self->newline();
  }
  
  $o->remove();
  # unlink o from its parent and siblings
  
  $o->set_parent_id($destination_obj);
  # set new o's parent to d
  
  if ($d) {
    # look out for destination of object 0
    my $old_child_id = $d->get_child_id();
  
    $d->set_child_id($object);
    # set d's child ID to o
  
    if ($old_child_id > 0) {
      # d had children; make them the new siblings of o,
      # which is now d's child.
      $o->set_sibling_id($old_child_id);
    }
  }
  
}

sub routine_push {
  # push a value onto the routine stack
  # args: value
  $current_frame->routine_push($_[1]);
}

sub routine_pop {
  # pop a value from the routine stack and store in specified variable.
  my ($self, $variable) = @_;
  $self->set_variable($variable, $current_frame->routine_pop());
}

sub jin {
  # jump if parent of obj1 is obj2
  # or if obj2 is 0 (null) and obj1 has no parent.
  my ($self, $obj1, $obj2) = @_;
#  my $x = new Games::Rezrov::ZObject($obj1, $self);
  if ($obj1 == 0) {
    # no such object; consider its parent zero as well
    $self->conditional_jump($obj2 == 0 ? 1 : 0);
  } else {
    my $x = $self->get_zobject($obj1);
    my $jump = 0;
    if ($obj2 == 0) {
      $jump = ($x->get_parent_id() == 0 ? 1 : 0);
      $self->write_text("[ jin(): untested! ]");
      $self->newline();
    } else {
      $jump = $x->get_parent_id() == $obj2  ? 1 : 0;
    }
    $self->conditional_jump($jump);
  }
}

sub print_object {
  my ($self, $object) = @_;
  # print short name of object (Z-encoded string in object property header)
  my $zobj = $self->get_zobject($object);
  my $highlight = Games::Rezrov::ZOptions::HIGHLIGHT_OBJECTS();
  $self->set_text_style(Games::Rezrov::ZConst::STYLE_BOLD) if $highlight;
  $self->write_zchunk($zobj->print($self->ztext()));
  $self->set_text_style(Games::Rezrov::ZConst::STYLE_ROMAN) if $highlight;
}

sub get_parent {
  # get parent object of this object and store result.
  # arg: object
  my $zobj = $_[0]->get_zobject($_[1]);
  $_[0]->store_result($zobj ? $zobj->get_parent_id() : 0);
  # if object ID 0, will be undef
}

sub get_child {
  # get child object ID for this object ID and store result, then
  # jump if it exists.
  #
  # arg: object
  my $zobj = $_[0]->get_zobject($_[1]);
  my $id = $zobj ? $zobj->get_child_id() : 0;
  # if object ID 0, will be undef
  $_[0]->store_result($id);
  $_[0]->conditional_jump($id != 0);
}

sub get_sibling {
  # get sibling object ID for this object ID and store result, then
  # jump if it exists.
  #
  # arg: object
  my $zobj = $_[0]->get_zobject($_[1]);
  my $id = $zobj ? $zobj->get_sibling_id() : 0;
  # if object ID 0, will be undef
  $_[0]->store_result($id);
  $_[0]->conditional_jump($id != 0);
}

sub get_property {
  # retrieve the specified property of the specified object
  my ($self, $object, $property) = @_;

  if (my $zobj = $self->get_zobject($object)) {
    my $zprop = $zobj->get_property($property);
    $self->store_result($zprop->get_value());
  } else {
    # object 0
    $self->store_result(0);
  }
}

sub ret_popped {
  # return with a variable popped from the routine stack.
  $_[0]->ret($current_frame->routine_pop());
}

sub stack_pop {
  # pop topmost variable from the stack
  $current_frame->routine_pop();
}

sub read_line {
  my ($self, $argv, $interpreter, $start_pc) = @_;
  # Read and tokenize a command.
  # multi-arg approach taken from zip; this call has many
  # possible arguments.

  my $text_address = $argv->[0];
  my $token_address = $argv->[1] || 0;
  my $time = 0;
  my $routine = 0;
  
  my $max_text_length = $self->get_byte_at($text_address);
  my $z_version = $self->version();
  $max_text_length++ if ($z_version <= 4);
  # sect15.html#sread
  
  if (@{$argv} > 2) {
    # timeout / routine specified
    $time = $argv->[2];
    $routine = $argv->[3];
  }
  
  $self->flush();
  # flush any buffered output before the prompt.
  # Also very important before hijacking/restoring ZIO when guessing
  # the title.

  $self->reset_write_count();

  my $bef_pc = $Games::Rezrov::PC;
  my $s = "";

  my $guess_title = Games::Rezrov::ZOptions::GUESS_TITLE();
  
  if ($self->is_stream_selected(Games::Rezrov::ZConst::STREAM_STEAL)) {
    # suppressing parser output up until the next prompt
    my $old = $self->zios()->[Games::Rezrov::ZConst::STREAM_STEAL];
    $self->output_stream(- Games::Rezrov::ZConst::STREAM_STEAL);
    my $suppressed = $old->buffer();
#    print STDERR "steal active: $suppressed\n";
    if ($self->push_command()) {
      $s = $self->push_command();
#      print STDERR "pushing: $s\n";
      $self->push_command("");

    } else {
      if ($self->guessing_title()) {
	$self->full_version_output($suppressed);
	$suppressed =~ /\s*(.*?)[\x0a\x0d]/;
	$self->screen_zio()->set_game_title($self->game_title("rezrov: " . $1));
      }
      my $regexp = '.*' . chr(Games::Rezrov::ZConst::Z_NEWLINE);
      # delete everything before the prompt (everything up to last newline)
      $suppressed =~ s/$regexp//o;
      $self->last_prompt($suppressed);
      $self->prompt_buffer($suppressed);
      # because flush() never sees the output this came from
      
      if ($self->guessing_title()) {
	# prompt was printed "last time", don't print again
	$self->guessing_title(0);
      } else {
	# print the prompt
	$self->screen_zio()->write_string($suppressed);
      }
    }
  } elsif ($guess_title) {
    #
    # The axe crashes against the rock, throwing sparks!
    #
    if (!$self->game_title() and $self->player_object()) {
      # delay submitting the "version" command until an object has been
      # moved; this necessary for game that read a line before the real
      # parser starts.  Example: Leather Goddesses of Phobos.
      # Doesn't work: AMFV
      if ($self->zdict()->get_dictionary_address("version")) {
	$self->guessing_title(1);
	$s = "version";
	# submit a surreptitious "version" command to the interpreter
	$self->suppress_hack();
	# temporarily hijack output
      } else {
	# game doesn't understand "version"; forget it.
	# example: Advent.z5
	$self->game_title("not gonna happen");
	$self->screen_zio()->set_game_title("rezrov");
      }
    }
  }

  my $undo_data;
  if (Games::Rezrov::ZOptions::EMULATE_UNDO()) {
    # save undo information
    my $tmp_pc = $Games::Rezrov::PC;
    $Games::Rezrov::PC = $start_pc;
    # fix me: move to quetzal itself
    $undo_data = $self->quetzal()->save("", "-undo" => 1);
    $Games::Rezrov::PC = $tmp_pc;
  }

  unless (length $s) {
    if ($self->current_input_stream() == Games::Rezrov::ZConst::INPUT_FILE) {
      #
      #  we're fetching commands from a script file.
      #
      my $fh = $self->input_filehandle();
      $s = <$fh>;
      if (defined($s)) {
	# got a command; display it
	chomp $s;
	$self->write_text($s || "");
	$self->newline();
      } else {
	# end of file
	$self->input_stream(Games::Rezrov::ZConst::INPUT_KEYBOARD);
	$s = "";
      }
    }

    unless (length $s) {
      # 
      #  Get commands from the user
      #
      my $initial_buf;
      if ($z_version <= 3) {
	$self->display_status_line();
      } elsif ($z_version >= 5) {
	# sect15.html#read
	# there may be some text already displayed as if we had typed it
	my $initial = $self->get_byte_at($text_address + 1);
	$initial_buf = $self->get_string_at($text_address + 2, $initial)
	  if $initial;
      }
      
      $s = $self->screen_zio()->get_input($max_text_length, 0,
					"-time" => $time,
					"-routine" => $routine,
					"-zi" => $interpreter,
					"-preloaded" => $initial_buf,
					);
    }
  }
#  printf STDERR "cmd: $s\n";

  if (Games::Rezrov::ZOptions::EMULATE_UNDO()) {
    my $slots = $self->undo_slots();
    if ($s eq "undo") {
      # want to undo; restore the old data
      if (@{$slots}) {
	$self->quetzal()->restore("", pop @{$slots});
	$self->write_text("Undone");
	if (@{$slots}) {
	  $self->write_text(sprintf " (%d more turn%s may be undone)", scalar @{$slots}, (scalar @{$slots} == 1 ? "" : "s"));
	}
	$self->write_text(".");
	$self->newline();
	$self->newline();
	$self->write_text($self->last_prompt() || ">");
	# hack! 
	return;
      } else {
	$self->write_text("Can't undo now, sorry.");
	$self->newline();
	$self->newline();
	$self->suppress_hack();
      }
    } else {
      # save this undo slot
      push @{$slots}, $undo_data;
      while (@{$slots} > Games::Rezrov::ZOptions::UNDO_SLOTS()) {
	shift @{$slots};
      }
    }
  }

  die("PC corrupt after get_input; was:$bef_pc now:" . $Games::Rezrov::PC)
    if ($Games::Rezrov::PC != $bef_pc);
  # interrupt routine sanity check


  $self->stream_dup(Games::Rezrov::ZConst::STREAM_TRANSCRIPT, $s);
  $self->stream_dup(Games::Rezrov::ZConst::STREAM_COMMANDS, $s);

#  printf STDERR "input: %s\n", $s;
  $s = substr($s, 0, $max_text_length);
  # truncate input if necessary

  my $zdict = $self->zdict();
  $zdict->save_buffer($s, $text_address);
  
  if ($z_version >= 5 && $token_address == 0) {
#    print STDERR "Skipping tokenization; test this!\n";
  } else {
    $zdict->tokenize_line($text_address, $token_address, length($s), 0);
  }

#  $zdict->last_buffer($s);
#  last_input = s;
  $self->store_result(10) if ($z_version >= 5);
  # sect15.html#sread; store terminating char ("newline")

  $self->last_input($s);
  # save last user input; used in "oops" emulation
}

sub read_char {
  my ($self, $argv, $zi) = @_;
  # read a single character
  $self->flush();
#  die("read_char: 1st arg must be 1") if ($argv->[0] != 1);
  my $time = 0;
  my $routine = 0;
  if (@{$argv} > 1) {
    $time = $argv->[1];
    $routine = $argv->[2];
  }
  my $result = $self->screen_zio()->get_input(1, 1,
					    "-time" => $time,
					    "-routine" => $routine,
					    "-zi" => $zi);
  my $code = ord(substr($result,0,1));
  $code = Games::Rezrov::ZConst::Z_NEWLINE if ($code == LINEFEED);
  # remap keyboard "linefeed" to what the Z-machine
  # will recognize as a "carriage return".  This is required
  # for the startup form in "Bureaucracy", and probably other
  # places.
  #
  # - does keyboard ever return 13 (non-IBM-clones)?
  # 
  # In spec terms:
  # - 10.7: only return characters defined in input stream
  # - 3.8: character "10" (linefeed) only defined for output.
  $self->store_result($code);
  #  store ascii value
}


sub display_status_line {
  # only called if needed; see spec 8.2
  my $zstatus = $_[0]->zstatus();
  my $zio = $_[0]->screen_zio();
  return unless $zio->can_split();
  $zstatus->update();

  if ($zio->manual_status_line()) {
    # the ZIO wants to handle it
    $zio->status_hook($zstatus);
  } else {
    # "generic" status line handling; broken for screen-splitting v3 games
    my $restore = $zio->get_position(1);
    $zio->status_hook(0);
    my $columns = $_[0]->columns();
    $zio->write_string((" " x $columns), 0, 0);
    # erase
    $zio->write_string($zstatus->location(), 0, 0);
    
    if ($zstatus->time_game()) {
      my $hours = $zstatus->hours();
      my $minutes = $zstatus->minutes();
      my $style = $hours < 12 ? "AM" : "PM";
      $zio->write_string(sprintf("Time: %d:%02d%s",
				 ($hours > 12 ? $hours - 12 : $hours),
				 $minutes, $style),
			 $columns - 14, 0);
    } else {
      my $score = $zstatus->score();
      my $moves = $zstatus->moves();
      my $buf = length($score) + length($moves);
      $zio->write_string("Score:" . $score . "  Moves:" . $moves,
			 $columns - $buf - 14, 0);
    }
    $zio->status_hook(1);
    &$restore();
  }
}

sub print_paddr {
  # print the string at the packed address given.
  # arg: address
  $_[0]->write_zchunk($_[0]->ztext()->decode_text($_[0]->convert_packed_address($_[1])));
}

sub print_addr {
  # print the string at the address given; address is not packed
  # example: hollywood hijinx: "n", "knock"
  $_[0]->write_zchunk($_[0]->ztext()->decode_text($_[1]));
}

sub random {
  my ($self, $value) = @_;
  # return a random number between 1 and specified number.
  # With arg 0, seed random number generator, return 0
  # With arg < 0, seed with that value, return 0
  my $result = 0;
  if ($value == 0) {
    # seed the random number generator
    srand();
  } elsif ($value < 0) {
    # use specified value as a seed
    $self->write_text("Specific seed used, test me!");
    $self->newline();
    srand($value);
  } else {
    $result = int(rand($value)) + 1;
  }
  $self->store_result($result);
}

sub remove_object {
  # remove an object from its parent
  my ($self, $object) = @_;
  if (my $zobj = $self->get_zobject($object)) {
    # beware object 0
    $zobj->remove();
    if (my $tail_id = $self->tailing()) {
      if ($tail_id == $zobj->object_id()) {
	$self->write_text(sprintf "You can no longer tail %s.", ${$zobj->print});
      $self->newline();
      $self->tailing("");
      }
    }
  }
}

sub get_property_addr {
  my ($self, $object, $property) = @_;
  # store data address for given property of given object.
  # If property doesn't exist, store zero.
  if (my $zobj = $self->get_zobject($object)) {
    my $zprop = $zobj->get_property($property);
    if ($zprop->property_exists()) {
      my $addr = $zprop->get_data_address();
#      printf STDERR "get_prop_addr for %s/%s=%s\n", $object, $property, $addr;
      $self->store_result($addr);
    } else {
      $self->store_result(0);
    }
  } else {
    # object 0
    $self->store_result(0);
  }
}

sub test_flags {
  # jump if all flags in bitmap are set
  my ($self, $bitmap, $flags) = @_;
  $self->conditional_jump(($bitmap & $flags) == $flags);
}

sub get_property_length {
  # given the literal address of a property data block,
  # find and store size of the property data (number of bytes).
  # example usage: "inventory" cmd
  my ($self, $address) = @_;
  $self->store_result(Games::Rezrov::ZProperty::get_property_length($address,
							     $self,
							     $self->version()));
}

sub verify {
  # verify game image
  # sect15.html#verify
  my $self = shift;
  my $header = $self->header();
  my $stat = $header->static_memory_address();
  my $flen = $header->file_length();
  my $sum = 0;
  for (my $i = 0x40; $i < $flen; $i++) {
    $sum += ($i < $stat) ? $self->save_area_byte($i) : $self->get_byte_at($i);
  }
  $sum = $sum % 0x10000;
  $self->conditional_jump($sum == $header->file_checksum());
}

sub get_next_property {
  my ($self, $object, $property) = @_;
  # return property number of the next property provided by
  # the given object's given property.  With argument 0,
  # load property number of first property provided by that object.
  # example: zork 2 start, "get all"

  my $zobj = $self->get_zobject($object);

  my $result = 0;
  if ($zobj) {
    # look out for object 0
    if ($property == 0) {
      # sect15.html#get_next_prop: 
      # if called with zero, it gives the first property number present.
      my $zp = $zobj->get_property(Games::Rezrov::ZProperty::FIRST_PROPERTY);
      $result = $zp->property_number();
    } else {
      my $zp = $zobj->get_property($property);
      if ($zp->property_exists()) {
	my $next = $zp->get_next();
	$result = $next->property_number();
      } else {
	die("attempt to get next after bogus property");
      }
    }
  }
  $self->store_result($result);
}

sub scan_table {
  my ($self, $argv) = @_;
  my ($search, $table, $num_entries, $form) = @{$argv};
  # args: search, table, len [form]
  # Is "search" one of the entries in "table", which is "num_entries" entries
  # long?  So return the address where it first occurs and branch.  If not,
  # return 0 and don't.  May be byte/word entries.
  my ($entry_len, $check_len);
  if (defined $form) {
#    $self->write_text("[custom form, check me!]");
#    $self->newline();
    
    $entry_len = $form & 0x7f;
    # length of each entry in the table
    $check_len = ($form & 0x80) > 0 ? 2 : 1;
    # how many of the first bytes in each entry to check
  } else {
    $check_len = $entry_len = 2;
  }
  my ($addr, $value, $entry_count);
  my $found = 0;
  for ($addr = $table, $entry_count = 0;
       $entry_count < $num_entries;
       $entry_count++, $addr += $entry_len) {
    $value = ($check_len == 1) ?
      $self->get_byte_at($addr) : $self->get_word_at($addr);
    # yeah, yeah, it'd be more efficient to have a separate
    # loop, one for byte and one for word...
    $found = 1, last if ($value == $search);
  }
  
  $self->store_result($found ? $addr : 0);
  $self->conditional_jump($found);
}

sub set_window {
  my ($self, $window) = @_;
#  print STDERR "set_window $window\n";
  $self->flush();
  my $zio = $self->screen_zio();

  my ($x, $y) = $zio->get_position();
  my $cursor = $self->window_cursors();
  $cursor->[$current_window] = [ $x, $y ];
  # save cursor position before leaving old window
  
  $current_window = $window;
  # set current window

  my $z_version = $self->version();
  if ($z_version >= 4) {
    if ($current_window == Games::Rezrov::ZConst::UPPER_WIN) {
      # 8.7.2: whenever upper window selected, cursor goes to top left
      $self->set_cursor(1,1);
    } else {
      # restore old cursor position
      my $rows = $self->rows();
      ($x, $y) = defined($cursor->[$current_window]) ?
	@{$cursor->[$current_window]} : (0, $rows - 1);
      $y = $rows - 1 if $z_version == 4;
      # 8.7.2.2: in v4 lower window cursor is always on last line
      $zio->absolute_move($x, $y);
#      print STDERR "restoring x=$x y=$y for $current_window\n";
    }
  } else {
    # in v3, cursor always in lower left
    $zio->absolute_move(0, $self->rows() - 1);
  }
  $zio->set_window($window);
  # for any local housekeeping
  $zio->set_text_style($self->font_mask());
  # since we always print in fixed font in the upper window,
  # make sure the zio gets a chance to turn this on/off as we enter/leave;
  # example: photopia.
}

sub set_cursor {
  my ($self, $line, $column, $win) = @_;
  my $zio = $self->screen_zio();
  $zio->fatal_error("set_cursor on $win not supported") if $win;

  $line--;
  $column--;
  # given starting at 1, not 0
  
#  print STDERR "set_cursor\n";
  if ($current_window == Games::Rezrov::ZConst::UPPER_WIN) {
    # upper window: use offsets as specified
    $zio->absolute_move($column, $line);
  } else {
    # lower window: map coordinates given upper window size
    $zio->absolute_move($column, $line + $upper_lines);
  }
}

sub write_zchar {
  #
  # write a decoded z-char to selected output streams.
  #
#  cluck "wz: %d(%s)\n", $_[1], chr($_[1]);
  my $selected = $_[0]->selected_streams();
  my $zios = $_[0]->zios();
  if ($selected->[Games::Rezrov::ZConst::STREAM_REDIRECT]) {
    #
    # 7.1.2.2: when active, no other streams get output
    #
    my $stack = $zios->[Games::Rezrov::ZConst::STREAM_REDIRECT];
    $stack->[$#$stack]->write_zchar($_[1]);
  } else {
    #
    #  all the other streams
    #
    if ($selected->[Games::Rezrov::ZConst::STREAM_SCREEN]) {
      #
      #  screen
      #
      if ($selected->[Games::Rezrov::ZConst::STREAM_SCREEN]) {
	if ($selected->[Games::Rezrov::ZConst::STREAM_STEAL] and
	    $current_window == Games::Rezrov::ZConst::LOWER_WIN) {
	  # temporarily steal lower window output
	  $zios->[Games::Rezrov::ZConst::STREAM_STEAL]->buffer_zchar($_[1]);
	} else {
	  my $zio = $zios->[Games::Rezrov::ZConst::STREAM_SCREEN];
	  
	  if ($buffering and $current_window != Games::Rezrov::ZConst::UPPER_WIN) {
	    # 8.7.2.5: buffering never active in upper window (v. 3-5)
	    if ($_[1] == Games::Rezrov::ZConst::Z_NEWLINE) {
	      $_[0]->flush();
	      $_[0]->prompt_buffer("");
	      $zio->newline();
	    } else {
	      $zio->buffer_zchar($_[1]);
	    }
	  } else {
	    # buffering off, or upper window
	    if ($_[1] == Games::Rezrov::ZConst::Z_NEWLINE) {
	      $_[0]->prompt_buffer("");
	      $zio->newline();
	    } else {
	      $zio->write_zchar($_[1]);
	    }
	  }
	}
      }
    }

    if ($selected->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT] and
	$current_window == Games::Rezrov::ZConst::LOWER_WIN) {
      # 
      #  Game transcript
      #
      my $fh = $zios->[Games::Rezrov::ZConst::STREAM_TRANSCRIPT];
      print $fh ($_[1] == Games::Rezrov::ZConst::Z_NEWLINE ? $/ : chr($_[1]));
    }
  }
}

sub screen_zio {
  # get the ZIO for the screen
  return $_[0]->zios()->[Games::Rezrov::ZConst::STREAM_SCREEN];
}

sub restore {
  # restore game
  my ($self) = @_;
  my $last = $self->last_savefile();
  my $filename = $self->filename_prompt("-default" => $last || "",
					"-ext" => "sav",
				       );
  my $success = 0;
  if ($filename) {
    my $q = $self->quetzal();
    $self->last_savefile($filename);
    $success = $q->restore($filename);
    if (!$success and $q->error_message()) {
      $self->write_text($q->error_message());
      $self->newline();
    }
  }
  my $z_version = $self->version();
  if ($z_version <= 3) {
    $self->conditional_jump($success);
  } elsif ($z_version == 4) {
    # sect15.html#save
    $self->store_result($success ? 2 : 0);
  } else {
    $self->store_result($success);
  }
}

sub filename_prompt {
#  my ($self, $prompt, $exist_check, $snide) = @_;
  my ($self, %options) = @_;
  
  my $ext = $options{"-ext"} || die;
  my $default;
  unless ($default = $options{"-default"}) {
    $default = $self->filename();
    $default =~ s/\..*//;
    $default .= ".$ext";
  }

  my $zio = $self->screen_zio();
  $zio->write_string(sprintf "Filename [%s]: ", $default);
  my $filename = $zio->get_input(30, 0) || $default;
  if ($filename) {
    if ($options{"-check"} and -f $filename) {
      $zio->write_string($filename . " exists, overwrite? [y/n]: ");
      my $proceed = $zio->get_input(1, 1);
      if ($proceed =~ /y/i) {
	$self->write_text("Yes.");
	unlink($filename);
      } else {
	$self->write_text("No.");
	$filename = "";
      }
      $self->newline();
    }
  }
  
  return $filename;
}

sub save {
  # save game
  my ($self) = @_;
  my $filename = $self->filename_prompt("-ext" => "sav",
					"-check" => 1);
  my $success = 0;
  if ($filename) {
    $self->last_savefile($filename, 0, 1);
    my $q = $self->quetzal();
#    $success = $q->save($filename, "-umem" => 1);
    $success = $q->save($filename);
    if (!$success and $q->error_message()) {
      $self->write_text($q->error_message());
      $self->newline();
    }
  }

  my $z_version = $self->version();
  if ($z_version <= 3) {
    $self->conditional_jump($success);
  } else {
    # v4 +
    $self->store_result($success);
  }
}

sub set_game_state {
  # called from Quetzal restore routines
  my ($self, $stack, $pc) = @_;
  $self->call_stack($stack);
  $self->set_current_frame();
  $Games::Rezrov::PC = $pc;
}

sub notify_toggle {
  # "notify" emulation: user is toggling state.
  my ($self) = @_;
  my $now = Games::Rezrov::ZOptions::notifying();
  my $status = $now ? 0 : 1;
  $self->write_text(sprintf "Score notification is now %s.", $status ? "on" : "off");
  $self->newline();
  $self->newline();
  $self->suppress_hack();
  Games::Rezrov::ZOptions::notifying($status);
}

sub snide_message {
  my @messages = ("Fine, be that way.",
		  "Eh? Speak up!",
		  "What?",
		 );
  return $messages[int(rand(scalar @messages))];
}

sub save_undo {
  # v5+, save to RAM
  if (0) {
    # BROKEN
    my $undo_data = $_[0]->quetzal()->save("", "-undo" => 1);
    $_[0]->undo_slots([ $undo_data ]);
    $_[0]->store_result(1);
  } else {
    $_[0]->store_result(-1);
  }
}

sub restore_undo {
  # v5+, restore from RAM
  if (0) {
    # BROKEN
    my $slots = $_[0]->undo_slots();
    my $status = @{$slots} ? $_[0]->quetzal()->restore("", pop @{$slots}) : 0;
    $_[0]->store_result($status);
  } else {
    $_[0]->store_result(0);
  }
}

sub check_arg_count {
  # sect15.html#check_arg_count
  # branch if the given argument number has been provided by the routine
  # call to the current routine
  $_[0]->conditional_jump($current_frame->arg_count() >= $_[1]);
}

sub DESTROY {
  # must be defined so our AUTOLOAD won't catch destructor and complain
  1;
}

sub copy_table {
  # sect15.html#copy_table
  my ($self, $first, $second, $size) = @_;
  $size = signed_byte($size);
  my $len = abs($size);
  my $i;
  if ($second == 0) {
    # zero out all bytes in first table
    for ($i = 0; $i < $len; $i++) {
      $self->set_byte_at($first + $i, 0);
    }
  } elsif ($size < 0) {
    # we *must* copy forwards
#    $self->write_text("[copy_table: untested!!!]");
    for ($i = 0; $i < $len; $i++) {
      $self->set_byte_at($second + $i, $self->get_byte_at($first + $i));
    }    
  } else {
    # copy first into second; since they might overlap, save off first
    my @buf;
    for ($i = 0; $i < $len; $i++) {
      $buf[$i] = $self->get_byte_at($first + $i);
    }
    for ($i = 0; $i < $len; $i++) {
      $self->set_byte_at($second + $i, $buf[$i]);
    }
  }
}

sub suppress_hack {
  # used when we're pulling a fast one with the parser,
  # intercepting user input.  Suppress the game's output (usually
  # complaints about unknown vocabulary), restoring i/o and
  # printing the prompt (which is everything after the last
  # Games::Rezrov::ZConst::Z_NEWLINE) during the read_line() opcode.
#  cluck "suppress_hack\n";
  $_[0]->output_stream(Games::Rezrov::ZConst::STREAM_STEAL);
}

sub print_table {
  # print a "window" of text onscreen.  Given text and width,
  # decode characters, moving down a line every "width" characters
  # to the same column (x position) where the table started.
  my ($self, $text, $width, $height, $skip) = @_;
  $height = 1 unless defined $height;
  $skip = 0 unless defined $skip;
  $self->write_text("print_table: untested; $text $width $height $skip")
    if ($height > 1 or $skip > 0);
  my $zio = $self->screen_zio();
  my ($i, $j);
  my ($x, $y) = $zio->get_position();
  for (my $i=0; $i < $height; $i++) {
    for(my $j=0; $j < $width; $j++) {
      $zio->write_zchar($self->get_byte_at($text++));
    }
    $text += $skip;
    # optionally skip specified number of chars between lines
    $zio->absolute_move(++$y, $x) if ($height > 1);
    # fix me: what if this goes out of bounds of the current window?
  }
}

sub set_font {
  $_[0]->store_result($_[0]->screen_zio()->set_font($_[1]));
}

sub set_color {
  my ($self, $fg, $bg, $win) = @_;
  die sprintf("v6; fix me! %s", join ",", @_) if defined $win;
  my $zio = $self->screen_zio();
  $self->flush();
  foreach ([ $fg, 'fg' ],
	   [ $bg, 'bg' ]) {
    my ($color_code, $method) = @{$_};
    if ($color_code == Games::Rezrov::ZConst::COLOR_CURRENT) {
      # nop?
      print STDERR "set color to current; huh?\n";
    } elsif ($color_code == Games::Rezrov::ZConst::COLOR_DEFAULT) {
      my $m2 = 'default_' . $method;
      $zio->$method($zio->$m2());
    } elsif (my $name = Games::Rezrov::ZConst::color_code_to_name($color_code)) {
      $zio->$method($name);
      #      printf STDERR "set %s to %s\n", $method, $name;
    } else {
      die "set_color(): eek, " . $color_code;
    }
  }
  $zio->color_change_notify();
}

sub fatal_error {
  my $zio = $_[0]->screen_zio();
  $zio->newline();
  $zio->fatal_error($_[1]);
}

sub split_window {
  my ($self, $lines) = @_;
  my $zio = $self->screen_zio();

  my $rows = $self->rows();
  $upper_lines = $lines;
  $lower_lines = $rows - $lines;
#  print STDERR "ll=$lower_lines ul=$upper_lines\n";
#  cluck "split_window to $lines\n";

  my ($x, $y) = $zio->get_position();
  if ($y <= $upper_lines) {
    # 8.7.2.2
    $zio->absolute_move($x, $upper_lines + 1);
  }
  $self->screen_zio()->split_window($lines);
  # any local housekeeping
}

sub play_sound_effect {
  # hmm, should we pass this through?
  my $self = shift;
  $self->screen_zio()->play_sound_effect(@_);
}

sub input_stream {
  my ($self, $stream, $filename) = @_;
  # $filename is an extension (only used internally)
  $self->current_input_stream($stream);
  if ($stream == Games::Rezrov::ZConst::INPUT_FILE) {
    my $fn = $filename || $self->filename_prompt("-ext" => "cmd");
    # filename provided if playing back from command line
    my $ok = 0;
    if ($fn) {
      if (open(TRANS_IN, $fn)) {
	$ok = 1;
	$self->input_filehandle(\*TRANS_IN);
	$self->write_text("Playing back commands from $fn...") unless defined $filename;
	# if name provided, don't print this message
      } else {
	$self->write_text("Can't open \"$fn\" for playback: $!");
      }
      $self->newline();
    }
    $self->current_input_stream(Games::Rezrov::ZConst::INPUT_KEYBOARD) unless $ok;
  } elsif ($stream eq Games::Rezrov::ZConst::INPUT_KEYBOARD) {
    close TRANS_IN;
  } else {
    die;
  }
}

sub set_buffering {
  # whether text buffering is active
  $buffering = $_[1] == 1;
}

sub font_mask {
  $_[0]->[$FM_INDEX] = $_[1] if defined $_[1];
  my $fm = $_[0]->[$FM_INDEX] || 0;
  $fm |= Games::Rezrov::ZConst::STYLE_FIXED
    if $current_window == Games::Rezrov::ZConst::UPPER_WIN;
  # 8.7.2.4:
  # An interpreter should use a fixed-pitch font when printing on the
  # upper window. 
  return $fm;
}

sub set_text_style {
  my ($self, $text_style) = @_;
  $self->flush();
  my $mask = $self->font_mask();
  if ($text_style == Games::Rezrov::ZConst::STYLE_ROMAN) {
    # turn off all
    $mask = 0;
  } else {
    $mask |= $text_style;
  }
  $mask = $self->font_mask($mask);
  # might be modified for upper window
  
  $self->screen_zio()->set_text_style($mask);
}

sub register_newline {
  # called by the ZIO whenever a newline is printed.
  return unless ($_[0]->wrote_something() and
		 # don't count newlines that occur before any text; 
		 # example: start of "plundered hearts", after initial RETURN
		 defined($current_window) and
		 $lower_lines and
		 $current_window == Games::Rezrov::ZConst::LOWER_WIN);
  my $wrote = $_[0]->lines_wrote() + 1;

#  printf STDERR "rn: %d/%d\n", $wrote, $lower_lines;
  
  if ($wrote >= ($lower_lines - 1)) {
    # need to pause; show prompt.
#    print STDERR "pausing...\n";
    my $zio = $_[0]->screen_zio();
    my $restore = $zio->get_position(1);
    
    $_[0]->set_cursor($lower_lines, 1);
    my $more_prompt = "[MORE]";
    my $old = $_[0]->font_mask();
    $_[0]->set_text_style(Games::Rezrov::ZConst::STYLE_REVERSE);
    $zio->write_string($more_prompt);
    $_[0]->set_text_style(Games::Rezrov::ZConst::STYLE_ROMAN);
    $_[0]->font_mask($old);
    $zio->update();
    $zio->get_input(1,1);
    $_[0]->set_cursor($lower_lines, 1);
    $zio->clear_to_eol();

#    $zio->erase_line($lower_lines);
#    $zio->erase_line($lower_lines - 1);
    $wrote = 0;
    &$restore();
    # restore old position
  }
  $_[0]->lines_wrote($wrote);
}

sub flush {
  # flush and format the characters buffered by the ZIO
  my ($self) = @_;
  return if $self->flushing();
  # can happen w/combinations of attributes and pausing
#  cluck "flush";
  my $len;
  my $zio = $self->screen_zio();
  my $buffer = $zio->get_buffer();
#  printf STDERR "buffer: ->%s<-\n", $buffer;
  $zio->reset_buffer();
  return unless length $buffer;
#  print "fs\n";
  $self->flushing(1);
  $self->wrote_something(1);
  if (Games::Rezrov::ZOptions::BEAUTIFY_LOCATIONS() and
      $self->version() < 4 and
      likely_location(\$buffer)) {
    $self->set_text_style(Games::Rezrov::ZConst::STYLE_BOLD);
    $zio->write_string($buffer);
    # FIX ME: this might wrap; eg Tk, "Zork III: The Dungeon Master"
    $self->set_text_style(Games::Rezrov::ZConst::STYLE_ROMAN);
  } elsif (length $buffer) {
    $self->wrote_something(1);
    my ($i, $have_left);
#    printf STDERR "buf = \"%s\"; lw=%d\n", $buffer, $self->lines_wrote();
    if ($current_window != Games::Rezrov::ZConst::LOWER_WIN) {
      # buffering in upper window: nonstandard hack in effect.
      # assume we know what we're doing :)
#      print STDERR "hack! \"$buffer\"\n";
      $zio->write_string($buffer);
    } elsif (!$zio->fixed_font_default()) {
      #
      #  Variable font; graphical wrapping
      #
      my ($x, $y) = $zio->get_pixel_position();
      my $total_width = ($zio->get_pixel_geometry())[0];
      my $pixels_left = $total_width - $x;
      my $plen;
      while ($len = length($buffer)) {
	$plen = $zio->string_width($buffer);
	if ($plen < $pixels_left) {
	  # it'll fit; we're done
#	  print STDERR "fits: $buffer\n";
	  $zio->write_string($buffer);
	  last;
	} else {
	  my $wrapped = 0;
	  my $i = int(length($buffer) * ($pixels_left / $plen));
#	  print STDERR "pl=$pixels_left, plen=$plen i=$i\n";
	  while (substr($buffer,$i,1) ne " ") {
	    # move ahead to a word boundary
#	    print STDERR "boundarizing\n";
	    last if ++$i >= $len;
	  }

	  while (1) {
	    $plen = $zio->string_width(substr($buffer,0,$i));
#	    printf STDERR "%s = %s\n", substr($buffer,0,$i), $plen;
	    if ($plen < $pixels_left) {
	      # it'll fit
	      $zio->write_string(substr($buffer,0,$i));
	      $zio->newline();
	      $buffer = substr($buffer, $i + 1);
	      $wrapped = 1;
	      last;
	    } else {
	      # retreat back a word
	      while (--$i >= 0 and substr($buffer,$i,1) ne " ") { }
	      if ($i < 0) {
		die "nothing fits! $buffer $pixels_left";
		last;
	      }
	    }
	  }
	  unless ($wrapped) {
	    # if couldn't wrap at all
	    $zio->newline();
	    die "couldn't fit anything!";
	  }
	  $have_left = $total_width;
	}
      }
    } else {
      #
      # Fixed font; do line/column wrapping
      # 
      my ($x, $y) = $zio->get_position();
      my $columns = $self->columns();
      $have_left = ($columns - $x);
      # Get start column position; we can't be sure we're starting at
      # column 0.  This is an issue when flush() is called when changing
      # attributes.  Example: "bureaucracy" intro paragraphs ("But
      # Happitec is going to be _much_ more fun...")
      while ($len = length($buffer)) {
	if ($len < $have_left) {
	  $zio->write_string($buffer);
	  last;
	} else {
#	  printf STDERR "wrapping: %d, %d, %s x:$x y:$y col:$columns\n", length $buffer, $have_left, $buffer;
	  my $wrapped = 0;
	  for ($i = $have_left - 1; $i > 0; $i--) {
	    if (substr($buffer, $i, 1) eq " ") {
	      $zio->write_string(substr($buffer, 0, $i));
	      $zio->newline();
	      $wrapped = 1;
	      $buffer = substr($buffer, $i + 1);
	      last;
	    }
	  }
	  $zio->newline() unless $wrapped;
	  # if couldn't wrap at all
	  $have_left = $columns;
	}
      }
    }
    $self->prompt_buffer($buffer);
    # FIX ME
  }
  $self->flushing(0);
#  print "fe\n";
}
  
sub likely_location {
  #
  # STATIC: is the given string likely the name of a location?
  #
  # An earlier approach saved the buffer position before and after
  # StoryFile::object_print() opcode, and considered a string a
  # location if and only if the buffer was flushed with only an object
  # string in the buffer.  Unfortunately this doesn't always work:
  #
  #  Suspect: "Ballroom, Near Fireplace", where "Near Fireplace"
  #           is an object, but Ballroom is not.
  #
  #  It's not enough to check for all capitalized words:
  #    Zork 1: "West of House"
  #
  # This approach "uglier" but works more often :)
  my $ref = shift;
  my $len = length $$ref;
  if ($len and $len < 50) {
    # length?
    my $buffer = $$ref;

    return 0 unless $buffer =~ /^[A-Z]/;
    # must start uppercased

    return 0 if $buffer =~ /\W$/;
    # can't end with a non-alphanum:
    # minizork.z3:
    #   >i
    #   You have:   <---------
    #   A leaflet

    unless ($buffer =~ /[a-z]/) {
      # if all uppercase...
      return 0 if $buffer =~ /[^\w ]/;
      # ...be extra strict about non-alphanumeric characters
      #
      # allowed: ENCHANTER
      #          HOLLYWOOD HIJINX
      # but not:
      #          ROBOT, GO NORTH (sampler, Planetfall)
    }

    if ($buffer =~ /\s[a-z]+$/) {
      # Can't end with a lowercase word;
      # Enchanter: "Flathead portrait"
      return 0;
    }

    return 0 if $buffer =~ /\s[a-z]\S{2,}\s+[a-z]\S{2,}/;
    # don't allow more than one "significant" lowercase-starting
    # word in a row.
    #
    # example: graffiti in Planetfall's brig:
    #
    #  There once was a krip, name of Blather  <--
    #  Who told a young ensign named Smather   <-- this is not caught here!
    #  "I'll make you inherit
    #  A trotting demerit                      <--
    #  And ship you off to those stinking fawg-infested tar-pools of Krather".
    #
    # However, we must allow:
    #
    #  Land of the Dead  [Zork I]
    #  Room in a Puzzle  [Zork III]

    if ($buffer =~ /\s([a-z]\S*\s+){3,}/) {
      # in any case, don't allow 3 lowercase-starting words in a row.
      # back to the brig example:
      #
      #  Who told a young ensign named Smather   <-- we get this here
      #      ^^^^^^^^^^^^^^^^^^^^^^^^^
      return 0;
    }
    # ( blech... )

    return $buffer =~ /[^\w\s,:\'\-]/ ? 0 : 1;
    # - commas allowed: Cutthroats, "Your Room, on the bed"
    # - dashes allowed: Zork I, "North-South Passage"
    # - apostrophes allowed: Zork II, "Dragon's Lair"
    # - colons allowed (for game titles): "Zork III: ..."
    # - otherwise, everything except whitespace and alphanums verboten.
  } else {
    return 0;
  }
}

sub tokenize {
  my ($self, $text, $parse, $dictionary, $flag) = @_;
  $self->screen_zio()->fatal_error("tokenize: can't handle!")
    if ($dictionary or $flag);
  my $zdict = $self->zdict();
  $zdict->tokenize_line($text, $parse);
#  die join ",", @_;
}

sub get_zobject {
  if (1) {
    # cache object requests; games seem to run about 5-10% faster,
    # the most gain seen in earlier games
    return $_[0]->object_cache()->get($_[1]);
  } else {
    # create every time; slow overhead
    return new Games::Rezrov::ZObject($_[1], $_[0]);
  }
}

sub rows {
  if (defined $_[1]) {
    $_[0]->[ROWS] = $_[1];
    $_[0]->header()->set_rows($_[1]) if $_[0]->header();
    $_[0]->reset_write_count();
    $lower_lines = $_[1] - $upper_lines if defined $upper_lines;
  }
  return $_[0]->[ROWS];
}

sub columns {
  if (defined $_[1]) {
    $_[0]->[COLUMNS] = $_[1];
    $_[0]->header()->set_columns($_[1]) if $_[0]->header();
  }
  return $_[0]->[COLUMNS];
}

sub reset_write_count {
  $_[0]->lines_wrote(0);
  $_[0]->wrote_something(0);
}

sub get_pc {
  return $Games::Rezrov::PC;
}

sub clear_screen {
  my $zio = $_[0]->screen_zio();
  my $fg = $zio->fg() || "";
  my $bg = $zio->bg() || "";
  my $dbg = $zio->default_bg() || "";
  # FIX ME!

#  printf STDERR "fg=%s/%s bg=%s/%s\n",$fg,$zio->default_fg, $bg, $zio->default_bg;
  if ($bg ne $dbg) {
    # the background color has changed; change the cursor color
    # to the current foreground color so we don't run the risk of it 
    # "disappearing".
    $zio->cc($fg);
  }
  $zio->default_bg($bg);
  $zio->default_fg($fg);
  $zio->clear_screen();
}

sub is_stream_selected {
  return $_[0]->selected_streams->[$_[1]];
}

sub stream_dup {
  my ($self, $stream, $string) = @_;
  if ($self->is_stream_selected($stream)) {
    my $fh = $self->zios()->[$stream];
    print $fh $string . $/;
  }
}

sub is_this_game {
  # do the given release number, serial number, and checksum
  # match those of this game?
  my ($self, $release, $serial, $checksum) = @_;
  my $header = $self->header();
  return ($header->release_number() eq $release and
	  $header->serial_code() == $serial and
	  $header->file_checksum() == $checksum);
}

sub get_global_var {
  # get the specified global variable
  return $_[0]->get_word_at($_[0]->global_variable_address() + ($_[1] * 2));
}

sub set_global_var {
  # set a global variable
  return $_[0]->set_word_at($_[0]->global_variable_address() +
			    ($_[1] * 2),
			    $_[2]);
}


1;
