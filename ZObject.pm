# ZObject: z-code Object, containing "attributes" (flags)
# and "properties" (values).
package Games::Rezrov::ZObject;

use strict;
use Games::Rezrov::ZProperty;
use Games::Rezrov::ZText;
use Games::Rezrov::MethodMaker ([],
			 qw(
			    story
			    prop_addr
			    object_id
			    pointer_size
			    property_start_index
			    attrib_offset
			    sibling_offset
			    child_offset
			    parent_offset
			    properties_offset
			    property_cache
			   ));

use SelfLoader;

#use Carp qw(cluck);

1;

__DATA__

sub new {
  my ($type, $object_id, $story) = @_;

#  cluck "new zobj $object_id!\n" if $object_id == 0;
  return undef if $object_id == 0;
  # no such object
  
  my $self = [];
#  my $self = {};
  bless $self, $type;

  die unless $story;
  $self->object_id($object_id);
  $self->story($story);
  my $header = $story->header();

  my $attrib_offset = $header->attribute_starter() +
    $header->object_bytes() * ($object_id - 1);
  
  my $pointer_size = $header->pointer_size();
  $self->pointer_size($pointer_size);

  my $parent_offset = $attrib_offset + $header->attribute_bytes();
  my $sibling_offset = $parent_offset + $pointer_size;
  my $child_offset = $sibling_offset + $pointer_size;
  my $properties_offset = $child_offset + $pointer_size;

  my $prop_addr = $story->get_word_at($properties_offset);
  my $text_words = $story->get_byte_at($prop_addr);
  # spec section 12.4: property table header,
  # first byte is length of "short name" text
  $self->property_start_index($prop_addr + 1 + ($text_words * 2));
  
  $self->prop_addr($prop_addr);
  $self->attrib_offset($attrib_offset);
  $self->parent_offset($parent_offset);
  $self->sibling_offset($sibling_offset);
  $self->child_offset($child_offset);
  $self->properties_offset($properties_offset);
  $self->property_cache({});

  return $self;
}


sub get_property {
  # arg: property number
  my $zp;
  my $pc = $_[0]->property_cache();
#  printf STDERR "want prop %s of obj %s (%s)...", $_[1], $_[0]->object_id(), ${$_[0]->print};
  if (0 and $zp = $pc->{$_[1]}) {
#    printf STDERR "cache hit\n";
    return $zp;
  } else {
    $zp = new Games::Rezrov::ZProperty($_[1], $_[0], $_[0]->story());
    $pc->{$_[1]} = $zp;
#    print STDERR "\n";
    return $zp;
  }
}

sub test_attr {
  my ($self, $attribute) = @_;
  # return true of specified attribute of this object is set,
  # false otherwise.
  # spec 12.3.1.
  # attributes are numbered from 0 to 31, and stored in 4 bytes,
  # bits starting at "most significant" and ending at "least".
  # ie attrib 0 is high bit of first byte, attrib 31 is low bit of 
  # last byte.
  
  my $byte_offset = $attribute / 8;
  # which of the 4 bytes the attribute is in
  my $bit_position = ($attribute % 8);
  # which bit in the byte (starting at high bit, counted as #0)
  my $bit_shift = 7 - $bit_position;
  my $story = $self->story();
  my $the_byte = $story->get_byte_at($self->attrib_offset() + $byte_offset);
  my $the_bit = ($the_byte >> $bit_shift) & 0x01;
  # move target bit into least significant byte

  if (Games::Rezrov::ZOptions::SNOOP_ATTR_TEST()) {
    $story->write_text(sprintf "[Test attribute %d of %s (%s) = %d]",
		       $attribute,
		       $self->object_id(),
		       ${$self->print()},
		      $the_bit == 1);
    $story->newline();
  }

  return ($the_bit == 1);
}

sub remove {
    # remove this object from its parent/sibling chain.
  my ($self) = @_;
  my $parent = $self->get_parent();
  unless ($parent) {
    # no parent, quit
    return;
  } else {
    my $object_id = $self->object_id;
    my $child = $parent->get_child();
    # get child of old parent
    if ($parent->get_child_id() == $object_id) {
      # first child matches: set child of old parent to first sibling
      # of the object being removed
      $parent->set_child_id($self->get_sibling_id());
    } else {
      my $prev_sib = $child;
      my $this_sib;
      for ($this_sib = $child->get_sibling(); defined($this_sib);
	   $prev_sib = $this_sib, $this_sib = $this_sib->get_sibling()) {
	if ($this_sib->object_id() == $object_id) {
	  # found it
	  $prev_sib->set_sibling_id($this_sib->get_sibling_id());
	  last;
	  # set the "next sibling" pointer of the previous
	  # sibling in the chain to the next sibling of this
	  # object (the one we're removing).
	}
      }
      if (not defined($this_sib)) {
	# sanity check
	die("attempt to delete object " + $object_id + " failed!");
      }
    }
  }
  $self->set_parent_id(0);
  $self->set_sibling_id(0);
}

sub get_parent {
  return $_[0]->get_object($_[0]->parent_offset());
}

sub get_sibling {
  return $_[0]->get_object($_[0]->sibling_offset());
}

sub get_child {
  return $_[0]->get_object($_[0]->child_offset());
}

sub get_object {
  # fetch ZObject with address at specified story byte
  my ($self, $offset) = @_;
  my $story = $self->story();
  my $header = $story->header();

  my $id = $self->get_ptr($offset);
  if ($id >= 1 && $id <= $header->max_objects()) {
    return new Games::Rezrov::ZObject($id, $story);
  } elsif ($id == 0) {
    # object id 0 means "nothing", return null
    return undef;
  } else {
    print STDERR "object id $id is out of range";
    return undef;
  } 
}

sub set_ptr {
  # args: offset value
  # set a value, depending on pointer size
  if ($_[0]->pointer_size() == 1) {
    $_[0]->story()->set_byte_at($_[1], $_[2]);
  } else {
    $_[0]->story()->set_word_at($_[1], $_[2]);
  }
}

sub get_ptr {
  # get a value, depending on pointer size
  # args: offset
  my $story = $_[0]->story();
  if ($_[0]->pointer_size() == 1) {
    return $story->get_byte_at($_[1]);
  } else {
    return $story->get_word_at($_[1]);
  }
}

sub get_child_id {
  return $_[0]->get_ptr($_[0]->child_offset());
}

sub get_parent_id {
  return $_[0]->get_ptr($_[0]->parent_offset());
}

sub get_sibling_id {
  return $_[0]->get_ptr($_[0]->sibling_offset());
}

sub set_parent_id {
  # set parent object id of this object to specified id
  $_[0]->set_ptr($_[0]->parent_offset(), $_[1]);
}

sub set_child_id {
  $_[0]->set_ptr($_[0]->child_offset(), $_[1]);
}

sub set_sibling_id {
  $_[0]->set_ptr($_[0]->sibling_offset(), $_[1]);
}

sub set_attr {
  # set an attribute for an object; spec 12.3.1
  my ($self, $attribute) = @_;
  my $story = $self->story();
  my $byte_offset = $attribute / 8;
  my $bit_position = $attribute % 8;
  my $bit_shift = 7 - $bit_position;
  my $mask = 1 << $bit_shift;
  my $where = $self->attrib_offset() + $byte_offset;
  my $the_byte = $story->get_byte_at($where);
  $the_byte |= $mask;
  $story->set_byte_at($where, $the_byte);
  if (Games::Rezrov::ZOptions::SNOOP_ATTR_SET()) {
    $story->write_text(sprintf "[Set attribute %d of %s (%s)]",
		       $attribute,
		       $self->object_id(),
		       ${$self->print()});
    $story->newline();
  }
}

sub clear_attr {
  # clear an attribute for an object; spec 12.3.1
  my ($self, $attribute) = @_;
  my $story = $self->story();
  my $byte_offset = $attribute / 8;
  my $bit_position = ($attribute % 8);
  my $bit_shift = 7 - $bit_position;
  my $mask = ~(1 << $bit_shift);
  my $where = $self->attrib_offset() + $byte_offset;
  my $the_byte = $story->get_byte_at($where);
  $the_byte &= $mask;
  $story->set_byte_at($where, $the_byte);
  if (Games::Rezrov::ZOptions::SNOOP_ATTR_CLEAR()) {
    $story->write_text(sprintf "[Clear attribute %d of %s (%s)]",
		       $attribute,
		       $self->object_id(),
		       ${$self->print()},
   );
    $story->newline();
  }
}

sub print {
  my ($self, $text) = @_;
  $text = new Games::Rezrov::ZText($self->story()) unless $text;
  # eek
  return $text->decode_text($self->prop_addr() + 1);
}

sub validate {
  # guess if this is a valid object or not; a few sanity checks
  # UNUSED
  my ($self, $max_objects) = @_;

  return 0 if $self->object_id() < 1;

  my $offset = $self->get_ptr($self->parent_offset());
  return 0 if $offset < 0 or $offset > $max_objects;
  $offset = $self->get_ptr($self->sibling_offset());
  return 0 if $offset < 0 or $offset > $max_objects;
  $offset = $self->get_ptr($self->child_offset());
  return 0 if $offset < 0 or $offset > $max_objects;
  # Hopeless: bad data is always in range :(

  return 1;
}

1;
