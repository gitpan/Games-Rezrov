package Games::Rezrov::ZProperty;
# object properties

use strict;

use constant FIRST_PROPERTY => -1;
# used to find the first property in the object

use Games::Rezrov::MethodMaker ([],
			 qw(
			    size_byte
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

use Games::Rezrov::Inliner;

use SelfLoader;

my $INLINE_CODE = '

sub get_value {
  # return this value for this property
  if ($_[0]->property_exists()) {
    # this object provides this property
    my $len = $_[0]->property_len();
    my $po = $_[0]->property_offset();
#    print STDERR "get_value at $po\n";
    if ($len == 2) {
      return GET_WORD_AT($po);
    } elsif ($len == 1) {
      return GET_BYTE_AT($po);
    } else {
      die "get_value() called on long property";
    }
  } else {
    # object does not provide this property: get default value
    return $_[0]->get_default_value();
  }
}

sub next {
  # search for a specific property, or move to the next one
  my ($self, $search_id) = @_;
  die("attempt to read past end of property list")
    if ($self->size_byte() == 0);
  my $pointer = $self->pointer();

  my $property_number;
  my $exists = 0;
  my $size_byte;
  my $property_len;
  my $last_id;
  my $property_offset = 0;
  my $pre_v4 = $self->pre_v4();
  while (1) {
#    print STDERR "search\n";
    $size_byte = GET_BYTE_AT($pointer);
    if ($size_byte == 0) {
      $property_number = 0;
      last;
    } else {
      my $size_bytes = 1;
      if ($pre_v4) {
	# spec 12.4.1:
	$property_number = $size_byte & 0x1f;
	# property number is in bottom 5 bytes
	$property_len = ($size_byte >> 5) + 1;
	# 12.4.1: shifted value is # of bytes minus 1
      } else {
	# spec 12.4.2:
	$property_number = $size_byte & 0x3f;
	# property number in bottom 6 bits
	if (($size_byte & 0x80) > 0) {
	  # top bit is set, there is a second size byte
	  $property_len = GET_BYTE_AT($pointer + 1) & 0x3f;
	  # length in bottom 6 bits
	  $size_bytes = 2;
	  if ($property_len == 0) {
	    # 12.4.2.1.1
	    print STDERR "wacky inform compiler size; test this!"; # debug
	    $property_len = 64;
	  }
	} else {
	  # 14.2.2.2
	  $property_len = ($size_byte & 0x40) > 0 ? 2 : 1;
	}
      }
      $property_offset = $pointer + $size_bytes;
      $pointer += $size_bytes + $property_len;
    }

    if (!(defined $search_id) or $search_id == FIRST_PROPERTY) {
      # move to next/first property
      $exists = 1;
      last;
    } else {
      if ($last_id and $property_number > $last_id) {
	# 12.4: properties are stored in descending numerical order
	# this means we are past the end
	# ...need example case here!
	last;
      } elsif ($search_id > $property_number) {
	# went past where it would have been had it existed
	last;
      } else {
	$last_id = $property_number;
	#    printf STDERR "prop search %s: %d\n", $zobj->object_id, $self->property_number;
	if ($property_number == $search_id) {
	  #      print STDERR "got it\n";
	  $exists = 1;
	  last;
	  # 12.4.1
	}
      }
    }
  }
  $self->property_exists($exists);
#  print STDERR "exists: $exists\n";
  $self->property_len($property_len);
  $self->property_number($property_number);
  $self->size_byte($size_byte);
  $self->property_offset($property_offset);
  $self->pointer($pointer);
}

sub get_default_value {
  # get the default value for this property ID
  # spec 12.2
  my $offset = Games::Rezrov::StoryFile::header()->object_table_address() +
    (($_[0]->search_id() - 1) * 2);
  # FIX ME
  return(GET_WORD_AT($offset));
}

';

Games::Rezrov::Inliner::inline(\$INLINE_CODE);
eval $INLINE_CODE;
undef $INLINE_CODE;

1;
__DATA__

sub new {
  my ($type, $search_id, $zobj) = @_;

#  printf STDERR "new zprop %s for obj %s\n", $search_id, $zobj->object_id();

  my $self = [];
  bless $self, $type;

  $self->zobj($zobj);
  $self->pre_v4(Games::Rezrov::StoryFile::version() <= 3);
  $self->search_id($search_id);

  $self->size_byte(-1);
  $self->pointer($zobj->property_start_index());
  $self->property_offset(-1);
  $self->next($search_id);
  return $self;
}

sub set_value {
  # set this property to specified value
  my ($self, $value) = @_;
  if ($self->property_exists()) {
#    print STDERR "set_value to $value\n";
    my $len = $self->property_len();
    my $offset = $self->property_offset();
    if (Games::Rezrov::ZOptions::SNOOP_PROPERTIES()) {
      Games::Rezrov::StoryFile::write_text(sprintf("[set value of property %d of %s (%s) = %d]",
					   $self->property_number(),
					   $self->zobj()->object_id(),
					   ${$self->zobj()->print()},
                                           $value), 1);
    }
    if ($len == 1) {
      Games::Rezrov::StoryFile::set_byte_at($offset, $value);
    } elsif ($len == 2) {
      Games::Rezrov::StoryFile::set_word_at($offset, $value);
    } else {
      die("set_value called on long property");
    }
  } else {
    die("attempt to set nonexistent property");
  }
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
