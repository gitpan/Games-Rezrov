package Games::Rezrov::ZStatus;
# all info required to refresh the status line; see spec 8.2

use Games::Rezrov::MethodMaker ([],
			 qw(
			    story
			    score
			    moves
			    hours
			    minutes
			    time_game
			    score_game
			    location
			   ));

use Games::Rezrov::Inliner;

my $INLINE_CODE = '
sub update () {
  # refresh information required for status line.
  my $self = shift;
  my $story = $self->story();
  
  # get the current location:
  my $object_id = $story->get_global_var(0);
  # 8.2.2.1
  
  my $zobj = new Games::Rezrov::ZObject($object_id, $story);
  $self->location(${$zobj->print($story->ztext())});
#  die "loc = $location";

  if ($self->time_game()) {
    $self->hours($story->get_global_var(1));
    $self->minutes($story->get_global_var(2));
  } else {
    $self->score(SIGNED_WORD($story->get_global_var(1)));
    $self->moves($story->get_global_var(2));
  }
}
';

Games::Rezrov::Inliner::inline(\$INLINE_CODE);
eval $INLINE_CODE;
undef $INLINE_CODE;


sub new {
  my ($type, $story) = @_;
  
  my $self = [];
  bless $self, $type;
  
  $self->story($story);
  $self->hours(0);
  $self->minutes(0);
  $self->moves(0);
  $self->score(0);
  $self->time_game(0);
  $self->score_game(0);
  
  if ($story->header()->is_time_game()) {
    $self->time_game(1);
  } else {
    $self->score_game(1);
  }
  return $self;
}


1;
