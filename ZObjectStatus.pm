package Games::Rezrov::ZObjectStatus;

use strict;
use SelfLoader;

use Games::Rezrov::MethodMaker qw(
				  is_player
				  is_current_room
				  is_toplevel_child
				  in_inventory
				  in_current_room
				  parent_room
				  toplevel_child
				 );

1;

__DATA__

sub new {
  my ($type, $id, $story, $object_cache) = @_;
  my $self = {};
  bless $self, $type;

  my $pid = $story->player_object() || -1;
  my $current_room = $story->current_room() || -1;
  my $zo = $object_cache->get($id);
  my $levels = 0;
  my $last;

  my $oid = $zo->object_id();
  $self->is_player($pid == $oid);
  $self->is_current_room($current_room == $oid);

  while (1) {
    last unless defined $zo;
    my $oid = $zo->object_id();
    $self->in_inventory(1) if $oid == $pid;
    if ($object_cache->is_room($oid)) {
      $self->in_current_room(1) if ($oid == $current_room);
      $self->parent_room($zo);
      $self->toplevel_child($last);
      last;
    }
    $levels++;
    $last = $zo;
    $zo = $object_cache->get($zo->get_parent_id());
  }
  $self->is_toplevel_child($levels == 1);
  
  return $self;
}

