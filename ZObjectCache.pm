package Games::Rezrov::ZObjectCache;

use strict;

use Games::Rezrov::MethodMaker qw(
				  names
				  rooms
				  items
				  cache
				  last_object
				  last_index
				 );

use SelfLoader;

1;
__DATA__

sub new {
  my $self = {};
  bless $self, shift;
  $self->cache([]);
  return $self;
}

sub load_names {
  my $self = shift;
  return if $self->names();

  my $header = Games::Rezrov::StoryFile::header();
  my $max_objects = $header->max_objects();
  
  my ($o, $desc, $ref);
  my $ztext = Games::Rezrov::StoryFile::ztext();
  my (@names, %rooms, %items);

  my $i;
  for ($i=1; $i <= $max_objects; $i++) {
    # decode the object table
    $o = new Games::Rezrov::ZObject($i);
    $desc = $o->print($ztext);
    if ($$desc =~ /\s{4,}/) {
      # several sequential whitespace characters; consider the end.
      # 3 is not enough for Lurking Horror or AMFV
      $self->last_object($i - 1);
#      print STDERR "$i $$desc\n";
      last;
    } else {
      if (Games::Rezrov::StoryFile::likely_location($desc)) {
	# this is named like a room but might not be.
	# examples: proper names (Suspect: "Veronica"),
	# Zork 3's "Royal Seal of Dimwit Flathead", etc.
	my $p = $self->get($o->get_parent_id());
	if ($p and Games::Rezrov::StoryFile::likely_location($p->print())) {
	  # aha: since this object's parent itself looks like a room,
	  # don't consider this object a room.
	  # example, zork 2:
	  #
	  #    Room 8 (196)
	  #     Frobozz Magic Grue Repellent (22)
	  # 
	  # Grue repellent is an item, but is named like rooms are.
	  #  
          $items{$i} = 1;
        } else {
          $rooms{$i} = 1;
	}
      } else {
	# it's almost certainly not a room.
	$items{$i} = 1;
      }
      $names[$i] = $desc;
#      printf STDERR "%d: %s\n", $i, $$desc;
    }
  }
  $self->last_object($i - 1) unless $self->last_object();

  if (0) {
    print "Rooms:\n";
    foreach (keys %rooms) {
      printf "  %s\n", ${$names[$_]};
    }
    print "Items:\n";
    foreach (keys %items) {
      printf "  %s\n", ${$names[$_]};
    }
  }
  
  $self->names(\@names);
  $self->rooms(\%rooms);
  $self->items(\%items);
}

sub print {
  # get description for a given item
  return $_[0]->names()->[$_[1]];
}

sub get_random {
  # get the name of a random room/item
  my ($self, %options) = @_;
  my $list = $options{"-room"} ? $self->rooms() : $self->items();
  my @list = keys %{$list};
  my $names = $self->names();
  my $last_index = $self->last_index() || 0;
  my $this_index;
  while (1) {
    $this_index = int(rand(scalar @list));
    last if $this_index != $last_index;
  }
  return $names->[$list[$this_index]];
}

sub find {
  # return object ID of an object containing specified text
  # Searches for the literal text and also regexp'ed whitespace.
  # ie "golden canary" matches "golden clockwork canary".
  my ($self, $what, %options) = @_;
  (my $what2 = $what) =~ s/\s+/.*/g;
  my $names = $self->names();
  my %hits;
  my $desc;
  my $list;
  my $rooms = $self->rooms();
  my $items = $self->items();
  if ($options{"-all"}) {
    $list = { %{$rooms}, %{$items} };
  } elsif ($options{"-room"}) {
    $list = $rooms;
  } else {
    $list = $items;
  }

  foreach my $i (keys %{$list}) {
    my $d = $names->[$i];
    $desc = $$d;
    next if $desc =~ /^\d/;
    # begins with a number, ignore --
    # zork 1, #82: "2m cbroken clockwork canary"
    
    if ($desc =~ /$what/i or $desc =~ /$what2/i) {
      if (exists $hits{$desc}) {
	# try to resolve duplicate names; give preference to objects
	# having a parent that looks legit.  Example: "Deadline" has
	# multiple entries for Mrs. Rourke, #148 and #149.
	# #149 looks like the "real" one as she's a child of "Kitchen"
	# location while #148 is in limbo: parent description is junk
	# ("   yc ")
	my $o1 = $self->get($hits{$desc}->[0]);
	my $o2 = $self->get($i);
	my $preferred;
	foreach ($o1, $o2) {
	  my $p = $self->get($_->get_parent_id()) || next;
	  my $desc = $p->print();
	  if ($p and $$desc =~ /^[A-Z]/) {
	    $preferred = $_;
	  } else {
#	    printf STDERR "No pref for %d (%s, p=%s)\n", $_->object_id(), ${$_->print}, $$desc;
	  }
	}
	if ($preferred) {
	  $hits{$desc} = [ $preferred->object_id(), $desc ];
	}
      } else {
	$hits{$desc} = [ $i, $desc ];
      }
    }
  }

  if (scalar keys %hits > 1) {
    my (%h2, %h3);
    foreach (values %hits) {
#      my $regexp = '^$what$';
#      study $regexp;
      if ($_->[1] =~ /^$what$/i) {
        $h2{$_->[1]} = $_;
      }
      foreach my $word (split(/\s+/, $_->[1])) {
	if (lc($word) eq lc($what)) {
	  $h3{$_->[1]} = $_;
	}
      }
    }
    if (scalar keys %h2 == 1) {
      # if there's an exact match for the string, use that.
      # Example: Zork I, if user enters "forest" and we have "forest" and 
      # "forest path", assume user meant "forest".
      %hits = %h2;
    } elsif (scalar keys %h3 == 1) {
      # Give preference to exact whole-word hits.
      # Example: Infidel, "pilfer ring" should assume "jeweled ring" and
      # not even consider "glittering leaf".
      %hits = %h3;
    }
  }

  return values %hits;
}

sub get {
  # fetch the specified object
  my $cache = $_[0]->cache();
  if (defined $cache->[$_[1]]) {
#    printf STDERR "cache hit for %s\n", $_[1];
    return $cache->[$_[1]];
  } else {
#    printf STDERR "new instance for %s\n", $_[1];
    my $zo = new Games::Rezrov::ZObject($_[1]);
    $cache->[$_[1]] = $zo;
    return $zo;
  }
}

sub get_rooms {
  my $self = shift;
  my $names = $self->names();
  my %rooms = map {${$names->[$_]} => 1} keys %{$self->rooms()};
  return sort keys %rooms;
}

sub get_items {
  my $self = shift;
  my $names = $self->names();
#  my %items = map {${$names->[$_]} . " ($_)" => 1} keys %{$self->items()};
  my %items = map {${$names->[$_]} => 1} keys %{$self->items()};
  return sort keys %items;
}

sub is_room {
  my ($self, $id) = @_;
  my $rooms = $self->rooms();
  if ($rooms) {
    # we've fully analyzed the object table
    return exists $rooms->{$id};
  } else {
    # guess
    my $zo = $self->get($id);
    my $desc = $zo->print();
    return Games::Rezrov::StoryFile::likely_location($desc);
  }
}

1;
