package Games::Rezrov::ZInterpreter;
# interpret z-code

use strict;

use Games::Rezrov::Inliner;

use constant OP_UNKNOWN => -1;
use constant OP_0OP => 0;
use constant OP_1OP => 1;
use constant OP_2OP => 2;
use constant OP_VAR => 3;
use constant OP_EXT => 4;

use constant CALL_VN2 => 0x1a;
use constant CALL_VS2 => 0x0c;
# var opcodes

my @TYPE_LABELS;
$TYPE_LABELS[OP_0OP] = "0OP";
$TYPE_LABELS[OP_1OP] = "1OP";
$TYPE_LABELS[OP_2OP] = "2OP";
$TYPE_LABELS[OP_VAR] = "VAR";
$TYPE_LABELS[OP_EXT] = "EXT";

#
# lists of opcodes that can be handled generically.  Rather than
# writing a massive & repetitive if/elsif/else, we store the
# straightforward opcodes here, indexed by opcode number; "use data
# instead of code".  There seems to be virtually no difference
# difference in speed using this approach vs if/elsif/else
# (according to DProf).
#
# Still, my kingdom for a switch statement  :P
#
# Of course, if we were *really* interested in speed we'd take the
# "obfuscated opcode" approach that zip 2.0 uses...
#

my @zero_ops;
$zero_ops[0x00] = 'rtrue';
$zero_ops[0x01] = 'rfalse';
$zero_ops[0x02] = 'print_text';
$zero_ops[0x03] = 'print_ret';
$zero_ops[0x05] = 'save';
$zero_ops[0x06] = 'restore';
$zero_ops[0x08] = 'ret_popped';
$zero_ops[0x09] = 'stack_pop';
$zero_ops[0x0b] = 'newline';
$zero_ops[0x0c] = 'display_status_line';
$zero_ops[0x0d] = 'verify';

my @one_ops;
$one_ops[0x00] = 'compare_jz';
$one_ops[0x01] = 'get_sibling';
$one_ops[0x02] = 'get_child';
$one_ops[0x03] = 'get_parent';
$one_ops[0x04] = 'get_property_length';
$one_ops[0x05] = 'increment';
$one_ops[0x06] = 'decrement';
$one_ops[0x07] = 'print_addr';
$one_ops[0x09] = 'remove_object';
$one_ops[0x0a] = 'print_object';
$one_ops[0x0c] = 'jump';
$one_ops[0x0d] = 'print_paddr';
$one_ops[0x0e] = 'load_variable';

my @two_ops;
$two_ops[0x01] = 'compare_je';
$two_ops[0x02] = 'compare_jl';
$two_ops[0x03] = 'compare_jg';
$two_ops[0x04] = 'dec_jl';
$two_ops[0x05] = 'inc_jg';
$two_ops[0x06] = 'jin';
$two_ops[0x07] = 'test_flags';
$two_ops[0x08] = 'bitwise_or';
$two_ops[0x09] = 'bitwise_and';
$two_ops[0x0a] = 'test_attr';
$two_ops[0x0b] = 'set_attr';
$two_ops[0x0c] = 'clear_attr';
$two_ops[0x0d] = 'set_variable';
$two_ops[0x0e] = 'insert_obj';
$two_ops[0x0f] = 'get_word_index';
$two_ops[0x10] = 'loadb';
$two_ops[0x11] = 'get_property';
$two_ops[0x12] = 'get_property_addr';
$two_ops[0x13] = 'get_next_property';
$two_ops[0x14] = 'add';
$two_ops[0x15] = 'subtract';
$two_ops[0x16] = 'multiply';
$two_ops[0x17] = 'divide';
$two_ops[0x18] = 'mod';
$two_ops[0x1b] = 'set_color';

my @var_ops;
$var_ops[0x01] = 'store_word';
$var_ops[0x02] = 'store_byte';
$var_ops[0x03] = 'put_property';
$var_ops[0x05] = 'write_zchar';
$var_ops[0x06] = 'print_num';
$var_ops[0x07] = 'random';
$var_ops[0x08] = 'routine_push';
$var_ops[0x09] = 'routine_pop';
$var_ops[0x0a] = 'split_window';
$var_ops[0x0b] = 'set_window';
$var_ops[0x0d] = 'erase_window';
$var_ops[0x0f] = 'set_cursor';
$var_ops[0x11] = 'set_text_style';
$var_ops[0x12] = 'set_buffering';
$var_ops[0x13] = 'output_stream';
$var_ops[0x14] = 'input_stream';  # example: minizork.z3, "#comm"
$var_ops[0x15] = 'play_sound_effect';
$var_ops[0x1b] = 'tokenize';
$var_ops[0x1d] = 'copy_table';
$var_ops[0x1e] = 'print_table';
$var_ops[0x1f] = 'check_arg_count';

my @ext_ops;
$ext_ops[0x00] = 'save';
$ext_ops[0x01] = 'restore';
$ext_ops[0x02] = 'log_shift';
$ext_ops[0x04] = 'set_font';
$ext_ops[0x09] = 'save_undo';
$ext_ops[0x0a] = 'restore_undo';

my @generic_opcodes;
$generic_opcodes[OP_0OP] = \@zero_ops;
$generic_opcodes[OP_1OP] = \@one_ops;
$generic_opcodes[OP_2OP] = \@two_ops;
$generic_opcodes[OP_VAR] = \@var_ops;
$generic_opcodes[OP_EXT] = \@ext_ops;

my $INLINE_CODE = '

sub interpret {
  #
  # Your sword is glowing with a faint blue glow.
  #
  # >
  #
  my $self = shift;
  my $quit = 0;
  my $story = $self->story();
  my $zio = $self->zio();
  my $z_version = $story->version();
  my ($start_pc, $opcode, $opcode_count);
  my ($op_style, $operand_types, $optype, $i);
  my @operands;
  my @op_counts;
  my $oc;
  my $input_counts = 0;
  my $count_opcodes = Games::Rezrov::ZOptions::COUNT_OPCODES();
  my $write_opcodes = Games::Rezrov::ZOptions::WRITE_OPCODES();

  my $var_ops = 0;
  my $orig_opcode;
  while (! $quit) {
    $start_pc = $Games::Rezrov::PC;
    # for "undo" emulation: the PC before any processing has occurred
    $orig_opcode = $opcode = GET_BYTE();
    $op_style = OP_UNKNOWN;
    $opcode_count++;
    @operands = ();
    if (($opcode & 0x80) == 0) {
      #
      #
      # top bit is zero: opcode is "long" format.
      # Handle these first as they seem to be the most common.
      #
      #
      # spec 4.4.2:
#      @operands = ($story->load_operand(($opcode & 0x40) == 0 ? 1 : 2),
#		   $story->load_operand(($opcode & 0x20) == 0 ? 1 : 2));
      
      @operands = (($opcode & 0x40) == 0 ?
		   GET_BYTE() : $story->get_variable(GET_BYTE()),
		   ($opcode & 0x20) == 0 ?
		   GET_BYTE() : $story->get_variable(GET_BYTE()));
      $opcode &= 0x1f; # last 5 bits
      $op_style = OP_2OP;
    } elsif ($opcode & 0x40) {
      # top 2 bits are both 1: "variable" format opcode.
      # This may actually be a 2OP opcode...
      $op_style = ($opcode & 0x20) == 0 ? OP_2OP : OP_VAR;
      # spec 4.3.3
      $opcode &= 0x1f;
      # Spec section 4.3.3 says operand is in bottom five bits.
      # However, "zip" code uses bottom six bits (0x3f).  This folding
      # together of the 2OP (bit 6 = 0) and VAR (bit 6 = 1) opcode
      # types makes for a more efficient single "switch" statement,
      # but makes it more difficult to match up the code with
      # The Specification.
      $var_ops = 1;
      # load operands later
    } else {
      #
      # highest bit is one, 2nd-highest is zero...
      #
      if ($opcode == 0xbe && $z_version >= 5) {
	# "extended" opcode
	$opcode = GET_BYTE();
	$op_style = OP_EXT;
	$var_ops = 1;
	# load operands below
      } elsif (($opcode & 0x30) == 0x30) {
	# "short" format opcode:
	# bits 4 and 5 are set; "0OP" opcode.
	$op_style = OP_0OP;
	$opcode &= 0x0f;
      } else {
	# "short" format opcode:
	# bits 4 and 5 are NOT set; "1OP" opcode.
	$op_style = OP_1OP;
	# push @operands, $story->load_operand((($opcode & 0x30) >> 4));
	$optype = ($opcode & 0x30) >> 4;
	# 4.2:
	if ($optype == 2) {
	  push @operands, $story->get_variable(GET_BYTE());
	} elsif ($optype == 1) {
	  push @operands, GET_BYTE();
	} elsif ($optype == 0) {
	  push @operands, GET_WORD();
	}
	$opcode &= 0x0f;
      }
    }

    if ($var_ops) {
      # a VAR or EXT opcode with variable argument count.
      # Load the arguments.
      if ($op_style == OP_VAR &&
	  ($opcode == CALL_VS2 || $opcode == CALL_VN2)) {
	# 4.4.3.1: there may be two bytes of operand types, allowing
	# for up to 8 arguments.  This byte will always be present,
	# though it does NOT have to be used...
	$i = 14;
	# start shift mask: target "leftmost" 2 bits
	$operand_types = GET_WORD();
      } else {
	# 4.4.3: one byte of operand types, up to 4 args.
	$i = 6;
	$operand_types = GET_BYTE();
      }
#      printf STDERR "%s: ", $operand_types;
      for (; $i >=0; $i -= 2) {
	$optype = ($operand_types >> $i) & 0x03;
#	print STDERR "$optype ";
#	push @operands, $story->load_operand($optype);
#	last if $optype == 0x03;
	if ($optype == 2) {
	  push @operands, $story->get_variable(GET_BYTE());
	} elsif ($optype == 1) {
	  push @operands, GET_BYTE();
	} elsif ($optype == 0) {
	  push @operands, GET_WORD();
	} else {
	  # 4.4.3: 0x03 means "no more operands"
	  last;
	}
      }
#      print STDERR "\n";
      $var_ops = 0;
    }

    #
    #  Finally, interpret the opcodes based on type.
    #  This is a separate if/then/else from above code because the
    #  VAR opcode type can actually become a 2OP type (spec 4.3.3).
    #  This allows us to share the operand calls without duplicating
    #  code or (further) convoluting the structure of this routine.
    #

    if ($write_opcodes) {
      # FIX ME: speed?
      printf LOG "count:%d pc:%d type:%s opcode:%d(0x%02x;raw=%d) (%s) operands:%s\n",
      $opcode_count,
      $start_pc + 1,
      $TYPE_LABELS[$op_style],
      $opcode,
      $opcode,
      $orig_opcode,
      ($generic_opcodes[$op_style]->[$opcode] || ""),
      join(",", @operands);
    }

    #
    # Opcode types in order of frequency based on a completely 
    # unscientific test of Zorks 1-3 seem to be:
    #    2OP, 1OP, VAR, 0OP
    #
    $op_counts[$op_style]++;
    if (defined $generic_opcodes[$op_style]->[$opcode]) {
      #
      #  Process opcodes 0/1/2/var/ext (old version):  5.43 secs
      #  Add processing opcodes by likely frequency:   4.51 secs
      #  Add intercepting generic opcodes first:       3.75 secs
      #
      #  (about 30% faster)
      #
      $oc = $generic_opcodes[$op_style]->[$opcode];
#      die unless @operands == $op_style;
      $story->$oc(@operands);
      # @operands contains the correct number of operands; just pass them
    } elsif ($op_style == OP_2OP) {
      #
      #  2-operand opcodes (well, mostly)
      #
      if ($opcode == 0x19) {
	$story->call(\@operands, Games::Rezrov::ZFrame::FUNCTION);
	# v4 only
      } elsif ($opcode == 0x1a) {
	$story->call(\@operands, Games::Rezrov::ZFrame::PROCEDURE);
	# v5 only
      } else {
	$self->zi_die($op_style, $opcode, $opcode_count);
      }
    } elsif ($op_style == OP_1OP) {
      #
      # one operand opcodes
      #
      if ($opcode == 0x08) {
	$story->call(\@operands, Games::Rezrov::ZFrame::FUNCTION);
	# v4 only
      } elsif ($opcode == 0x0b) {
	my $result = $story->ret($operands[0]);
#	if ($story->is_interrupt_top()) {
#	  # end of interrupt routine
#	  $story->set_interrupt_top(0);
#	  return $result;
#	}
	# async interpreter call (v4+), not implemented
      } elsif ($opcode == 0x0f) {
	die("bitwise not, FIX ME") if ($z_version < 5);
	$story->call(\@operands, Games::Rezrov::ZFrame::PROCEDURE);
      } else {
	$self->zi_die($op_style, $opcode, $opcode_count);
      }
    } elsif ($op_style == OP_VAR) {
      #
      #  variable-format opcodes
      #
      if ($opcode == 0x00) {
	$story->call(\@operands, Games::Rezrov::ZFrame::FUNCTION);
      } elsif ($opcode == 0x04) {
	$story->read_line(\@operands, $self, $start_pc);
	if ($count_opcodes and
	    (++$input_counts > (Games::Rezrov::ZOptions::GUESS_TITLE() ? 1 : 0))) {
	  my $count = 0;
	  my $desc = "";
	  foreach my $key (OP_0OP, OP_1OP, OP_2OP, OP_VAR, OP_EXT) {
	    my $oc = $op_counts[$key] || 0;
	    $count += $oc;
	    $desc .= sprintf " %s:%d", $TYPE_LABELS[$key], $oc;
	  }
	  $story->write_text(sprintf "[%d opcodes:%s]\n", $count, $desc);
	  @op_counts = ();
	}
      } elsif ($opcode == CALL_VS2) {
	$story->call(\@operands, Games::Rezrov::ZFrame::FUNCTION);
	# call_vs2
      } elsif ($opcode == 0x16) {
	$story->read_char(\@operands, $self);
      } elsif ($opcode == 0x17) {
	$story->scan_table(\@operands);
	# v5+ from here on
      } elsif ($opcode == 0x19) {
	$story->call(\@operands, Games::Rezrov::ZFrame::PROCEDURE);
      } elsif ($opcode == CALL_VN2) {
	$story->call(\@operands, Games::Rezrov::ZFrame::PROCEDURE);
      } else {
	$self->zi_die($op_style, $opcode, $opcode_count);
      }
    } elsif ($op_style == OP_0OP) {
      #
      #  zero-operand opcodes
      #
      if ($opcode == 0x04) {
	1; # NOP opcode
      } elsif ($opcode == 0x07) {
	$self->restart(0);
      } elsif ($opcode == 0x0a) {
	$quit = 1;
      } else {
	$self->zi_die($op_style, $opcode, $opcode_count);
      }
    } elsif ($op_style == OP_EXT) {
      $self->zi_die($op_style, $opcode, $opcode_count);
    } else {
      $self->zi_die($op_style, $opcode, $opcode_count);
    }
  }

  $zio->newline();
  $zio->write_string("*** End of session ***");
  $zio->newline();
  $zio->get_input(1,1);

  $zio->set_game_title(" ") if $story->game_title();
  $zio->cleanup();
  printf "Opcode counts: %s\n", join " ", @op_counts if $count_opcodes;
}
';

Games::Rezrov::Inliner::inline(\$INLINE_CODE);
eval $INLINE_CODE;

sub new {
  my ($type, $story, $zio) = @_;
  my $self = {};
  bless $self, $type;

  $self->zio($zio);
  $self->story($story);

  if (my $where = Games::Rezrov::ZOptions::WRITE_OPCODES()) {
    if ($where eq "STDERR") {
      *Games::Rezrov::ZInterpreter::LOG = \*main::STDERR;
    } else {
      die "Can't write to $where: $!\n"
	unless open(LOG, ">$where");
    }
    my $old = select();
    select LOG;
    $|=1;
    select $old;
  }

  $self->restart(1);
  $self->interpret();
  return $self;
}

sub zio {
  return (defined $_[1] ? $_[0]->{"zio"} = $_[1] : $_[0]->{"zio"});
}

sub story {
  return (defined $_[1] ? $_[0]->{"story"} = $_[1] : $_[0]->{"story"});
}

sub restart {
  my ($self, $first_time) = @_;
  my $story = $self->story();
  $story->reset_storyfile() unless $first_time;
  $story->reset_game();
}

sub zi_die {
  my ($self, $style, $opcode, $count) = @_;
  my $desc = $TYPE_LABELS[$style] || "mystery";
  $self->zio()->fatal_error(sprintf "Unknown/unimplemented %s opcode %d (0x%02x), \#%d", $desc, $opcode, $opcode, $count);

}

1;

