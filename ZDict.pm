package Games::Rezrov::ZDict;
# dictionary routines

use strict;
use 5.004;
use SelfLoader;

use Games::Rezrov::ZObjectCache;
use Games::Rezrov::ZObject;
use Games::Rezrov::ZText;
use Games::Rezrov::ZConst;
use Games::Rezrov::ZObjectStatus;

use Games::Rezrov::MethodMaker ([],
			 qw(
			    ztext
			    dictionary_word_start
			    entry_length
			    entry_count
			    separators
			    encoded_word_length
			    version
			    story
			    decoded_by_word
			    decoded_by_address
			    object_cache
			    last_random
			   ));

use constant ZORK_1 => ("Zork I", 88, "840726", 41257);
use constant ZORK_2 => ("Zork II", 48, "840904", 55449);
use constant ZORK_3 => ("Zork III", 17, "840727", 11898);
use constant INFIDEL => ("Infidel", 22, "830916", 16674);

use constant SNIDE_MESSAGES => (
				'A hollow voice says, "cretin."',
				'An invisible boot kicks you in the shin. Ouch!',
				'An invisible hand smacks you in the head. Ouch!',
#				'An invisible hand slaps you smartly across the face.  Ouch!',
			       );

use constant PILFER_LOCAL_MESSAGES => (
				       'The %s glows briefly with a faint blue glow.',
				       'Sparks fly from the %s!',
				       'The %s shimmers briefly.',
				      );

use constant PILFER_SELF_MESSAGES => (
				      'You feel invisible hands grope around your person.',
				      'You feel invisible hands rifling through your possessions.',
				      
);

use constant PILFER_REMOTE_MESSAGES => (
					'The earth seems to shift slightly beneath your feet.',
					'You hear a roll of thunder in the distance.',
					'A butterfly flits by, glistening green and gold and black.  There is a sound of thunder...',
					# Ray Bradbury = The Man
					'The smell of burning leaves surrounds you.',
				       );

use constant TELEPORT_MESSAGES => (
				   'You blink, and find your surroundings have changed...',
				   'You are momentarily dizzy, and then...',
				   '*** Poof! ***',
#				   'The taste of salted peanuts fills your mouth.',
				   
				  );

use constant TELEPORT_HERE_MESSAGES => (
					"Look around you!",
					"Sigh...",
#					"So that's why cabs have minimum fares...",
					"You experience the strange sensation of materializing in your own shoes.",
				       );

use constant TELEPORT_TO_ITEM_MESSAGES => (
					   "Oh yes, that's right over here...",
					   "Right this way...",
					  );

use constant SHAMELESS_MESSAGES => (
				    "Michael Edmonson just wishes he were an Implementor.",
				    "Michael Edmonson is a sinister, lurking presence in the dark places of the earth.  His favorite diet is onion rings from Cooke's Seafood, but his insatiable appetite is tempered by his fear of light.  Michael Edmonson has never been seen by the light of day, and few have survived his fearsome jaws to tell the tale.",
				    "Somebody with too much time on his hands, clearly.",
				   );

use constant FROTZ_SELF_MESSAGES => (
				     "Nah.",
				     "Bizarre!",
				     "I'd like to; unfortunately it won't work.",
				     "How about one of your fine possessions instead?",
				    );

use constant BANISH_MESSAGES => (
#				 'The %s disappears in a shower of sparks.',
				 'A cloud of sinister black fog descends; when it lifts, the %s is nowhere to be seen.',
				 'There is a bright flash; when you open your eyes, the %s is nowhere to be seen.',
				 'The %s disappears with a pop.'
				 );

use constant BANISH_CONTAINER_MESSAGES => (
					   'The %s flickers with a faint blue glow.',
					   'The %s shimmers briefly.'
				 );

use constant BANISH_SELF_MESSAGES => (
				      'You feel a tickle.',
				      'Your load feels lighter.',
				      '%s?  What %s?',
				 );

use constant TRAVIS_MESSAGES => (
				 "Looking at the %s, you suddenly feel an inflated sense of self-esteem.",
				 "The %s looks more dangerous already.",
				 "The %s glows wickedly.",
				);

use constant HELP_INFOCOM_URLS => (
				   "http://www.csd.uwo.ca/~pete/Infocom/Invisiclues/",
				  );

use constant HELP_GENERIC_URLS => (
				   "http://www.yahoo.com/Recreation/Games/Interactive_Fiction/",
);

%Games::Rezrov::ZDict::MAGIC_WORDS = map {$_ => 1} (
						    "pilfer",
						    "teleport",
						    "#teleport",
						    "bamf",
						    "lingo",
						    "embezzle",
						    "omap",
						    "lumen",
						    "frotz",
						    "futz",
						    "travis",
						    "bickle",
						    "tail",
						   );

%Games::Rezrov::ZDict::ALIASES = (
			   "x" => "examine",
			   "g" => "again",
			   "z" => "wait",
			   "l" => "look",
			  );

1;
__DATA__

sub new {
  my ($type, $story) = @_;
  my $self = [];
  bless $self, $type;
  $self->story($story);
  $self->version($story->version());
  $self->ztext($story->ztext());
  my $header = $story->header();
  $self->encoded_word_length($header->encoded_word_length());
  my $dp = $header->dictionary_address();
  
  $self->decoded_by_word({});
  $self->decoded_by_address({});

  # 
  #  get token separators
  #
  my $sep_count = $story->get_byte_at($dp++);
  my %separators;
  for (my $i=0; $i < $sep_count; $i++) {
    $separators{chr($story->get_byte_at($dp++))} = 1;
  }
  $self->separators(\%separators);
  
  $self->entry_length($story->get_byte_at($dp++));
  # number of bytes for each encoded word
  $self->entry_count($story->get_word_at($dp));
  # number of words in the dictionary
  $dp += 2;

  $self->dictionary_word_start($dp);
  # start address of encoded words
  
#  die sprintf "%s %s\n", $self->entry_length(), $self->entry_count();
  
  return $self;
}

sub save_buffer {
  # copy the input buffer to story memory.
  # This may be called internally during oops emulation.
  my ($self, $buf, $text_address) = @_;
  my $mem_offset;
  my $story = $self->story();
  my $z_version = $self->version();
  my $len = length $buf;
  if ($z_version >= 5) {
    $story->set_byte_at($text_address + 1, $len);
    $mem_offset = $text_address + 2;
  } else {
    $mem_offset = $text_address + 1;
  }
  
  for (my $i=0; $i < $len; $i++, $mem_offset++) {
    # copy the buffer to memory
    $story->set_byte_at($mem_offset, ord substr($buf,$i,1));
  }
  $story->set_byte_at($mem_offset, 0) if ($z_version <= 4);
  # terminate the line
}

sub tokenize_line {
  my ($self, $text_address, $token_address,
      $text_len, $oops_word) = @_;
  
#  my $b1 = new Benchmark();
  my $story = $self->story();
  my $max_tokens = $story->get_byte_at($token_address);
  my $token_p = $token_address + 2;
  # pointer to location where token data will be written
  my $separators = $self->separators();

  #
  #  Step 1: parse out the tokens
  #
  my $text_p = $text_address + 1;
  # skip past max bytes enterable
  if ($self->version() >= 5) {
    $text_len = $story->get_byte_at($text_p) unless defined $text_len;
    # needed if called from tokenize opcode (VAR 0x1b)
    $text_p++;
    # move pointer past length of entered text.
  }
  my $raw_input = $story->get_string_at($text_p, $text_len);

  my $text_end = $text_p + $text_len;
  # we're passed the length because in <= v4 we would have to count
  # the bytes in the buffer, looking for terminating zero.

  my @tokens;
  my $start_offset = 0;
  # token start position
  my $token = "";

  my $c;
  my $token_done = 0;
  my $all_done = 0;
  while (! $all_done) {
    if ($text_p >= $text_end) {
      # finished
      $token_done = 1;
      $all_done = 1;
    } else {
      $start_offset = $text_p unless $start_offset;
      $c = chr($story->get_byte_at($text_p++));
      if ($c eq ' ') {
	# a space character:
	if ($token) {
	  # token is completed
	  $token_done = 1;
	} else {
	  # ignore whitespace: move start pointer past it
	  $start_offset++;
	}
      } elsif (exists $separators->{$c}) {
	# hit a game-specific token separator
#	print STDERR "separator: $c\n";
	$token_done = 1;
	if ($token) {
	  # a token is already built; use it, and move
	  # text pointer back one so we'll make a new token
	  # out of this separator
	  $text_p--;
	} else {
	  # the separator itself is a token
	  $token = $c;
	}
      } else {
	# append to the token
	$token .= $c;
      }
    }
    if ($token_done) {
      push @tokens, [ $token, $start_offset - $text_address ] if $token;
      $token = "";
      $token_done = $start_offset = 0;
    }
  }
#  printf STDERR "tokens: %s\n", join "/", map {$_->[0]} @tokens;

  if (@tokens == 3 and
      Games::Rezrov::ZOptions::SHAMELESS() and
      $tokens[0]->[0] =~ /^(who|what)$/i and
      $tokens[1]->[0] =~ /^is$/ and
      $tokens[2]->[0] =~ /^(michae\w*|edmons\w*)/) {
    # shameless self-promotion
    unless ($self->get_dictionary_address($1)) {
      # don't do anything if name is in dictionary (e.g. Suspect has a Michael)
      $story->write_text($self->random_message(SHAMELESS_MESSAGES));
      $story->newline();
      $story->newline();
      $story->suppress_hack();
      return;
    }
  }

  #
  #  Step 2: store dictionary addresses for words
  #
  my $encoded_length = $self->encoded_word_length();
  my $wrote_tokens = 0;
  my $untrunc_token;
  for (my $ti = 0; $ti < @tokens; $ti++) {
    my ($token, $offset) = @{$tokens[$ti]};
    if ($wrote_tokens++ < $max_tokens) {
      $untrunc_token = lc($token);
      $token = substr($token,0,$encoded_length)
	if length($token) > $encoded_length;
      my $addr = $self->get_dictionary_address($token);
      if ($addr == 0) {
	if (Games::Rezrov::ZOptions::EMULATE_NOTIFY() and $token eq "notify") {
	  $story->notify_toggle();
	} elsif (Games::Rezrov::ZOptions::EMULATE_HELP() and $token eq "help") {
	  $self->help();
	} elsif (Games::Rezrov::ZOptions::EMULATE_OOPS() and ($oops_word or
					      (($token eq "oops") or
					       (Games::Rezrov::ZOptions::ALIASES() and $token eq "o")))) {
	  if ($oops_word) {
	    # replace misspelled word
	    $addr = $self->get_dictionary_address($oops_word);
	  } else {
	    # entered "oops"
	    my $last_input = $story->last_input();
	    $self->save_buffer($last_input, $text_address);
	    $self->tokenize_line($text_address, $token_address, length($last_input), $tokens[$ti + 1]->[0]);
	    return;
	  }
	} elsif (Games::Rezrov::ZOptions::MAGIC() and exists $Games::Rezrov::ZDict::MAGIC_WORDS{$untrunc_token}) {
	  (my $what = $raw_input) =~ s/.*?${untrunc_token}\s*//i;
	# use the raw input rather than joining the remaining tokens.
	# Necessary if the query string contains what the game considers
	# tokenization characters.  For example, "Mrs. Robner" in Deadline
	# is broken into 3 tokens: "Mrs", ".", and "Robner".  Joined
	# this is "Mrs . Robner", which doesn't match anything in the object
	# table.
#	print STDERR "magic: $what\n";
	  $self->magic($untrunc_token, $what);
#		       $ti < @tokens - 1 ?
#		       join " ", map {$_->[0]} @tokens[$ti + 1 .. $#tokens]
#		       : "");
	} elsif (Games::Rezrov::ZOptions::ALIASES() and
		 exists $Games::Rezrov::ZDict::ALIASES{$untrunc_token}) {
	  $addr = $self->get_dictionary_address($Games::Rezrov::ZDict::ALIASES{$untrunc_token});
	} elsif (Games::Rezrov::ZOptions::EMULATE_COMMAND_SCRIPT() and
		 $token eq "#reco" or
		 $token eq "#unre" or
		 $token eq "#comm") {
	  if ($token eq "#comm") {
	    # play back commands
	    $story->input_stream(Games::Rezrov::ZConst::INPUT_FILE);
	  } else {
	    $story->output_stream($token eq "#reco" ? Games::Rezrov::ZConst::STREAM_COMMANDS : - Games::Rezrov::ZConst::STREAM_COMMANDS);
	  }
	  $story->newline();
	  $story->suppress_hack();
	} elsif ($token eq "#cheat") {
	  my $status = !(Games::Rezrov::ZOptions::MAGIC());
	  Games::Rezrov::ZOptions::MAGIC($status);
	  $story->write_text(sprintf "Cheating is now %sabled.", $status ? "en" : "dis");
	  $story->newline();
	  $story->newline();
	  $story->suppress_hack();
	} elsif ($token eq "rooms") {
	  # print room names
	  $self->dump_objects(2);
	  $story->newline();
	  $story->suppress_hack();
	} elsif ($token eq "items") {
	  # print item names
	  $self->dump_objects(3);
	  $story->newline();
	  $story->suppress_hack();
	}
      }
      $story->set_word_at($token_p, $addr);
      $story->set_byte_at($token_p + 2, length $untrunc_token);
      $story->set_byte_at($token_p + 3, $offset);
      $token_p += 4;
    } else {
      $story->write_text("Too many tokens; ignoring $token");
      $story->newline();
    }
  }

  $story->set_byte_at($token_address + 1, $wrote_tokens);
  # record number of tokens written

#  my $b2 = new Benchmark();
#  my $td = timediff($b2, $b1);
#  printf STDERR "took: %s\n", timestr($td, 'all');

}

sub get_dictionary_address {
  # get the dictionary address for the given token.
  #
  # NOTES:
  #   This does NOT conform to the spec; officially, we should encode
  #   the word and look up the encoded value.  This would be a bit
  #   faster, but I'm too Lazy and Impatient right now to do it that
  #   way.  Contains ugly hacks for non-alphanumeric "words".
  #

  my $self = $_[0];
  my $token = lc($_[1]);

  my $max = $self->encoded_word_length();
  $token = substr($token,0,$max) if length($token) > $max;
  # make sure token is truncated to max length

  my $by_name = $self->decoded_by_word();

  if (exists $by_name->{$token}) {
    # we already know where this word is; return its address
#    print STDERR "cache hit for $token\n";
    return $by_name->{$token};
  } else {
    # find the word
    my $dict_start = $self->dictionary_word_start();
    my $ztext = $self->ztext();
    my $num_words = $self->entry_count();
    my $entry_length = $self->entry_length();
    my $by_address = $self->decoded_by_address();
    my $char = substr($token,0,1);
    my $search_index;
    my $linear_search = 0;
    if ($char =~ /[a-z]/) {
      $search_index = int(($num_words - 1) * (ord(lc($char)) - ord('a')) / 26);
      # pick an approximate start position
    } elsif (ord($char) < ord 'a') {
      $search_index = 0;
      $linear_search = 1;
    } else {
      printf STDERR "tokenize: fix me, char %d", ord($char);
    }

    my ($address, $word, $delta_mult, $delta, $next);
    my $behind = -1;
    my $ahead = $num_words;
    while (1) {
      $address = $dict_start + ($search_index * $entry_length);
      if (exists $by_address->{$address}) {
	# already know word for this address
#	print STDERR "address cache hit!\n";
	$word = $by_address->{$address};
      } else {
	# decode word at this address and cache
	$word = ${$ztext->decode_text($address)};
	$by_name->{$word} = $address;
	$by_address->{$address} = $word;
      }
#      print "Got $word at $search_index\n";
      if ($word eq $token) {
	# found the word we're looking for: done
	return $address;
      } else {
	# missed: search further
	if ($linear_search) {
	  $next = $search_index + 1;
	} else {
	  $delta_mult = $token cmp $word;
	  # determine direction we need to search
	  if ($delta_mult == -1) {
	    # ahead; need to search back
	    $delta = int(($search_index - $behind) / 2);
	    $ahead = $search_index;
	  } else {
	    # behind; need to search ahead
	    $delta = int(($ahead - $search_index) / 2);
	    $behind = $search_index;
	  }
	  $delta = 1 if $delta == 0;
	  $next = $search_index + ($delta * $delta_mult);
	}
	if ($next < 0 or $next >= $num_words) {
	  # out of range
	  return 0;
	} elsif ($next == $ahead or $next == $behind) {
	  # word does not exist between flanking words
	  return 0;
	} else {
	  $search_index = $next;
	}
      }
    }
  }
  die;
}

sub magic {
  #
  #  >read dusty book
  #  The first page of the book was the table of contents. Only two
  #  chapter names can be read: The Legend of the Unseen Terror and
  #  The Legend of the Great Implementers.
  #  
  #  >read legend of the implementers
  #  This legend, written in an ancient tongue, speaks of the
  #  creation of the world. A more absurd account can hardly be
  #  imagined. The universe, it seems, was created by "Implementers"
  #  who directed the running of great engines. These engines       
  #  produced this world and others, strange and wondrous, as a test
  #  or puzzle for others of their kind. It goes on to state that
  #  these beings stand ready to aid those entrapped within their
  #  creation. The great magician-philosopher Helfax notes that a
  #  creation of this kind is morally and logically indefensible and
  #  discards the theory as "colossal claptrap and kludgery."
  #
  
  my ($self, $token, $what) = @_;
  my $story = $self->story();
  my $object_cache = $self->get_object_cache();

  if ($what) {
    my $po = $story->player_object();
    my $cr = $story->current_room();
    if ($po and $what =~ /^(me|self)$/i) {
      # for the purposes of these commands, consider "me" and "self"
      # equivalent to the player object (whatever that's called)
      my $desc = $object_cache->print($po);
      $what = $$desc;
    } elsif ($cr and $what =~ /^here$/) {
      # likewise consider "here" to be the current room
      my $desc = $object_cache->print($cr);
      $what = $$desc;
    }
  }

  my $just_one_newline = 0;

  if (0 and $token eq "fbg") {
    # can we make arbitrary things glow with a faint blue glow?
    # (nope)
    my $zo = new Games::Rezrov::ZObject(160, $story);
    # 160=mailbox
    my $zp = $zo->get_property(12);
    $story->write_text($zp->property_exists() ? "yes" : "no");
  } elsif (0 and $token eq "fbg2") {
    # do all objects with "blue glow" property behave the same?
    my $object_cache = $self->get_object_cache();
    for (my $i = 1; $i <= $object_cache->last_object(); $i++) {
      my $zo = new Games::Rezrov::ZObject($i, $story);
      my $zp = $zo->get_property(12);
      if ($zp->property_exists()) {
	$zp->set_value(3);
	$story->write_text(${$zo->print()});
	$story->newline();
      }
    }
  } elsif ($token eq "omap") {
    # dump object relationships
    $self->dump_objects(1, $what);
  } elsif ($token eq "lingo") {
    # dump the dictionary
    $self->dump_dictionary($what);
  } elsif ($token eq "embezzle") {
    # manipulate game score
    if ($story->version() > 3) {
      $story->write_text("Sorry, this trick only works in version 3 games.");
    } elsif ($story->header()->is_time_game()) {
      $story->write_text("Sorry, this trick doesn't work in \"time\" games.");
    } elsif ($what) {
      if ($what =~ /^-?\d+$/) {
	$story->set_global_var(1, $what);
	$story->write_text("\"Clickety click...\"");
	# BOFH
      } else {
	$story->write_text("Is that a score on your planet?");
      }
    } else {
      $story->write_text("Tell me what to set your score to.");
    }
  } elsif ($token =~ "#?teleport") {
    $self->teleport($what);
  } elsif ($token eq "travis" or $token eq "bickle") {
    $self->travis($what);
  } elsif ($token =~ /^(frotz|futz|lumen)$/) {
    $self->frotz($what);
  } elsif ($token eq "tail") {
    $self->tail($what);
  } else {
    # pilfer or bamf
    my @hits = $what ? $object_cache->find($what, "-room" => 0) : ();
    if (@hits > 1) {
      $story->write_text(sprintf 'Hmm, which do you mean: %s?',
			 nice_list(sort map {$_->[1]} @hits));
    } elsif (@hits == 1) {
      my ($id, $desc) = @{$hits[0]};
      my $zo = $object_cache->get($id);
      my $zstat = new Games::Rezrov::ZObjectStatus($hits[0]->[0],
						   $story,
						   $object_cache);

      if ($token eq "bamf") {
	#
	#  Make an object disappear
	#
	if ($zstat->is_player()) {
	  $story->write_text("You are beyond help already.");
	} elsif ($zstat->in_current_room()) {
	  if ($zstat->in_inventory()) {
	    $story->write_text(ucfirst(sprintf $self->random_message(BANISH_SELF_MESSAGES), $desc, $desc));
	  } elsif ($zstat->is_toplevel_child()) {
	    # top-level, should be visible
	    $story->write_text(sprintf $self->random_message(BANISH_MESSAGES), $desc);
	  } else {
	    # in something else
	    $story->write_text(sprintf $self->random_message(BANISH_CONTAINER_MESSAGES), ${$zstat->toplevel_child()->print()});
	  }
	  $story->insert_obj($id, 0);
	  # set the object's parent to zero (nothing)
	} else {
	  $story->write_text(sprintf "I don't see any %s here.", ${$zo->print()});
	}
      } elsif ($token eq "pilfer") {
	#
	#  Try to move and item to inventory
	#  (move it to this room and submit "take" command)
	#
	my $proceed = 0;
	if (!$story->player_object()) {
	  $story->write_text("Sorry, I'm not sure where you are just yet...");
	} elsif ($zstat->is_player()) {
	  if ($desc eq "cretin") {
	    $story->write_text("\"cretin\" suits you, I see.");
	  } else {
	    $story->write_text($self->random_message(SNIDE_MESSAGES));
	  }
	} elsif ($zstat->in_current_room()) {
	  if ($zstat->in_inventory()) {
	    $story->write_text($self->random_message(PILFER_SELF_MESSAGES));
	    $proceed = 1;
	    # sometimes makes sense: pilfer canary from egg, even
	    # when carrying it
	  } elsif ($zstat->is_toplevel_child()) {
	    # at top level in room (should already be visible)
	    $story->write_text($self->random_message(SNIDE_MESSAGES));
	    $story->newline();
	    $story->write_text(sprintf "The %s seems unaffected.", $desc);
	  } else {
	    # inside something else in this room
	    $story->write_text(sprintf $self->random_message(PILFER_LOCAL_MESSAGES), ${$zstat->toplevel_child->print});
	    $proceed = 1;
	  }
	} else {
	  $story->write_text($self->random_message(PILFER_REMOTE_MESSAGES));
	  $proceed = 1;
        }
        if ($proceed) {
	  $story->insert_obj($id, $story->current_room());
	  # hee hee
	  my $thing = (reverse(split /\s+/, $desc))[0];
	  # if description is multiple words, use the last one.
          # example: zork 1, "jewel-encrusted egg" becomes "egg".
	  # (parser doesn't understand "jewel-encrusted" part)
	  # room for improvement: check to make sure this word
	  # is in dictionary
	  $story->push_command("take " . $thing);
	  $just_one_newline = 1;
        }
      } else {
	die "$token ?";
      }
    } elsif ($what) {
$story->write_text(sprintf "I don't know what that is, though I have seen a %s that you might be interested in...", ${$object_cache->get_random()});
    } elsif ($token eq "pilfer") {
      $story->write_text("Please tell me what you want to pilfer.");
    } elsif ($token eq "bamf") {
      $story->write_text("Please tell me what you want to make disappear.");
    } else {
      $story->write_text("Can you be more specific?");
    }
  }

  $story->newline();
  $story->newline() unless $just_one_newline;
  $story->suppress_hack();
  # suppress parser output ("I don't know the word XXX.");
}

sub get_object_cache {
  # FIX ME
  unless ($_[0]->object_cache()) {
    my $cache = new Games::Rezrov::ZObjectCache($_[0]->story());
    $cache->load_names();
    $_[0]->object_cache($cache);
  }
  return $_[0]->object_cache();
}

sub random_message {
  my ($self, @messages) = @_;
  my $index;
  my $last_index = $self->last_random();
  while (1) {
    $index = int(rand(scalar @messages));
    last if (@messages == 1 or 
	     !defined($last_index) or
	     $index != $last_index);
    # don't use the same index twice in a row
  }
  $self->last_random($index);
  return $messages[$index];
}

sub nice_list {
  if (@_ == 1) {
    return $_[0];
  } elsif (@_ == 2) {
    return join " or ", @_;
  } else {
    return join(", ", @_[0 .. ($#_ - 1)]) . ", or " . $_[$#_];
  }
}

sub dump_dictionary {
  my ($self, $what) = @_;
  my $story = $self->story();
  my $dict_start = $self->dictionary_word_start();
  my $ztext = $self->ztext();
  my $num_words = $self->entry_count();
  my $entry_length = $self->entry_length();
  my $by_name = $self->decoded_by_word();
  my $by_address = $self->decoded_by_address();
  my $address;

  for (my $index = 0; $index < $num_words; $index++) {
    $address = $dict_start + ($index * $entry_length);
    unless (exists $by_address->{$address}) {
      my $word = $ztext->decode_text($address);
      $by_name->{$$word} = $address;
      $by_address->{$address} = $$word;
    }
  }
  my $rows = $story->rows();
  my $columns = $story->columns();
  my $len = $self->encoded_word_length();
  my $fit = int($columns / ($len + 2));
  my $fmt = '%-' . $len . "s";
  my $wrote = 0;

  my @words;
  if ($what) {
    @words = grep {/^$what/} sort keys %{$by_name};
  } else {
    my %temp = %{$by_name};
    if (Games::Rezrov::ZOptions::SHAMELESS()) {
      my $token_len = $story->header()->encoded_word_length();
      foreach my $word (qw(michael edmonson)) {
	$word = substr($word,0,$token_len) if length $word > $token_len;
	$temp{$word} = 1;
      }
    }
    @words = sort keys %temp;
  }

  foreach (@words) {
    $story->write_text(sprintf $fmt, $_);
    if (++$wrote % $fit) {
      $story->write_text("  ");
    } else {
      $story->newline();
    }
  }
}

sub dump_objects {
  my ($self, $type, $what) = @_;
  my $object_cache = $self->get_object_cache();
  my $story = $self->story();
  my $last = $object_cache->last_object();
  
  $SIG{"__WARN__"} = sub {};
  # intercept perl's silly "deep recursion" warnings
  
  if ($type == 1) {
    # show object relationships
    if ($what) {
      my @hits = $object_cache->find($what, "-all" => 1);
      if (@hits > 1) {
	$story->write_text(sprintf 'Hmm, which do you mean: %s?', nice_list(map {$_->[1]} @hits));
      } elsif (@hits == 1) {
	my $zstat = new Games::Rezrov::ZObjectStatus($hits[0]->[0],
						     $story,
						     $object_cache);

	if (my $pr = $zstat->parent_room()) {
	  $self->dump_object($pr, 1, 1);
	} else {
	  $self->dump_object($object_cache->get($hits[0]->[0]), 1, 1);
	}
      } else {
	$story->write_text(sprintf 'I have no idea what you mean by "%s."', $what);
      }
    } else {
      my ($zo, $pid);
      my (%objs, %parents, @tops, %seen);
      for (my $i = 1; $i <= $last; $i++) {
	$zo = $object_cache->get($i);
	$pid = $zo->get_parent_id();
	$objs{$i} = $zo;
	$parents{$i} = $pid;
      }

      for (my $i = 1; $i <= $last; $i++) {
	$pid = $parents{$i};
	if ($pid == 0 or !$objs{$pid}) {
	  push @tops, $i;
	}
      }

      foreach (@tops) {
	next if exists $seen{$_};
	$self->dump_object($objs{$_}, 1, 0, \%seen);
      }
    }
  } else {
    # list rooms/items
    foreach ($type == 2 ? $object_cache->get_rooms() : $object_cache->get_items()) {
      $story->write_text(" " . $_);
      $story->newline();
    }
  }
  #  delete $SIG{"__WARN__"};
  # doesn't restore handler (!)
  $SIG{"__WARN__"} = "";
  # but this does
}

sub dump_object {
  my ($self, $object, $indent, $no_sibs, $seen_ref) = @_;
  my $story = $self->story();

  my $object_cache = $self->get_object_cache();
  my $id = $object->object_id();
  my $last = $object_cache->last_object();
  die unless $id;
  my $desc = $object_cache->print($id);
  if (defined $desc) {
    if ($seen_ref) {
      return if exists $seen_ref->{$id};
      $seen_ref->{$id} = 1;
    }
    $story->newline();
    $story->write_text((" " x $indent) .
		       $$desc . 
		       " ($id)");
    my $child = $object_cache->get($object->get_child_id());
    $self->dump_object($child, $indent + 3, 0, $seen_ref) if $child and
      $child->object_id() and
      $child->object_id() <= $last;
    unless ($no_sibs) {
      my $sib = $object_cache->get($object->get_sibling_id());
#      printf STDERR "sib of %s: %s (%d)\n", ${$object->print}, ${$sib->print}, $sib->object_id if $sib;
      $self->dump_object($sib, $indent, 0, $seen_ref) if $sib and
	$sib->object_id() and
	$sib->object_id() <= $last;
    }
  } else {
    print STDERR "No desc for item $id!\n";
  }
}

sub teleport {
  #
  #  cheat command: move the player to a new location
  #
  my ($self, $where) = @_;
  my $story = $self->story();
  my $player_object = $story->player_object();
  if (!$where) {
    $story->write_text("Where to?");
  } elsif (!$player_object) {
    $story->write_text("Sorry, I'm not sure where you are just yet...");
  } else {
    my $object_cache = $self->get_object_cache();
    my @hits = $object_cache->find($where, "-room" => 1);
    my @item_hits = $object_cache->find($where);
    if (@hits == 1) {
      # only one possible destination: proceed
      my $room_id = $hits[0]->[0];
      my $zstat = new Games::Rezrov::ZObjectStatus($room_id,
						   $story,
						   $object_cache);
      if ($zstat->is_current_room()) {
	# destination object is the current room: be rude
	$story->write_text($self->random_message(TELEPORT_HERE_MESSAGES));
      } else {
	# "teleport" to the new room
	$story->insert_obj($player_object, $room_id);
	# make the player object a child of the new room object
	$story->write_text($self->random_message(TELEPORT_MESSAGES));
	# print an appropriate message
	$story->push_command("look");
	# steal player's next turn to describe new location
      }
    } elsif (@item_hits == 1 and @hits == 0) {
      # user has specified an item instead of a room; try to teleport
      # to the room the item is in
      my $zstat = new Games::Rezrov::ZObjectStatus($item_hits[0]->[0],
						   $story,
						   $object_cache);
      
      if ($zstat->parent_room()) {
	# item was in a room
	my $proceed = 1;
	if ($zstat->is_current_room()) {
	  # destination is the current room: be rude
	  $story->write_text($self->random_message(TELEPORT_HERE_MESSAGES));
	  $proceed = 0;
	} elsif ($zstat->is_player()) {
	  $story->write_text("Sure, just tell me where.");
	  $proceed = 0;
	} elsif ($zstat->is_toplevel_child()) {
	  # top-level, should be visible in new location
	  $story->write_text($self->random_message(TELEPORT_TO_ITEM_MESSAGES));
	} else {
	  # item is probably inside something else visible in the room
	  my $desc = $zstat->toplevel_child()->print();
	  $story->write_text(sprintf "I think it's around here somewhere; try the %s.", $$desc);
	  # print description of item's toplevel container
	}
	if ($proceed) {
	  # move the player to the room and steal turn to look around
	  $story->insert_obj($player_object,
			     $zstat->parent_room()->object_id());
	  $story->push_command("look");
	}
      } else {
	# can't determine parent (many objects are in limbo until 
	# something happens)
	my $random = $object_cache->get_random("-room" => 1);
	$story->write_text(sprintf "I don't where that is; how about the %s?", $$random);
      }
    } elsif (@hits > 1) {
      # ambiguous destination
      $story->write_text(sprintf 'Hmm, where you mean: %s?',
			 nice_list(sort map {$_->[1]} @hits));
    } elsif (@item_hits > 1) {
      # ambiguous item
      $story->write_text(sprintf 'Hmm, which do you mean: %s?',
			 nice_list(sort map {$_->[1]} @item_hits));
    } else {
      # no clue at all
      my $random = $object_cache->get_random("-room" => 1);
      $story->write_text(sprintf "I don't where that is; how about the %s?", $$random);
    }
  }
}

sub frotz {
  # cheat command --
  # "frotz" emulation, from Enchanter spell to cause something to emit light.
  # Zork I/II/III define frotz in their dictionaries!  Aliases: "futz", "lumen"
  #
  # Light is usually provided by a particular object attribute,
  # which varies by game...
  my ($self, $what) = @_;
  my $story = $self->story();

  my @SUPPORTED_GAMES = (
			 [ ZORK_1, 20 ],
			 [ ZORK_2, 19 ],
			 [ ZORK_3, 15 ],
			 [ INFIDEL, 21, 10 ],
			 # In Infidel, attribute 21 provides light,
			 # attribute 10 seems to show "lit and burning" in
			 # inventory
			);

  my @attributes = $self->support_check(@SUPPORTED_GAMES);
  return unless @attributes;
#  die join ",", @attributes;
  
  unless ($what) {
    $story->write_text("Light up what?");
  } else {
    # know how to do it
    my $object_cache = $self->get_object_cache();
    my @hits = $object_cache->find($what);
    if (@hits == 1) {
      # just right
      my $id = $hits[0]->[0];
      my $zo = $object_cache->get($id);
      my $zstat = new Games::Rezrov::ZObjectStatus($id,
						   $story,
						   $object_cache);
      my $proceed = 0;
      if ($zstat->is_player()) {
	$story->write_text($self->random_message(FROTZ_SELF_MESSAGES));
      } elsif ($zstat->in_inventory()) {
	$proceed = 1;
      } elsif ($zstat->in_current_room()) {
	if ($zstat->is_toplevel_child()) {
	  # items that are a top-level child of the room are OK;
	  # even if we can't pick them up, assume they are visible
	  $proceed = 1;
	} else {
	  # things inside other things might not be visible; be coy
	  $story->write_text(sprintf "Why don't you pick it up first.");
	}
      } else {
	$story->write_text(sprintf "I don't see any %s here!", $what);
      }

      if ($proceed) {
	# with apologies to "Enchanter"  :)
	my $desc = $zo->print();
	$story->write_text(sprintf "There is an almost blinding flash of light as the %s begins to glow! It slowly fades to a less painful level, but the %s is now quite usable as a light source.", $$desc, $$desc);
	foreach (@attributes) {
	  $zo->set_attr($_);
	}
      }
    } elsif (@hits > 1) {
      # too many 
      $story->write_text(sprintf 'Hmm, which do you mean: %s?',
			 nice_list(sort map {$_->[1]} @hits));
    } else {
      # no matches
      $story->write_text("What's that?");
    }
  }
}

sub travis {
  #
  # cheat command -- "travis": turn an ordinary item into a weapon.
  # 
  # "Weapons" just seem to be items with a certain object property set...
  #
  # You lookin' at me?
  #
  my ($self, $what) = @_;
  my $story = $self->story();
  my @SUPPORTED_GAMES = (
			 [ ZORK_1, 29 ],
		       );

  my $property = $self->support_check(@SUPPORTED_GAMES) || return;

  unless ($what) {
    $story->write_text("What do you want to use as a weapon?");
  } else {
    my $object_cache = $self->get_object_cache();
    my @hits = $object_cache->find($what);
    if (@hits == 1) {
      my $zo = $object_cache->get($hits[0]->[0]);
      my $zstat = new Games::Rezrov::ZObjectStatus($hits[0]->[0],
						   $story,
						   $object_cache);
      if ($zstat->is_player()) {
	$story->write_text("You're scary enough already.");
      } elsif ($zstat->in_inventory()) {
	if ($zo->test_attr($property)) {
	  $story->write_text(sprintf "The %s already looks pretty menacing.", ${$zo->print});
	} else {
	  $zo->set_attr($property);
	  $story->write_text(sprintf $self->random_message(TRAVIS_MESSAGES), ${$zo->print});
	}
      } elsif ($zstat->in_current_room()) {
	$story->write_text("Pick it up, then we'll talk.");
      } else {
	$story->write_text(sprintf "I don't see any %s here!", ${$zo->print});	
      }
    } elsif (@hits > 1) {
      $story->write_text(sprintf 'Hmm, which do you mean: %s?',
			 nice_list(sort map {$_->[1]} @hits));
    } else {
      $story->write_text("What's that?");
    }
  }
}

sub support_check {
  # check if this game matches one of a given a list of game versions
  my ($self, @list) = @_;
  my $story = $self->story();
  foreach (@list) {
    my ($name, $rnum, $serial, $checksum, @stuff) = @{$_};
    if ($story->is_this_game($rnum, $serial, $checksum)) {
      # yay
      return @stuff == 1 ? $stuff[0] : @stuff;
    }
  }
  # failed, complain:
  $story->write_text("Sorry, this trick only currently works in the following games:");
  foreach (@list) {
    $story->newline();
    $story->write_text(sprintf "  - %s (release %d, serial number %s)", @{$_});
  }
  
  return undef;
}

sub tail {
  # cheat command --
  # follow an object as it moves around; usually a "person"
  my ($self, $what) = @_;
  my $story = $self->story();
  unless ($what) {
    $story->write_text("Who or what do you want to tail?");
  } else {
    my $object_cache = $self->get_object_cache();
    my @hits = $object_cache->find($what);
    if (@hits == 1) {
      # just right
      my $id = $hits[0]->[0];
      my $zo = $object_cache->get($id);
      my $target_desc = $zo->print();
      my $zstat = new Games::Rezrov::ZObjectStatus($id,
						   $story,
						   $object_cache);
      if (my $parent = $zstat->parent_room()) {
	$story->tailing($id);
	my $zs2 = new Games::Rezrov::ZObjectStatus($parent->object_id(),
						   $story,
						   $object_cache);
	if ($zs2->in_current_room()) {
	  # in same room already
	  $story->write_text(sprintf "OK.");
	} else {
	  # our subject is elsewhere: go there
	  my $desc = ${$parent->print()};
      	  if ($$target_desc =~ /^mr?s\. /i) {
   	    $story->write_text(sprintf "All right; she's in the %s.", $desc);
	  } elsif ($$target_desc =~ /^mr\. /i) {
   	    $story->write_text(sprintf "All right; he's in the %s.", $desc);
	  } else {
	    $story->write_text(sprintf "All right; heading to %s.", $desc);
	  }
          $story->newline();
   	  $self->teleport($desc);
        }
      } else {
	$story->write_text(sprintf "I don't know where %s is...", ${$zo->print});
      }
    } elsif (@hits > 1) {
      $story->write_text(sprintf 'Hmm, which one: %s?',
			 nice_list(sort map {$_->[1]} @hits));
    } else {
      $story->write_text("Who or what is that?");
    }
  }

}

sub help {
  # when user types "help" and the game doesn't understand
  my $self = shift;
  my $story = $self->story();

  my @stuff = gethostbyname("www.netscape.com");
  if (@stuff) {
    my $url;
    my $fvo = $story->full_version_output() || "";
    if ($fvo =~ /infocom/i) {
      # we're playing an infocom game
      $url = $self->random_message(HELP_INFOCOM_URLS);
    } else {
      # title disabled or not infocom
      $url = $self->random_message(HELP_GENERIC_URLS);
    }
    $story->write_text("I'll try...");
    call_web_browser($url);
  } else {
    $story->write_text("Connect to the Internet, then maybe I'll help you.");
  }
  $story->newline();
  $story->newline();
  $story->suppress_hack();
}


sub call_web_browser {
  # try to call a web browser for a particular URL.
  # uses Netscape's remote-control interface if available
  my $url = shift;
  
  if ($^O eq "MSWin32") {
    system "start $url";
  } else {
    my $cmd = sprintf "netscape -remote 'openURL(%s)'", $url;
    system $cmd;
    if ($?) {
      # failed: Netscape isn't running, so start it
      my $command = sprintf "netscape %s &", $url;
      system $command;
    }
  }
}

1;
