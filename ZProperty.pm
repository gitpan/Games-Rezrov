package Games::Rezrov::ZProperty;
# object properties

use strict;

use constant FIRST_PROPERTY => -1;
# used to find the first property in the object

use Games::Rezrov::Inliner;
use Games::Rezrov::MethodMaker ([],
			 qw(
			    size_byte
			    story
			    search_id
			    pointer
			    property_offset
			    property_exists
			    property_number
			    property_len
			    zobj
			    pre_v4
			   )
			 );

use SelfLoader;

my $INLINE_CODE = '
sub get_property_length {
  my ($address, $story, $version) = @_;
  # STATIC METHOD
  #
  # given the literal address of a property data block,
  # find and store size of the property data (number of bytes).
  # example usage: "inventory" cmd
  my $addr = SIGNED_WORD($address - 1);
  # subtract one because we are given data start location, not 
  # the index location (yuck).  Also account for possible rollover;
  # one example: (1) start sorcerer.  (2) "ne" (3) "frotz me".
  # int rollover crash: 0 becomes -1 instead of 65535.
  my $size_byte = $story->get_byte_at($addr & 0xffff);
  my $result;
  if ($version <= 3) {
    # 12.4.1
    $result = ($size_byte >> 5) + 1;
  } else {
    if (($size_byte & 0x80) > 0) {
      # spec 12.4.2.1: this is the second size byte, length
      # is in bottom 6 bits
      $result = $size_byte & 0x3f;
      if ($result == 0) {
	# 12.4.2.1.1
	print STDERR "wacky inform size; check this\n";
	$result = 64;
      }
    } else {
      # 12.4.2.2
      $result = (($size_byte & 0x40) > 0) ? 2 : 1;
    }
  }
  return $result;
}

';

Games::Rezrov::Inliner::inline(\$INLINE_CODE);
eval $INLINE_CODE;
undef $INLINE_CODE;

1;

__DATA__

sub new {
  my ($type, $search_id, $zobj, $story) = @_;

#  printf STDERR "new zprop %s for obj %s\n", $search_id, $zobj->object_id();

  my $self = [];
  bless $self, $type;

  $self->zobj($zobj);
  $self->pre_v4($story->version() <= 3);
  $self->story($story);
  $self->search_id($search_id);

  $self->size_byte(-1);
  $self->pointer($zobj->property_start_index());
  $self->property_offset(-1);
  $self->property_exists(0);

  my ($this_id, $last_id);
  while ($self->next()) {
    $this_id = $self->property_number();
    if ($last_id and $this_id > $last_id) {
      # 12.4: properties are stored in descending numerical order
      # this means we're past the end
      last;
    } elsif ($search_id > $this_id) {
      # went past where it would have been had it existed
      last;
    }
    $last_id = $this_id;
#    printf STDERR "prop search %s: %d\n", $zobj->object_id, $self->property_number;
    if ($this_id == $search_id || $search_id == FIRST_PROPERTY) {
#      print STDERR "got it\n";
      $self->property_exists(1);
      # 12.4.1
      last;
    }
  }

#  printf "property %d: %d\n", $search_id, $self->property_exists();

  return $self;
}

sub next {
  # move to the next property in the list.
  # Returns property number of the next property (0 if at end)
  # NOTE: this function changes the instance to move to the
  # next property; caches beware!
  die("attempt to read past end of property list")
    if ($_[0]->size_byte() == 0);

  my $story = $_[0]->story();
  my $pointer = $_[0]->pointer();
  my $size_byte = $story->get_byte_at($pointer);
  $_[0]->size_byte($size_byte);
  if ($size_byte == 0) {
    $_[0]->property_number(0);
    $_[0]->property_exists(0);
    return 0;
  } else {
    my $size_bytes = 1;
    if ($_[0]->pre_v4()) {
      # spec 12.4.1:
      $_[0]->property_number($size_byte & 0x1f);
      # property number is in bottom 5 bytes
      $_[0]->property_len(($size_byte >> 5) + 1);
      # 12.4.1: shifted value is # of bytes minus 1
    } else {
      # spec 12.4.2:
      $_[0]->property_number($size_byte & 0x3f);
      # property number in bottom 6 bits
      if (($size_byte & 0x80) > 0) {
	# top bit is set, there is a second size byte
	$_[0]->property_len($story->get_byte_at($pointer + 1) & 0x3f);
	# length in bottom 6 bits
	$size_bytes = 2;
	if ($_[0]->property_len() == 0) {
	  # 12.4.2.1.1
	  print STDERR "wacky inform compiler size; test this!"; # debug
	  $_[0]->property_len(64);
	}
      } else {
	# 14.2.2.2
	$_[0]->property_len((($size_byte & 0x40) > 0) ? 2 : 1);
      }
    }
    $_[0]->property_offset($pointer + $size_bytes);
    $_[0]->pointer($pointer + $size_bytes + $_[0]->property_len());
    
    return 1;
  }
}

sub set_value {
  # set this property to specified value
  my ($self, $value) = @_;
  if ($self->property_exists()) {
#    print STDERR "set_value to $value\n";
    my $len = $self->property_len();
    my $story = $self->story();
    my $offset = $self->property_offset();
    if (Games::Rezrov::ZOptions::SNOOP_PROPERTIES()) {
      $story->write_text(sprintf "[set value of property %d of %s (%s) = %d]",
			 $self->property_number(),
			 $self->zobj()->object_id(),
			 ${$self->zobj()->print()},
			 $value);
      $story->newline();
    }
    if ($len == 1) {
      $story->set_byte_at($offset, $value);
    } elsif ($len == 2) {
      $story->set_word_at($offset, $value);
    } else {
      die("set_value called on long property");
    }
  } else {
    die("attempt to set nonexistent property");
  }
}

sub get_value {
  # return this value for this property
  my $self = shift;
  my $value = 0;
  if ($self->property_exists()) {
    # this object provides this property
    my $len = $self->property_len();
    my $story = $self->story();
    my $po = $self->property_offset();
#    print STDERR "get_value at $po\n";
    if ($len == 1) {
      $value = $story->get_byte_at($po);
    } elsif ($len == 2) {
      $value = $story->get_word_at($po);
    } else {
      die "get_value() called on long property";
    }
  } else {
    # object does not provide this property: get default value
    $value = $self->get_default_value();
  }
  return($value);
}

sub get_default_value {
  # get the default value for this property ID
  # spec 12.2
  my $self = shift;
  my $story = $self->story();
  my $offset = $story->header()->object_table_address() +
    (($self->search_id() - 1) * 2);
  # FIX ME
  return($story->get_word_at($offset));
}

sub get_data_address {
  return $_[0]->property_offset();
}

sub get_next {
  # return a new ZProperty object representing the property 
  # after this one.  total hack!
  my $self = shift;
  my $next = [];
  bless $next, ref $self;
  @{$next} = @{$self};
  # make a copy of of $self
  $next->next();
  # make new property point to the next one in the list
  return $next;
}

1;
