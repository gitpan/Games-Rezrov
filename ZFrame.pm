package Games::Rezrov::ZFrame;

use strict;

use Games::Rezrov::MethodMaker ([],
			 qw(
			    arg_count
			    routine_stack
			    call_type
			    rpc
			   ));

my $next_method_index = Games::Rezrov::MethodMaker::get_count();
my $LOCAL_VARS = $next_method_index++;
# speed optimization, avoid sub call for this method

use constant DUMMY => 0;
use constant PROCEDURE => 1;
use constant FUNCTION => 2;
# call types: FIX ME, set type in constructor, method to check type?

use constant MAX_LOCAL_VARIABLES => 15;
# spec 5.2

sub new {
  my ($type, $return_pc) = @_;
  die unless @_ == 2;
  my $self = [];
  bless $self, $type;

  $self->rpc($return_pc);
  $self->routine_stack([]);
  $self->call_type(DUMMY);
  $self->[$LOCAL_VARS] = [];
  return $self;
}

sub set_local_var {
  # args: self, index, value
  $_[0]->[$LOCAL_VARS]->[$_[1]] = $_[2];
}

sub get_local_var {
  # return specified local variable
  return $_[0]->[$LOCAL_VARS]->[$_[1]];
}

sub routine_push {
  # push a variable onto the routine stack
  push @{$_[0]->routine_stack()}, $_[1];
}

sub routine_pop {
  # pop a variable from the routine stack
  return pop @{$_[0]->routine_stack()};
}

sub is_dummy {
  return($_[0]->call_type() eq DUMMY);
}

sub is_function {
  return($_[0]->call_type() eq FUNCTION);
}

sub is_procedure {
  return($_[0]->call_type() eq PROCEDURE);
}

sub count_local_variables {
  # count the number of local variables set.
  # Just finds the highest local variable set to determine ceiling
  my $self = shift;
  my $max = -1;
  my $vars = $self->[$LOCAL_VARS];
  for (my $i=MAX_LOCAL_VARIABLES - 1; $i > 0; $i--) {
    return $i + 1 if (defined($vars->[$i]) and $vars->[$i] > 0);
    # index 0 means 1 variable is set
  }
  return 0;
}

1;

