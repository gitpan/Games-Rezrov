package Games::Rezrov::ZText;
# text decoder

use Carp qw(cluck);
use strict;

use Games::Rezrov::StoryFile;

use constant SPACE => 32;

my @alpha_table = (
		   [ 'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y','z' ],
		   [ 'A','B','C','D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z' ],
		   [ '_','^','0','1','2','3','4','5','6','7','8','9','.',',','!','?','_','#','\'','"','/','\\','-',':','(',')' ]
);

sub new {
  my ($type, $story) = @_;
  my $self = {};
  bless $self, $type;
  $self->story($story);
  return $self;
}

sub story {
  $_[0]->{"story"} = $_[1] if defined $_[1];
  return $_[0]->{"story"};
}

sub decode_text {
  my ($self, $address, $buf_ref) = @_;
  # decode and return text at this address; see spec section 3
  # in list context, returns address after decoding.
  my $buffer = "";
  $buf_ref = \$buffer unless ($buf_ref);
  # $buf_ref supplied if called recursively

  my ($word, $zshift, $zchar);
  my $alphabet = 0;
  my $abbreviation = 0;
  my $two_bit_code = 0;
  my $two_bit_flag = 0;
  # spec 3.4
  my $story = $self->story();
      
  while (1) {
    $word = $story->get_word_at($address);
    $address += 2;
    # spec 3.2
    for ($zshift = 10; $zshift >= 0; $zshift -= 5) {
      # break word into 3 zcharacters of 5 bytes each
      $zchar = ($word >> $zshift) & 0x1f;
      if ($two_bit_flag > 0) {
	# spec 3.4
	if ($two_bit_flag++ == 1) {
	  $two_bit_code = $zchar << 5; # first 5 bits
	} else {
	  $two_bit_code |= $zchar; # last 5
#	  $receiver->write_zchar($two_bit_code);
	  $$buf_ref .= chr($two_bit_code);
	  $two_bit_code = $two_bit_flag = 0;
	  # done
	}
      } elsif ($abbreviation > 0) {
	# synonym/abbreviation; spec 3.3
	my $entry = (32 * ($abbreviation - 1)) + $zchar;
	my $addr = $story->header()->get_abbreviation_addr($entry);
	$self->decode_text($addr, $buf_ref);
	$abbreviation = 0;
      } elsif ($zchar == 0) {
#	$receiver->write_zchar(SPACE);
	$$buf_ref .= " ";
      } elsif ($zchar == 4) {
	# spec 3.2.3: shift character; alphabet 1
	$alphabet = 1;
      } elsif ($zchar == 5) {
	# spec 3.2.3: shift character; alphabet 2
	$alphabet = 2;
      } elsif ($zchar >= 1 && $zchar <= 3) {
	# spec 3.3: next zchar is an abbreviation code
	$abbreviation = $zchar;
      } else {
	# spec 3.5: convert remaining chars from alpha table
	if ($zchar == 0) {
#	  $receiver->write_zchar(SPACE);
	  $$buf_ref .= " ";
	} else {
	  $zchar -= 6;
	  # convert to string index
	  if ($alphabet < 2) {
#	    $receiver->write_zchar(ord $alpha_table[$alphabet]->[$zchar]);
	    $$buf_ref .= $alpha_table[$alphabet]->[$zchar];
#	    die $$buf_ref;
	  } else {
	    # alphabet 2; some special cases (3.5.3)
	    if ($zchar == 0) {
	      $two_bit_flag = 1;
	    } elsif ($zchar == 1) {
#	      $receiver->write_zchar(Games::Rezrov::ZConst::Z_NEWLINE());
	      $$buf_ref .= chr(Games::Rezrov::ZConst::Z_NEWLINE());
	    } else {
#	      $receiver->write_zchar(ord $alpha_table[$alphabet]->[$zchar]);
	      $$buf_ref .= $alpha_table[$alphabet]->[$zchar];
	    }
	  }
	}
	$alphabet = 0;
	# applies to this character only (3.2.3)
      }
      # unset temp flags!
    }
    last if (($word & 0x8000) > 0);
  }
  
  return wantarray ? (\$buffer, $address) : \$buffer;
}


1;
